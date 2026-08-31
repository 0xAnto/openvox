import Foundation

/// Creates and provisions the Python venv the sidecar runs in. Runs only
/// when a user explicitly asks for it (onboarding's Download step, or
/// switching to Streaming in Settings) -- never automatically at launch,
/// so the app never downloads or installs anything silently.
enum RuntimeSetup {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OpenVox/runtime")

    static var pythonPath: URL { root.appendingPathComponent("bin/python") }

    // MARK: - Cancellation

    // ponytail: a global lock is fine here -- at most one install runs at a
    // time, and cancellation is a rare user-initiated action, not a hot path.
    private static let stateQueue = DispatchQueue(label: "openvox.runtimesetup.state")
    private static var currentProcess: Process?

    /// Terminates the in-flight deps-install process, if any. A no-op if
    /// nothing is currently running (e.g. cancelling while the sidecar's
    /// own `load` is blocking, not this). `run()` reports the terminated
    /// process as a failure, which its callers surface as `ok == false` --
    /// callers that can be cancelled must guard against acting on a stale
    /// completion (see AppDelegate.cancelModeSwitch).
    static func cancelCurrent() {
        stateQueue.sync { currentProcess?.terminate() }
    }

    static func isBaseInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: pythonPath.path)
    }

    /// Creates the venv if needed and installs requirements-base.txt
    /// (numpy, huggingface_hub, onnxruntime, tokenizers -- small, fast).
    /// Enough for Fast/Offline.
    static func ensureBase(status: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        let mainStatus = mainThreadStatus(status)
        DispatchQueue.global(qos: .userInitiated).async {
            let alreadyThere = isBaseInstalled()
            mainStatus(alreadyThere ? "Already downloaded" : "Preparing runtime…")
            let ok = createVenvIfNeeded(status: mainStatus) && installRequirements("requirements-base.txt", status: mainStatus)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Installs requirements-streaming.txt (torch, torchaudio, transformers)
    /// into the same venv. Called reactively when `load` for nemotron
    /// replies `{"ev":"error","code":"missing-streaming-deps"}` -- we don't
    /// pre-check whether torch is importable (a marker file could lie),
    /// we just react to the sidecar telling us.
    static func installStreamingExtras(status: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        let mainStatus = mainThreadStatus(status)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = installRequirements("requirements-streaming.txt", status: mainStatus)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Status callbacks otherwise fire on a background queue but write
    /// observable AppState; marshal every call to main, not just completion.
    private static func mainThreadStatus(_ status: @escaping (String) -> Void) -> (String) -> Void {
        { text in DispatchQueue.main.async { status(text) } }
    }

    private static func createVenvIfNeeded(status: @escaping (String) -> Void) -> Bool {
        if isBaseInstalled() { return true }
        try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let uv = "/opt/homebrew/bin/uv"
        if FileManager.default.isExecutableFile(atPath: uv) {
            status("Creating virtual environment…")
            return run(uv, ["venv", "--python", "3.12", root.path])
        }
        guard let python = findSystemPython() else {
            status("No Python 3.10+ found. Install uv or Python 3.12 and try again.")
            return false
        }
        status("Creating virtual environment…")
        return run(python, ["-m", "venv", root.path])
    }

    /// The plain-python fallback (no uv) needs a real Python 3.10+: this
    /// machine's /usr/bin/python3 is 3.9.6, too old for the pinned deps.
    /// Search common install locations for a modern interpreter and verify
    /// its version rather than trusting the name.
    private static func findSystemPython() -> String? {
        let names = ["python3.13", "python3.12", "python3.11", "python3.10"]
        let pathDirs = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin"] + pathDirs
        for dir in searchDirs {
            for name in names {
                let path = (dir as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: path), isPython310OrLater(path) {
                    return path
                }
            }
        }
        return nil
    }

    private static func isPython310OrLater(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe // some pythons print --version to stderr
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let versionToken = output.split(separator: " ").last else { return false }
        let parts = versionToken.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return false }
        return major > 3 || (major == 3 && minor >= 10)
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
        stateQueue.sync { currentProcess = process }
        process.waitUntilExit()
        stateQueue.sync { currentProcess = nil }
        return process.terminationStatus == 0
    }
}
