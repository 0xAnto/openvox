import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let appState = AppState()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let hotkeyMonitor: HotkeyMonitor
    private let audioCapture = AudioCapture()
    private let sidecarClient = SidecarClient()
    private let partialTyper = PartialTyper()
    private var indicatorPanel: IndicatorPanel!
    private var onboardingController: OnboardingWindowController?
    private var settingsController: NSWindowController?

    private var isDictating = false
    private var isFinalizing = false
    private var utteranceStart = Date()
    private var sawProgressThisAttempt = false

    override init() {
        hotkeyMonitor = HotkeyMonitor(keyCode: appState.hotkeyKeyCode)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon

        indicatorPanel = IndicatorPanel()
        buildStatusItem()

        hotkeyMonitor.onDown = { [weak self] in self?.hotkeyDown() ?? false }
        hotkeyMonitor.onUp = { [weak self] in self?.hotkeyUp() }
        audioCapture.onChunk = { [weak self] chunk in self?.handleChunk(chunk) }
        audioCapture.onLevel = { [weak self] level in self?.handleLevel(level) }

        appState.onModeSelected = { [weak self] mode in self?.attemptLoad(for: mode) }
        appState.onHotkeyKeyCodeChange = { [weak self] code in self?.hotkeyMonitor.keyCode = code }
        appState.onMicDeviceChange = { [weak self] uid in self?.audioCapture.setInputDevice(uid: uid) }
        // Granting Accessibility during onboarding must arm the hotkey
        // without a relaunch; hotkeyMonitor.start() is idempotent.
        appState.onAccessibilityGranted = { [weak self] in self?.hotkeyMonitor.start() }

        sidecarClient.onEvent = { [weak self] ev in self?.handle(ev) }
        sidecarClient.onDied = { [weak self] in self?.handleSidecarDied() }
        sidecarClient.onRespawned = { [weak self] in self?.attemptLoad(for: self?.appState.mode ?? .fast) }

        // Seed AudioCapture with the persisted mic pick and the current
        // Accessibility status (the didSet above fires start() if granted).
        audioCapture.setInputDevice(uid: appState.micDeviceUID)
        appState.accessibilityGranted = PermissionsHelper.isAccessibilityTrusted()

        if appState.setupCompleted {
            // Runtime was already provisioned during onboarding; just start
            // the long-lived sidecar and warm the last-selected engine.
            sidecarClient.start()
            attemptLoad(for: appState.mode)
        } else {
            showOnboarding()
        }
    }

    // MARK: - Status item / menu

    private func buildStatusItem() {
        if let icon = Bundle.main.image(forResource: "MenuBarIcon") {
            icon.isTemplate = true // adapts to light/dark menu bar and highlight
            icon.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = icon
        } else {
            // Dev `swift run` has no bundled Resources; fall back to an SF Symbol.
            statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "OpenVox")
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard appState.setupCompleted else {
            menu.cancelTracking()
            showOnboarding()
            return
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        for mode in AppState.Mode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = appState.mode == mode ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit OpenVox", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func statusLine() -> String {
        if appState.activeMode != appState.mode {
            return "\(appState.mode.label) — preparing (\(appState.sidecarStatus))"
        }
        return "\(appState.mode.label) — \(appState.sidecarStatus)"
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = AppState.Mode(rawValue: raw) else { return }
        appState.selectMode(mode)
    }

    @objc private func openSettings() {
        if settingsController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "OpenVox Settings"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(appState: appState))
            settingsController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(
                appState: appState,
                onDownload: { [weak self] mode in self?.startOnboardingProvisioning(mode: mode) },
                onFinish: { [weak self] in self?.finishOnboarding() }
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingController?.showWindow(nil)
        onboardingController?.window?.makeKeyAndOrderFront(nil)
    }

    private func startOnboardingProvisioning(mode: AppState.Mode) {
        appState.mode = mode
        appState.provisioningFailed = false
        appState.progressStage = nil
        appState.progressPct = nil
        sawProgressThisAttempt = false
        appState.sidecarStatus = "Preparing runtime…"
        RuntimeSetup.ensureBase(status: { [weak self] status in self?.appState.sidecarStatus = status }) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.appState.provisioningFailed = true
                self.appState.sidecarStatus = "Setup failed. Check your internet connection and try again."
                return
            }
            self.sidecarClient.start()
            self.attemptLoad(for: mode)
        }
    }

    private func finishOnboarding() {
        appState.setupCompleted = true
        onboardingController?.close()
        onboardingController = nil
    }

    // MARK: - Sidecar / mode switching

    private func attemptLoad(for mode: AppState.Mode) {
        appState.sidecarReady = false
        appState.provisioningFailed = false
        appState.progressStage = nil
        appState.progressPct = nil
        sawProgressThisAttempt = false
        appState.sidecarStatus = "Preparing \(mode.label)…"
        sidecarClient.load(engine: mode.engine)
    }

    /// SidecarClient.onDied: the process terminated unexpectedly (crash,
    /// killed, etc). Reset in-flight state and surface a failure for the
    /// Download step if this happened mid-provisioning; SidecarClient
    /// itself schedules a backoff restart, and onRespawned re-sends `load`
    /// once it relaunches.
    private func handleSidecarDied() {
        appState.sidecarReady = false
        if isDictating || isFinalizing { abortDictation() }
        if appState.activeMode != appState.mode {
            appState.provisioningFailed = true
        }
        appState.sidecarStatus = "Sidecar stopped unexpectedly. Restarting…"
    }

    /// Stops capture (if running) and hides the indicator; shared by the
    /// sidecar-died and sidecar-error paths so a crash never leaves the mic
    /// tapped or the indicator stuck on screen.
    private func abortDictation() {
        if isDictating { _ = audioCapture.stop() }
        isDictating = false
        isFinalizing = false
        indicatorPanel.hide()
    }

    private func handle(_ ev: SidecarEventMessage) {
        switch ev.ev {
        case "progress":
            sawProgressThisAttempt = true
            appState.progressStage = ev.stage
            appState.progressPct = ev.pct
            appState.sidecarStatus = ev.stage == "download" ? "Downloading model…" : "Loading…"

        case "ready":
            let readyMode = AppState.Mode.allCases.first { $0.engine == ev.engine }
            appState.activeMode = readyMode ?? appState.mode
            appState.sidecarReady = true
            appState.provisioningFailed = false
            appState.sidecarStatus = sawProgressThisAttempt ? "Ready" : "Already downloaded"

        case "partial":
            guard let text = ev.text else { return }
            partialTyper.partial(text)
            if isDictating || isFinalizing { indicatorPanel.show(state: .transcribing) }

        case "final":
            let text = ev.text ?? ""
            if appState.activeMode == .streaming {
                partialTyper.final(text)
            } else if text.utf16.count > TextInserter.pasteThreshold {
                TextInserter.pasteAndInsert(text)
            } else {
                TextInserter.type(text)
            }
            isFinalizing = false
            indicatorPanel.hide()

        case "error":
            if ev.code == "missing-streaming-deps" {
                appState.sidecarStatus = "Installing streaming components…"
                RuntimeSetup.installStreamingExtras(status: { [weak self] s in self?.appState.sidecarStatus = s }) { [weak self] ok in
                    guard let self else { return }
                    guard ok else {
                        self.appState.provisioningFailed = true
                        self.appState.sidecarStatus = "Streaming setup failed"
                        return
                    }
                    self.attemptLoad(for: .streaming) // retry, now with deps installed
                }
            } else {
                // Unknown/plain error codes: surface the message and reset
                // any in-flight utterance so the app doesn't hang silently.
                appState.sidecarStatus = ev.message ?? "Sidecar error"
                if appState.activeMode == nil { appState.provisioningFailed = true }
                if isDictating || isFinalizing { abortDictation() }
            }

        default:
            break // "pong" and anything else: no action needed
        }
    }

    // MARK: - Dictation flow

    /// Returns whether the press was accepted, so HotkeyMonitor knows
    /// whether to swallow a plain-key hotkey or let it type normally.
    @discardableResult
    private func hotkeyDown() -> Bool {
        guard !isFinalizing, !isDictating else { return false } // ignore hotkey while finalizing
        guard appState.sidecarReady, let activeMode = appState.activeMode else {
            indicatorPanel.show(state: .notReady(appState.sidecarStatus))
            return false
        }
        isDictating = true
        utteranceStart = Date()
        partialTyper.reset()
        do {
            try audioCapture.start(mode: activeMode == .streaming ? .streaming : .offline)
            indicatorPanel.show(state: .listening(level: 0))
            return true
        } catch {
            isDictating = false
            appState.sidecarStatus = "Microphone error: \(error.localizedDescription)"
            return false
        }
    }

    /// Invoked from the CGEventTap callback: only captures the utterance
    /// and hands the raw samples off; SidecarClient does the base64
    /// encoding and the pipe write on its own queue, so this returns fast
    /// (a slow tap callback risks kCGEventTapDisabledByTimeout).
    private func hotkeyUp() {
        guard isDictating else { return }
        isDictating = false
        let elapsed = Date().timeIntervalSince(utteranceStart)
        let pcm = audioCapture.stop() // also flushes the streaming tail chunk, before finalize below

        guard elapsed >= 0.150 else { // drop accidental taps
            indicatorPanel.hide()
            return
        }

        isFinalizing = true
        indicatorPanel.show(state: .transcribing)
        if appState.activeMode == .streaming {
            sidecarClient.finalize()
        } else {
            sidecarClient.transcribe(pcm: pcm)
        }
    }

    /// Called directly from AudioCapture's render-thread callback; must
    /// stay AppState-free. SidecarClient.stream is thread-safe (it just
    /// enqueues onto its own write queue).
    private func handleChunk(_ chunk: [Float]) {
        sidecarClient.stream(pcm: chunk)
    }

    private func handleLevel(_ level: Float) {
        guard isDictating else { return }
        appState.micLevel = level
        indicatorPanel.show(state: .listening(level: level))
    }
}

private struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Mode", selection: Binding(
                    get: { appState.mode },
                    set: { appState.selectMode($0) }
                )) {
                    ForEach(AppState.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                if appState.activeMode != appState.mode {
                    Text("Preparing \(appState.mode.label)… \(appState.sidecarStatus)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            SetupFormSections(appState: appState)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
    }
}
