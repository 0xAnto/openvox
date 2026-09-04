import Foundation

// MARK: - NDJSON protocol (see docs/superpowers/specs/2026-08-31-openvox-design.md)

/// App -> sidecar messages. Optional fields are omitted from the wire
/// encoding by Codable's synthesized encodeIfPresent, matching the
/// documented minimal per-op JSON shapes.
struct SidecarOpMessage: Codable, Equatable {
    var op: String
    var engine: String?
    var pcm: String?
    /// Moonshine size folder. Omitted for nemotron, which has one engine.
    var variant: String?

    static func load(engine: String, variant: String? = nil) -> SidecarOpMessage {
        .init(op: "load", engine: engine, pcm: nil, variant: variant)
    }
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
    /// On "ready": the moonshine size that actually loaded. It differs from
    /// the requested one when the sidecar fell back, so the app follows it
    /// rather than the request.
    var variant: String?
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
///
/// All writes (load/stream/transcribe/finalize/ping) go through one serial
/// `writeQueue`, in call order. Encoding (including base64) happens on that
/// queue too, not on the caller's thread -- callers on the CGEventTap
/// callback or the audio render thread must return quickly, and a chunk
/// enqueued before `finalize` can never be written after it.
final class SidecarClient {
    var onEvent: ((SidecarEventMessage) -> Void)?
    /// Fired on main when the process terminates unexpectedly (not via stop()).
    var onDied: (() -> Void)?
    /// Fired on main after a crash-restart successfully relaunches the process.
    var onRespawned: (() -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var readBuffer = Data()
    private var restartAttempts = 0
    private var stopped = true
    private var pendingRestart: DispatchWorkItem?
    private let writeQueue = DispatchQueue(label: "openvox.sidecar.write")

    /// Set right before an intentional (not a crash) termination, so the
    /// termination handler relaunches immediately -- no backoff, no
    /// onDied -- instead of treating it as a death.
    private var intentionalRestart = false
    private var afterIntentionalRestart: (() -> Void)?

    /// Idempotent: does nothing if the process is already alive, so a
    /// manual Retry re-sends `load` instead of spawning a second process
    /// over the first.
    @discardableResult
    func start() -> Bool {
        stopped = false
        if let process, process.isRunning { return true }
        pendingRestart?.cancel()
        pendingRestart = nil
        return launch(isRestart: false)
    }

    func stop() {
        stopped = true
        pendingRestart?.cancel()
        pendingRestart = nil
        stdin?.closeFile()
        process?.terminate()
        process = nil
    }

    /// Interrupts a `load` in progress (which blocks the sidecar's stdin
    /// loop, so it can't just be asked to stop): terminates the process
    /// without treating it as a crash, relaunches, and calls `then` once
    /// the new process is up. Safe to call even if no process is running
    /// yet (e.g. cancelling during the app-side deps-install phase) -- in
    /// that case it just launches fresh right away.
    func cancelLoad(then: @escaping () -> Void) {
        pendingRestart?.cancel()
        pendingRestart = nil
        guard let process, process.isRunning else {
            if launch(isRestart: false) { then() }
            return
        }
        intentionalRestart = true
        afterIntentionalRestart = then
        process.terminate()
    }

    func load(engine: String, variant: String? = nil) { enqueue { .load(engine: engine, variant: variant) } }
    func transcribe(pcm: [Float]) { enqueue { .transcribe(pcm: Base64PCM.encode(pcm)) } }
    func stream(pcm: [Float]) { enqueue { .stream(pcm: Base64PCM.encode(pcm)) } }
    func finalize() { enqueue { .finalize } }
    func ping() { enqueue { .ping } }

    /// Builds and writes the op entirely on `writeQueue`. `makeOp` is
    /// called there, not on the caller's thread, so base64-encoding a large
    /// offline utterance never runs on the CGEventTap callback or the audio
    /// render thread.
    private func enqueue(_ makeOp: @escaping () -> SidecarOpMessage) {
        writeQueue.async { [weak self] in self?.write(makeOp()) }
    }

    private func write(_ op: SidecarOpMessage) {
        guard let stdin else { return }
        guard var data = try? JSONEncoder().encode(op) else { return }
        data.append(0x0A) // NDJSON: one object per line
        do {
            try stdin.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(Data("openvox: sidecar write failed: \(error)\n".utf8))
        }
    }

    @discardableResult
    private func launch(isRestart: Bool) -> Bool {
        guard let python = pythonURL, FileManager.default.isExecutableFile(atPath: python.path),
              let script = SidecarPaths.scriptURL else {
            onEvent?(SidecarEventMessage(ev: "error", stage: nil, pct: nil, engine: nil, text: nil,
                                          message: "Sidecar runtime not installed yet", code: nil))
            return false
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path]
        // The sidecar runs from Contents/Resources. Never let Python write
        // __pycache__ files into the signed app bundle: changing even one
        // resource after launch invalidates the bundle signature and can
        // break the stable Accessibility identity on the next launch.
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment

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
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.process = nil
                self.stdin = nil
                if self.intentionalRestart {
                    self.intentionalRestart = false
                    let callback = self.afterIntentionalRestart
                    self.afterIntentionalRestart = nil
                    if self.launch(isRestart: false) { callback?() }
                    return
                }
                self.onDied?()
                self.scheduleRestart()
            }
        }

        do {
            try process.run()
            self.process = process
            self.stdin = stdinPipe.fileHandleForWriting
            // restartAttempts resets only on a `ready` event (see consume()),
            // not here -- a crash-looping sidecar must keep backing off.
            if isRestart { onRespawned?() }
            return true
        } catch {
            onEvent?(SidecarEventMessage(ev: "error", stage: nil, pct: nil, engine: nil, text: nil,
                                          message: "Failed to launch sidecar: \(error)", code: nil))
            scheduleRestart()
            return false
        }
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newlineRange = readBuffer.range(of: Data([0x0A])) {
            let line = readBuffer.subdata(in: readBuffer.startIndex..<newlineRange.lowerBound)
            readBuffer.removeSubrange(readBuffer.startIndex..<newlineRange.upperBound)
            guard !line.isEmpty, let event = try? JSONDecoder().decode(SidecarEventMessage.self, from: line) else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if event.ev == "ready" { self.restartAttempts = 0 }
                self.onEvent?(event)
            }
        }
    }

    private func scheduleRestart() {
        restartAttempts += 1
        let delay = min(30.0, pow(2.0, Double(restartAttempts)))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.launch(isRestart: true)
        }
        pendingRestart = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private var pythonURL: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenVox/runtime/bin/python")
    }
}
