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

    private static let holdThreshold: TimeInterval = 0.35

    private var isDictating = false
    private var isFinalizing = false
    /// True once a quick tap (held < holdThreshold) has switched this
    /// utterance into toggle mode: the next hotkey press stops it, rather
    /// than starting a new one.
    private var isToggleActive = false
    /// Set by cancelDictation(); makes the eventual `final` (streaming
    /// still sends finalize, to reset the sidecar's stream state) a no-op.
    private var utteranceCancelled = false
    /// Whether a confirmed text target was found. Checked once at
    /// dictation start for streaming (decides live-type vs live-card for
    /// the whole utterance); unused for offline, which checks at
    /// insertion time instead.
    private var utteranceHasTextTarget = true
    private var transcriptCardShowing = false
    private var sawProgressThisAttempt = false

    override init() {
        hotkeyMonitor = HotkeyMonitor(keyCode: AppState.defaultHotkeyKeyCode, cancelKeyCode: AppState.defaultCancelKeyCode)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon

        indicatorPanel = IndicatorPanel()
        buildStatusItem()

        hotkeyMonitor.keyCode = appState.hotkeyKeyCode
        hotkeyMonitor.cancelKeyCode = appState.cancelKeyCode
        hotkeyMonitor.canAcceptPress = { [weak self] in self?.canAcceptPress() ?? false }
        hotkeyMonitor.onDown = { [weak self] in self?.hotkeyPressed() }
        hotkeyMonitor.onUp = { [weak self] heldFor, synthesized in self?.hotkeyReleased(heldFor: heldFor, synthesized: synthesized) }
        hotkeyMonitor.onCancel = { [weak self] in self?.handleCancelKeyPress() }
        hotkeyMonitor.isCancelActiveProvider = { [weak self] in
            guard let self else { return false }
            return self.isDictating || self.transcriptCardShowing
        }
        audioCapture.onChunk = { [weak self] chunk in self?.handleChunk(chunk) }
        audioCapture.onLevel = { [weak self] level in self?.handleLevel(level) }
        indicatorPanel.onCardDismissed = { [weak self] in self?.transcriptCardShowing = false }

        appState.onHotkeyKeyCodeChange = { [weak self] code in self?.hotkeyMonitor.keyCode = code }
        appState.onCancelKeyCodeChange = { [weak self] code in self?.hotkeyMonitor.cancelKeyCode = code }
        appState.onMicDeviceChange = { [weak self] uid in self?.audioCapture.setInputDevice(uid: uid) }
        appState.onDictationEnabledChange = { [weak self] enabled in self?.applyDictationEnabled(enabled) }
        // Granting Accessibility during onboarding must arm the hotkey
        // without a relaunch; hotkeyMonitor.start() is idempotent.
        appState.onAccessibilityGranted = { [weak self] in
            guard let self, self.appState.dictationEnabled else { return }
            self.hotkeyMonitor.start()
        }

        sidecarClient.onEvent = { [weak self] ev in self?.handle(ev) }
        sidecarClient.onDied = { [weak self] in self?.handleSidecarDied() }
        sidecarClient.onRespawned = { [weak self] in
            guard let self else { return }
            self.beginLoad(target: self.appState.mode, isSwitch: false)
        }

        // Seed AudioCapture with the persisted mic pick -- a pure state
        // store now, so this touches no AVAudioEngine and can't trigger a
        // TCC prompt this early (see AudioCapture.setInputDevice).
        audioCapture.setInputDevice(uid: appState.micDeviceUID)
        appState.accessibilityGranted = PermissionsHelper.isAccessibilityTrusted()

        if appState.setupCompleted {
            // Runtime was already provisioned during onboarding; just start
            // the long-lived sidecar and warm the last-confirmed engine.
            sidecarClient.start()
            beginLoad(target: appState.mode, isSwitch: false)
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
        // While onboarding is incomplete, clicking the status item must
        // bring the setup window back, not show the (mostly non-functional
        // pre-setup) menu. cancelTracking() here aborts the menu before it
        // ever appears.
        guard appState.setupCompleted else {
            menu.cancelTracking()
            showOnboarding()
            return
        }
        rebuildMenu()
    }

    /// Mode selection lives only in Settings (switching provisions a new
    /// engine -- too heavy for a menu click). The default menu is exactly
    /// three items; a status row only appears when there's something to
    /// say (provisioning, loading, or an error).
    private func rebuildMenu() {
        menu.removeAllItems()

        let enableItem = NSMenuItem(title: "Enable Dictation", action: #selector(toggleDictationEnabled), keyEquivalent: "")
        enableItem.target = self
        enableItem.state = appState.dictationEnabled ? .on : .off
        menu.addItem(enableItem)

        if let status = idleStatusLineOrNil() {
            menu.addItem(.separator())
            let statusRow = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            statusRow.isEnabled = false
            menu.addItem(statusRow)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit OpenVox", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Nil when idle-and-ready (nothing worth saying); otherwise a short
    /// status for provisioning/loading/error.
    private func idleStatusLineOrNil() -> String? {
        if appState.provisioningFailed { return appState.sidecarStatus }
        if appState.pendingMode != nil { return "Preparing \(currentLoadTarget.label)… \(appState.sidecarStatus)" }
        if !appState.sidecarReady { return appState.sidecarStatus }
        return nil
    }

    @objc private func toggleDictationEnabled() {
        appState.dictationEnabled.toggle()
    }

    /// Off: tears down the tap (no indicator ever shows) and cleanly ends
    /// anything in flight. On: re-arms the tap if Accessibility is granted.
    private func applyDictationEnabled(_ enabled: Bool) {
        if enabled {
            if appState.accessibilityGranted { hotkeyMonitor.start() }
        } else {
            hotkeyMonitor.stop()
            if isDictating || isFinalizing {
                abortDictation()
            } else {
                indicatorPanel.hide()
            }
        }
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
            window.contentView = NSHostingView(rootView: SettingsView(
                appState: appState,
                onSelectMode: { [weak self] mode in self?.requestModeSwitch(mode) },
                onCancelSwitch: { [weak self] in self?.cancelModeSwitch() }
            ))
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
            self.beginLoad(target: mode, isSwitch: false)
        }
    }

    private func finishOnboarding() {
        appState.setupCompleted = true
        onboardingController?.dropFloatingLevel() // no longer needs to stay above System Settings etc.
        onboardingController?.close()
        onboardingController = nil
    }

    // MARK: - Sidecar / mode switching

    /// Whichever mode we're currently trying to get ready: the switch
    /// target while one is in flight, otherwise the confirmed-active mode.
    private var currentLoadTarget: AppState.Mode { appState.pendingMode ?? appState.mode }

    /// `isSwitch: true` marks this as an explicit user-initiated switch
    /// away from a different, already-working mode (sets `pendingMode`, so
    /// Settings shows the provisioning view with Cancel, and `mode` only
    /// flips on success). `isSwitch: false` is the initial post-launch
    /// warm-up or a crash-recovery reload of the mode already selected --
    /// no previous mode to fall back to, so no Cancel affordance.
    private func beginLoad(target: AppState.Mode, isSwitch: Bool) {
        appState.sidecarReady = false
        appState.pendingMode = isSwitch ? target : nil
        appState.provisioningFailed = false
        appState.progressStage = nil
        appState.progressPct = nil
        sawProgressThisAttempt = false
        appState.sidecarStatus = "Preparing \(target.label)…"
        sidecarClient.load(engine: target.engine)
    }

    private func requestModeSwitch(_ target: AppState.Mode) {
        guard target != appState.mode, appState.pendingMode == nil else { return }
        beginLoad(target: target, isSwitch: true)
    }

    /// Cancel button in Settings' progress view, or picking the other mode
    /// again mid-switch. Terminates whatever's in flight and restores the
    /// previously-active mode; never surfaces this as an error.
    private func cancelModeSwitch() {
        guard appState.pendingMode != nil else { return }
        let restoreTarget = appState.mode
        // Deps-install phase: a no-op if nothing's running there.
        RuntimeSetup.cancelCurrent()
        appState.pendingMode = nil
        appState.provisioningFailed = false
        appState.progressStage = nil
        appState.progressPct = nil
        appState.sidecarStatus = "Restoring \(restoreTarget.label)…"
        // Sidecar `load` phase: a no-op relaunch if the sidecar wasn't
        // actually mid-load. Either way, restore the previous engine once
        // the (possibly fresh) process is up. This intentional kill does
        // not count toward SidecarClient's crash backoff or fire onDied.
        sidecarClient.cancelLoad { [weak self] in
            self?.beginLoad(target: restoreTarget, isSwitch: false)
        }
    }

    /// SidecarClient.onDied: the process terminated unexpectedly (crash,
    /// killed, etc). Reset in-flight state and surface a failure if this
    /// happened mid-provisioning; SidecarClient itself schedules a backoff
    /// restart, and onRespawned re-sends `load` once it relaunches.
    private func handleSidecarDied() {
        let wasMidProvisioning = appState.pendingMode != nil || !appState.sidecarReady
        appState.sidecarReady = false
        if isDictating || isFinalizing { abortDictation() }
        if wasMidProvisioning { appState.provisioningFailed = true }
        appState.sidecarStatus = "Sidecar stopped unexpectedly. Restarting…"
    }

    /// Stops capture (if running) and hides the indicator/card; shared by
    /// the sidecar-died and sidecar-error paths so a crash never leaves
    /// the mic tapped or the indicator stuck on screen.
    private func abortDictation() {
        if isDictating { audioCapture.stop() }
        isDictating = false
        isFinalizing = false
        isToggleActive = false
        utteranceCancelled = false
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
            guard ev.engine == currentLoadTarget.engine else { break } // stale ready from a superseded/cancelled attempt
            if let pending = appState.pendingMode {
                appState.mode = pending
                // Keep pendingMode set briefly so Settings' provisioning
                // view shows the "Everything's ready" checkmark before
                // reverting to the mode picker, instead of swapping away
                // the instant it becomes true.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    guard let self, self.appState.pendingMode == pending else { return } // superseded meanwhile
                    self.appState.pendingMode = nil
                }
            }
            appState.sidecarReady = true
            appState.provisioningFailed = false
            appState.sidecarStatus = sawProgressThisAttempt ? "Ready" : "Already downloaded"

        case "partial":
            guard let text = ev.text else { return }
            guard (isDictating || isFinalizing), !utteranceCancelled else { return }
            if utteranceHasTextTarget {
                partialTyper.partial(text)
                indicatorPanel.show(state: .transcribing)
            } else {
                transcriptCardShowing = true
                indicatorPanel.show(state: .transcriptCard(text: text, isFinal: false))
            }

        case "final":
            let text = ev.text ?? ""
            isFinalizing = false
            guard !utteranceCancelled else {
                if appState.mode == .streaming { partialTyper.final(text) } // no-op typing; still resets internal state
                return
            }
            let hasTarget = appState.mode == .streaming ? utteranceHasTextTarget : FocusTarget.hasFocusedTextInput()
            if hasTarget {
                if appState.mode == .streaming {
                    partialTyper.final(text)
                } else {
                    TextInserter.insert(text)
                }
                indicatorPanel.hide()
            } else if text.isEmpty {
                indicatorPanel.hide() // nothing was said: an empty card with a Copy button is noise
            } else {
                transcriptCardShowing = true
                indicatorPanel.show(state: .transcriptCard(text: text, isFinal: true))
            }

        case "error":
            if ev.code == "missing-streaming-deps" {
                appState.sidecarStatus = "Installing streaming components…"
                RuntimeSetup.installStreamingExtras(status: { [weak self] s in self?.appState.sidecarStatus = s }) { [weak self] ok in
                    guard let self, self.currentLoadTarget == .streaming else { return } // cancelled/superseded meanwhile
                    guard ok else {
                        self.appState.provisioningFailed = true
                        self.appState.sidecarStatus = "Streaming setup failed"
                        return
                    }
                    self.beginLoad(target: .streaming, isSwitch: self.appState.pendingMode != nil) // retry, now with deps installed
                }
            } else {
                // Never show a raw exception in the menu/status: log the
                // full message to stderr, surface a short human summary.
                FileHandle.standardError.write(Data("openvox: sidecar error: \(ev.message ?? "unknown")\n".utf8))
                if isDictating || isFinalizing {
                    abortDictation()
                    appState.sidecarStatus = "Transcription failed — try again"
                } else {
                    if !appState.sidecarReady { appState.provisioningFailed = true }
                    appState.sidecarStatus = "Setup failed — try again"
                }
            }

        default:
            break // "pong" and anything else: no action needed
        }
    }

    // MARK: - Dictation flow

    /// Cheap, synchronous prediction of whether a plain-key hotkey press
    /// would be accepted, called from INSIDE HotkeyMonitor's CGEventTap
    /// callback (via `canAcceptPress`) to decide the swallow/pass-through
    /// return value immediately. Only reads already-cached Bools -- never
    /// touches AVAudioEngine or the sidecar, both of which are slow enough
    /// to overrun the tap's callback timeout (that overrun is bug 1's root
    /// cause: see HotkeyMonitor.handle). The real accept/reject check runs
    /// again, for real, in hotkeyPressed() once the async hop lands; if
    /// that later disagrees (e.g. sidecarReady flips false in the gap) the
    /// key was already swallowed, but the indicator still reports it via
    /// the existing "not ready" / "Microphone unavailable" states.
    private func canAcceptPress() -> Bool {
        if isToggleActive { return true } // stopping an active toggle always succeeds
        guard !isFinalizing, !isDictating else { return false }
        return appState.dictationEnabled && appState.sidecarReady && appState.micPermissionGranted
    }

    /// Hybrid tap/hold: this only ever starts capture or handles a
    /// toggle-mode stop; hotkeyReleased() decides toggle vs hold-to-talk.
    /// Always runs async (dispatched by HotkeyMonitor), so it is free to
    /// do real work like starting AVAudioEngine.
    private func hotkeyPressed() {
        switch HotkeyEdge.decide(.press, isDictating: isDictating, isToggleActive: isToggleActive, heldFor: 0, synthesized: false, holdThreshold: Self.holdThreshold) {
        case .finish:
            isToggleActive = false
            finishDictation()
            return
        case .ignore:
            return // already mid-utterance (e.g. a stray repeat); don't restart
        case .start:
            break // fall through to the readiness checks below
        case .enterToggle:
            return // unreachable on a press edge; kept so both edges share one enum
        }

        guard !isFinalizing else { return }
        guard appState.dictationEnabled else { return }
        guard appState.sidecarReady else {
            indicatorPanel.show(state: .notReady(appState.sidecarStatus))
            return
        }

        switch PermissionsHelper.micAuthorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            // First-ever dictation attempt: prompt right now. Never start
            // capture before this resolves -- an AVAudioEngine created
            // before the grant reports a permanently dead input format.
            PermissionsHelper.requestMic { [weak self] granted in self?.appState.micPermissionGranted = granted }
            indicatorPanel.show(state: .notReady("Requesting microphone access…"))
            return
        default:
            indicatorPanel.show(state: .notReady("Microphone access denied — check System Settings"))
            return
        }

        isDictating = true
        isToggleActive = false
        utteranceCancelled = false
        utteranceHasTextTarget = FocusTarget.hasFocusedTextInput()
        partialTyper.reset()
        do {
            try audioCapture.start(mode: appState.mode == .streaming ? .streaming : .offline)
            if appState.mode == .streaming, !utteranceHasTextTarget {
                transcriptCardShowing = true
                indicatorPanel.show(state: .transcriptCard(text: "", isFinal: false))
            } else {
                indicatorPanel.show(state: .listening(level: 0))
            }
        } catch {
            isDictating = false
            FileHandle.standardError.write(Data("openvox: capture start failed: \(error)\n".utf8))
            indicatorPanel.show(state: .notReady("Microphone unavailable"))
        }
    }

    /// Key released. `heldFor` and `synthesized` come straight from
    /// HotkeyMonitor (see its onUp doc comment) -- `heldFor` is measured
    /// from CGEvent timestamps, never Date(), so it can't be skewed by the
    /// async hop between the tap callback and this call. A quick genuine
    /// tap (< holdThreshold) switches into toggle mode -- keep dictating,
    /// the next press stops. A longer hold, or any synthesized release,
    /// finishes now.
    private func hotkeyReleased(heldFor: TimeInterval, synthesized: Bool) {
        switch HotkeyEdge.decide(.release, isDictating: isDictating, isToggleActive: isToggleActive, heldFor: heldFor, synthesized: synthesized, holdThreshold: Self.holdThreshold) {
        case .ignore:
            break // toggle-stop already handled at press-time, or not dictating
        case .enterToggle:
            isToggleActive = true
        case .finish:
            finishDictation()
        case .start:
            break // unreachable on a release edge; kept so both edges share one enum
        }
    }

    /// Ends dictation and sends the utterance for transcription, guarded
    /// by captured samples/chunks (not wall time): a quick toggle-mode tap
    /// that starts dictation is not an accidental press, so this guard
    /// only ever runs once dictation actually ends.
    private func finishDictation() {
        guard isDictating else { return }
        isDictating = false
        isToggleActive = false
        let pcm = audioCapture.stop() // also flushes the streaming tail chunk, before finalize below
        let chunkCount = audioCapture.chunkCount

        if appState.mode == .streaming {
            guard chunkCount > 0 else { // no chunk was ever sent: skip finalize entirely
                indicatorPanel.hide()
                return
            }
            isFinalizing = true
            if utteranceHasTextTarget {
                indicatorPanel.show(state: .transcribing)
            } // else: the card is already showing live partials; leave it until `final` arrives
            sidecarClient.finalize()
        } else {
            guard pcm.count >= AudioCapture.minSamplesToTranscribe else { // accidental tap: too little audio to be real speech
                indicatorPanel.hide()
                return
            }
            isFinalizing = true
            indicatorPanel.show(state: .transcribing)
            sidecarClient.transcribe(pcm: pcm)
        }
    }

    /// Cancel key while dictating: discards the utterance. Fast mode stops
    /// capture with no transcribe op. Streaming still sends finalize (to
    /// reset the sidecar's stream state) but suppresses further typing --
    /// already-typed partials stay on screen.
    private func cancelDictation() {
        guard isDictating else { return }
        isDictating = false
        isToggleActive = false
        utteranceCancelled = true
        let mode = appState.mode
        audioCapture.stop() // discard whatever was captured
        indicatorPanel.hide()
        if mode == .streaming {
            partialTyper.cancel()
            isFinalizing = true // the eventual `final` is absorbed harmlessly (see handle(_:), utteranceCancelled)
            sidecarClient.finalize()
        }
    }

    /// The cancel key is swallowed either while dictating (discard the
    /// utterance) or while the transcript card is showing (dismiss it) --
    /// same physical key (default Escape) serves both, without the
    /// non-activating indicator panel ever needing to become key window.
    private func handleCancelKeyPress() {
        if isDictating {
            cancelDictation()
        } else if transcriptCardShowing {
            indicatorPanel.hide()
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
        guard appState.mode != .streaming || utteranceHasTextTarget else { return } // the card owns the indicator in this case
        indicatorPanel.show(state: .listening(level: level))
    }
}

/// Pure toggle/hold decision logic for one hotkey edge (press or release),
/// deliberately decoupled from AppDelegate/HotkeyMonitor state so
/// --selftest can exercise it directly without a live CGEventTap. All
/// durations are seconds derived from CGEvent timestamps (see
/// HotkeyMonitor), never Date() taken at handling time.
enum HotkeyEdge {
    enum Kind { case press, release }
    enum Action: Equatable { case start, enterToggle, finish, ignore }

    /// - synthesized: true only for a release manufactured by HotkeyMonitor
    ///   after a tap-disabled recovery -- the real key-up may have been
    ///   lost in the gap. Such a release must always finish (or, if nothing
    ///   was captured, finishDictation's own sample-count guard makes it a
    ///   no-op cancel), never enter toggle mode: entering toggle from a
    ///   fake release is exactly how a broken hold-to-talk turns every
    ///   press into click-to-toggle (bug 1).
    static func decide(_ kind: Kind, isDictating: Bool, isToggleActive: Bool, heldFor: TimeInterval, synthesized: Bool, holdThreshold: TimeInterval) -> Action {
        switch kind {
        case .press:
            if isToggleActive { return .finish } // stop the toggle-active utterance
            return isDictating ? .ignore : .start
        case .release:
            guard isDictating, !isToggleActive else { return .ignore } // toggle-stop already handled at press-time, or nothing to release
            if synthesized { return .finish }
            return heldFor < holdThreshold ? .enterToggle : .finish
        }
    }
}

private struct SettingsView: View {
    @Bindable var appState: AppState
    let onSelectMode: (AppState.Mode) -> Void
    let onCancelSwitch: () -> Void

    var body: some View {
        Form {
            Section("Dictation") {
                if let pending = appState.pendingMode {
                    ProvisioningView(appState: appState, mode: pending, onCancel: onCancelSwitch)
                } else if !appState.sidecarReady {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(appState.sidecarStatus).foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Mode", selection: Binding(
                        get: { appState.mode },
                        set: { onSelectMode($0) }
                    )) {
                        ForEach(AppState.Mode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            SetupFormSections(appState: appState)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
    }
}
