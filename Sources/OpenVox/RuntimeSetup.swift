import Foundation

/// Creates and provisions the Python venv the sidecar runs in. Runs only
/// when a user explicitly asks for it (onboarding's Download step, or
/// switching to Streaming in Settings) -- never automatically at launch,
/// so the app never downloads or installs anything silently.
enum RuntimeSetup {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OpenVox/runtime")

    static var pythonPath: URL { root.appendingPathComponent("bin/python") }

    static func isBaseInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: pythonPath.path)
    }

    /// Creates the venv if needed and installs requirements-base.txt
    /// (numpy, huggingface_hub, onnxruntime, tokenizers -- small, fast).
    /// Enough for Fast/Offline.
    static func ensureBase(status: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let alreadyThere = isBaseInstalled()
            if alreadyThere {
                status("Already downloaded")
            } else {
                status("Preparing runtime…")
            }
            let ok = createVenvIfNeeded(status: status) && installRequirements("requirements-base.txt", status: status)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Installs requirements-streaming.txt (torch, torchaudio, transformers)
    /// into the same venv. Called reactively when `load` for nemotron
    /// replies `{"ev":"error","code":"missing-streaming-deps"}` -- we don't
    /// pre-check whether torch is importable (a marker file could lie),
    /// we just react to the sidecar telling us.
    static func installStreamingExtras(status: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = installRequirements("requirements-streaming.txt", status: status)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private static func createVenvIfNeeded(status: @escaping (String) -> Void) -> Bool {
        if isBaseInstalled() { return true }
        try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let uv = "/opt/homebrew/bin/uv"
        if FileManager.default.isExecutableFile(atPath: uv) {
            status("Creating virtual environment…")
            return run(uv, ["venv", "--python", "3.12", root.path])
        }
        status("Creating virtual environment…")
        return run("/usr/bin/python3", ["-m", "venv", root.path])
    }

    private static func installRequirements(_ filename: String, status: @escaping (String) -> Void) -> Bool {
        guard let requirements = SidecarPaths.locate(filename) else {
            status("Missing \(filename)")
            return false
        }
        status("Installing Python dependencies…")
        let uv = "/opt/homebrew/bin/uv"
        if FileManager.default.isExecutableFile(atPath: uv) {
            return run(uv, ["pip", "install", "--python", pythonPath.path, "-r", requirements.path])
        }
        let pip = root.appendingPathComponent("bin/pip").path
        return run(pip, ["install", "-r", requirements.path])
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
