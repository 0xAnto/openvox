import Foundation

// MARK: - NDJSON protocol (see docs/superpowers/specs/2026-08-31-openvox-design.md)

/// App -> sidecar messages. Optional fields are omitted from the wire
/// encoding by Codable's synthesized encodeIfPresent, matching the
/// documented minimal per-op JSON shapes.
struct SidecarOpMessage: Codable, Equatable {
    var op: String
    var engine: String?
    var pcm: String?

    static func load(engine: String) -> SidecarOpMessage { .init(op: "load", engine: engine, pcm: nil) }
    static func transcribe(pcm: String) -> SidecarOpMessage { .init(op: "transcribe", engine: nil, pcm: pcm) }
    static func stream(pcm: String) -> SidecarOpMessage { .init(op: "stream", engine: nil, pcm: pcm) }
    static let finalize = SidecarOpMessage(op: "finalize", engine: nil, pcm: nil)
    static let ping = SidecarOpMessage(op: "ping", engine: nil, pcm: nil)
}

/// Sidecar -> app events. `code` is an optional error sub-type: today only
/// `"missing-streaming-deps"` is defined; any other code is treated as a
/// plain error.
struct SidecarEventMessage: Codable, Equatable {
    var ev: String
    var stage: String?
    var pct: Int?
    var engine: String?
    var text: String?
    var message: String?
    var code: String?
}

/// Audio on the wire is base64 float32 LE, 16 kHz mono. Apple Silicon is
/// little-endian, so the raw Float bytes are already in wire order.
enum Base64PCM {
    static func encode(_ samples: [Float]) -> String {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    }

    static func decode(_ base64: String) -> [Float]? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}

/// Locates a bundled resource under Contents/Resources/sidecar, with a dev
/// fallback to the repo's sidecar/ directory relative to the built
/// executable (so `swift run` works without an app bundle).
enum SidecarPaths {
    static func locate(_ filename: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: (filename as NSString).deletingPathExtension,
                                          withExtension: (filename as NSString).pathExtension,
                                          subdirectory: "sidecar") {
            return bundled
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("sidecar").appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static var scriptURL: URL? { locate("openvox_sidecar.py") }
}

/// Owns the sidecar process: spawns venv python + the sidecar script,
/// speaks NDJSON over stdin/stdout, restarts on death with backoff.
final class SidecarClient {
    var onEvent: ((SidecarEventMessage) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var readBuffer = Data()
    private var restartAttempts = 0
    private var stopped = false

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        stdin?.closeFile()
        process?.terminate()
        process = nil
    }

    func send(_ op: SidecarOpMessage) {
        guard let stdin else { return }
        guard var data = try? JSONEncoder().encode(op) else { return }
        data.append(0x0A) // NDJSON: one object per line
        do {
            try stdin.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(Data("openvox: sidecar write failed: \(error)\n".utf8))
        }
    }

    func load(engine: String) { send(.load(engine: engine)) }
    func transcribe(pcm: String) { send(.transcribe(pcm: pcm)) }
    func stream(pcm: String) { send(.stream(pcm: pcm)) }
    func finalize() { send(.finalize) }
    func ping() { send(.ping) }

    private func launch() {
        guard let python = pythonURL, FileManager.default.isExecutableFile(atPath: python.path),
              let script = SidecarPaths.scriptURL else {
            onEvent?(SidecarEventMessage(ev: "error", stage: nil, pct: nil, engine: nil, text: nil,
                                          message: "Sidecar runtime not installed yet", code: nil))
            return
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        // stderr is free-form logs; surface them for debugging but don't parse.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            FileHandle.standardError.write(Data("[sidecar] \(text)".utf8))
        }

        process.terminationHandler = { [weak self] _ in
            guard let self, !self.stopped else { return }
            self.scheduleRestart()
        }

        do {
            try process.run()
            self.process = process
            self.stdin = stdinPipe.fileHandleForWriting
            restartAttempts = 0
        } catch {
            onEvent?(SidecarEventMessage(ev: "error", stage: nil, pct: nil, engine: nil, text: nil,
                                          message: "Failed to launch sidecar: \(error)", code: nil))
            scheduleRestart()
        }
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newlineRange = readBuffer.range(of: Data([0x0A])) {
            let line = readBuffer.subdata(in: readBuffer.startIndex..<newlineRange.lowerBound)
            readBuffer.removeSubrange(readBuffer.startIndex..<newlineRange.upperBound)
            guard !line.isEmpty, let event = try? JSONDecoder().decode(SidecarEventMessage.self, from: line) else { continue }
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }

    private func scheduleRestart() {
        process = nil
        stdin = nil
        restartAttempts += 1
        let delay = min(30.0, pow(2.0, Double(restartAttempts)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.launch()
        }
    }

    private var pythonURL: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenVox/runtime/bin/python")
    }
}
