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
    private var productController: ProductWindowController?
    private let productNavigation = ProductNavigation()
    private var screenshotRun: ScreenshotRun?

    private static let holdThreshold: TimeInterval = 0.35

    private var isDictating = false
    private var isFinalizing = false
    /// True once a quick tap (held < holdThreshold) has switched this
    /// utterance into toggle mode: the next hotkey press stops it, rather
    /// than starting a new one.
    private var isToggleActive = false
    private var sawProgressThisAttempt = false
    /// Set when capture starts, cleared when it ends. finishDictation turns
    /// it into pendingDuration, which handleFinal records with the text.
    private var dictationStartedAt: Date?
    private var pendingDuration: TimeInterval?

    override init() {
        hotkeyMonitor = HotkeyMonitor(shortcut: AppState.defaultHotkey, cancelKeyCode: AppState.defaultCancelKeyCode)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Login-item launches include the `lgit` parameter in their open-app
        // Apple event. They should start dictation quietly without forcing a
        // dashboard over whatever the user is doing at sign-in.
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(0x6C676974)) != nil

        // Explicit launches start as a regular Dock app. Login-item launches
        // stay quietly in the menu bar until the user opens a destination.
        NSApp.setActivationPolicy(launchedAtLogin ? .accessory : .regular)

        indicatorPanel = IndicatorPanel()
        indicatorPanel.accent = appState.indicatorAccent
        applyAppearance() // the capsule follows the theme from the first frame
        if CommandLine.arguments.contains("--indicator-demo") { runIndicatorDemo() }
        buildStatusItem()
        buildMainMenu()
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let window = note.object as? NSWindow { self?.appWindowWillClose(window) }
        }
        hotkeyMonitor.shortcut = appState.hotkey
        hotkeyMonitor.cancelKeyCode = appState.cancelKeyCode
        hotkeyMonitor.canAcceptPress = { [weak self] in self?.canAcceptPress() ?? false }
        hotkeyMonitor.onDown = { [weak self] in self?.hotkeyPressed() }
        hotkeyMonitor.onUp = { [weak self] heldFor, synthesized in self?.hotkeyReleased(heldFor: heldFor, synthesized: synthesized) }
        hotkeyMonitor.onCancel = { [weak self] in self?.cancelDictation() }
        hotkeyMonitor.isCancelActiveProvider = { [weak self] in self?.isDictating ?? false }
        audioCapture.onChunk = { [weak self] chunk in self?.handleChunk(chunk) }
        audioCapture.onLevel = { [weak self] level in self?.handleLevel(level) }

        appState.onHotkeyChange = { [weak self] shortcut in self?.hotkeyMonitor.shortcut = shortcut }
        appState.onCancelKeyCodeChange = { [weak self] code in self?.hotkeyMonitor.cancelKeyCode = code }
        appState.onMicDeviceChange = { [weak self] uid in self?.audioCapture.setInputDevice(uid: uid) }
        appState.onDictationEnabledChange = { [weak self] enabled in self?.applyDictationEnabled(enabled) }
        appState.onIndicatorAccentChange = { [weak self] on in self?.indicatorPanel.accent = on }
        appState.onAppearanceChange = { [weak self] _ in self?.applyAppearance() }
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
            if sidecarClient.start() {
                beginLoad(target: appState.mode, isSwitch: false)
            }
            if !launchedAtLogin {
                // An explicit launch always lands on Home. Home surfaces a
                // missing Accessibility grant in its status card, so the
                // page never has to hand the user off to Settings first.
                openHome()
            }
            startScreenshotRunIfRequested()
        } else {
            showOnboarding()
        }
    }

    /// `OpenVox --screenshots <dir> [--themes light,dark]`: capture every
    /// page, theme, and size for a pull request, then quit. `--themes system`
    /// lets a shell flip the macOS appearance mid-run to prove the windows
    /// follow it live. Restores the saved theme on exit.
    private func startScreenshotRunIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--screenshots"), flag + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[flag + 1])
        var themes: [AppState.Appearance] = [.light, .dark]
        if let themesFlag = arguments.firstIndex(of: "--themes"), themesFlag + 1 < arguments.count {
            themes = arguments[themesFlag + 1].split(separator: ",").compactMap { AppState.Appearance(rawValue: String($0)) }
        }
        let savedAppearance = appState.appearance
        let run = ScreenshotRun(directory: directory, themes: themes, hooks: .init(
            window: { [weak self] in self?.productController?.window },
            show: { [weak self] page in self?.productNavigation.selection = page },
            openNewestEntry: { [weak self] in
                guard let self else { return }
                self.productNavigation.openHistory(entry: self.appState.history.last?.id)
            },
            setAppearance: { [weak self] appearance in self?.appState.appearance = appearance },
            showOnboarding: { [weak self] in
                self?.showOnboarding()
                return self?.onboardingController?.window
            },
            indicator: indicatorPanel
        ))
        screenshotRun = run
        run.start { [weak self] in
            self?.appState.appearance = savedAppearance
            NSApp.terminate(nil)
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
    /// four items; a status row only appears when there's something to
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
        let history = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

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
        showProductWindow(section: .settings)
    }

    @objc private func openHistory() {
        showProductWindow(section: .history)
    }

    @objc private func openHome() {
        showProductWindow(section: .home)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - App windows

    private func showProductWindow(section: ProductNavigation.Destination) {
        if productController == nil {
            productController = ProductWindowController(
                appState: appState,
                navigation: productNavigation,
                onSelectMode: { [weak self] mode in self?.requestModeSwitch(mode) },
                onCancelSwitch: { [weak self] in self?.cancelModeSwitch() },
                onRetryLoad: { [weak self] in
                    guard let self else { return }
                    if self.sidecarClient.start() {
                        self.beginLoad(target: self.appState.mode, isSwitch: false)
                    }
                }
            )
            applyAppearance()
        }
        productNavigation.selection = section
        if let productController { present(productController) }
    }

    /// Sets the chosen theme on the windows this app creates, including the
    /// floating indicator. It leaves NSApp.appearance alone: forcing it would
    /// tint the template menu-bar icon against the app theme instead of the
    /// menu bar. System leaves each window at nil, so macOS switches them
    /// live.
    private func applyAppearance() {
        let appearance = appState.appearance.nsAppearance
        productController?.window?.appearance = appearance
        onboardingController?.window?.appearance = appearance
        indicatorPanel?.appearance = appearance
    }

    private func present(_ controller: NSWindowController) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Closing the final OpenVox window returns the app to its lightweight
    /// menu-bar state. Quit remains the explicit way to stop dictation and
    /// remove the menu-bar item.
    private func appWindowWillClose(_ closing: NSWindow) {
        let otherWindows = [onboardingController?.window, productController?.window]
            .compactMap { $0 }
            .filter { $0 !== closing }

        if !otherWindows.contains(where: { $0.isVisible || $0.isMiniaturized }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Dock icon click, or launching the app again, with no window open:
    /// bring back Setup or the unified Home window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if appState.setupCompleted { openHome() } else { showOnboarding() }
        }
        return true
    }

    /// Standard macOS menus keep familiar shortcuts and responder-chain
    /// editing behavior available throughout the regular Dock app.
    private func buildMainMenu() {
        let appMenu = NSMenu(title: "OpenVox")
        appMenu.addItem(withTitle: "About OpenVox", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "").target = NSApp
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())

        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide OpenVox", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").target = NSApp
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "").target = NSApp
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OpenVox", action: #selector(quit), keyEquivalent: "q").target = self

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(
                appState: appState,
                onDownload: { [weak self] mode in self?.startOnboardingProvisioning(mode: mode) },
                onFinish: { [weak self] in self?.finishOnboarding() }
            )
            applyAppearance()
        }
        if let onboardingController { present(onboardingController) }
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
            if self.sidecarClient.start() {
                self.beginLoad(target: mode, isSwitch: false)
            }
        }
    }

    private func finishOnboarding() {
        appState.setupCompleted = true
        onboardingController?.close()
        onboardingController = nil
        openHome()
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

    /// Stops capture (if running) and hides the indicator; shared by
    /// the sidecar-died and sidecar-error paths so a crash never leaves
    /// the mic tapped or the indicator stuck on screen.
    private func abortDictation() {
        if isDictating { audioCapture.stop() }
        isDictating = false
        dictationStartedAt = nil
        pendingDuration = nil
        isFinalizing = false
        isToggleActive = false
        indicatorPanel.hide()
    }

    private func handle(_ ev: SidecarEventMessage) {
        switch ev.ev {
        case "progress":
            handleProgress(ev)
        case "ready":
            handleReady(ev)
        case "partial":
            handlePartial(ev)
        case "final":
            handleFinal(ev)
        case "error":
            handleError(ev)
        default:
            break // "pong" and anything else: no action needed
        }
    }

    private func handleProgress(_ ev: SidecarEventMessage) {
        sawProgressThisAttempt = true
        appState.progressStage = ev.stage
        appState.progressPct = ev.pct
        appState.sidecarStatus = ev.stage == "download" ? "Downloading model…" : "Loading…"
    }

    private func handleReady(_ ev: SidecarEventMessage) {
        guard ev.engine == currentLoadTarget.engine else { return } // stale ready from a superseded/cancelled attempt
        if let pending = appState.pendingMode {
            appState.mode = pending
            // Keep pendingMode set briefly so Settings' provisioning view
            // shows the success checkmark before returning to the picker.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.appState.pendingMode == pending else { return } // superseded meanwhile
                self.appState.pendingMode = nil
            }
        }
        appState.sidecarReady = true
        appState.provisioningFailed = false
        appState.sidecarStatus = sawProgressThisAttempt ? "Ready" : "Already downloaded"
    }

    private func handlePartial(_ ev: SidecarEventMessage) {
        guard let text = ev.text else { return }
        guard isDictating || isFinalizing else { return }
        partialTyper.partial(text)
        // The words are already landing on screen; the indicator stays in
        // listening until the key is released (finishDictation).
    }

    private func handleFinal(_ ev: SidecarEventMessage) {
        guard isFinalizing else { return } // ignore a stale result after cancellation or teardown
        let text = ev.text ?? ""
        isFinalizing = false
        let duration = pendingDuration
        pendingDuration = nil // an empty result must not leak its duration into the next dictation
        if !text.isEmpty { appState.recordDictation(text, duration: duration) }

        // Start closing the indicator before the paste so the tick is
        // already leaving when the text lands.
        if text.isEmpty { indicatorPanel.hide() } else { indicatorPanel.show(state: .done) }
        if appState.mode == .streaming {
            partialTyper.final(text)
        } else {
            TextInserter.insert(text)
        }
    }

    private func handleError(_ ev: SidecarEventMessage) {
        guard ev.code != "missing-streaming-deps" else {
            installStreamingComponents()
            return
        }
        reportSidecarError(ev)
    }

    private func installStreamingComponents() {
        appState.sidecarStatus = "Installing streaming components…"
        RuntimeSetup.installStreamingExtras(status: { [weak self] status in
            self?.appState.sidecarStatus = status
        }) { [weak self] ok in
            guard let self, self.currentLoadTarget == .streaming else { return } // cancelled/superseded meanwhile
            guard ok else {
                self.appState.provisioningFailed = true
                self.appState.sidecarStatus = "Streaming setup failed"
                return
            }
            self.beginLoad(target: .streaming, isSwitch: self.appState.pendingMode != nil) // retry, now with deps installed
        }
    }

    private func reportSidecarError(_ ev: SidecarEventMessage) {
        // Never show a raw exception in the menu/status: log the full
        // message to stderr and surface a short human summary.
        FileHandle.standardError.write(Data("openvox: sidecar error: \(ev.message ?? "unknown")\n".utf8))
        if isDictating || isFinalizing {
            abortDictation()
            appState.sidecarStatus = "Transcription failed — try again"
            return
        }
        if !appState.sidecarReady { appState.provisioningFailed = true }
        appState.sidecarStatus = "Setup failed — try again"
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
        if appState.isRecordingShortcut { return false }
        if isToggleActive { return true } // stopping an active toggle always succeeds
        guard !isFinalizing, !isDictating else { return false }
        return appState.dictationEnabled && appState.sidecarReady && appState.micPermissionGranted
    }

    /// Hybrid tap/hold: this only ever starts capture or handles a
    /// toggle-mode stop; hotkeyReleased() decides toggle vs hold-to-talk.
    /// Always runs async (dispatched by HotkeyMonitor), so it is free to
    /// do real work like starting AVAudioEngine.
    private func hotkeyPressed() {
        guard !appState.isRecordingShortcut else { return }
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
        dictationStartedAt = Date()
        isToggleActive = false
        partialTyper.reset()
        do {
            try audioCapture.start(mode: appState.mode == .streaming ? .streaming : .offline)
            indicatorPanel.show(state: .listening(level: 0))
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
        pendingDuration = dictationStartedAt.map { Date().timeIntervalSince($0) }
        dictationStartedAt = nil
        isToggleActive = false
        let pcm = audioCapture.stop() // also flushes the streaming tail chunk, before finalize below
        let chunkCount = audioCapture.chunkCount

        if appState.mode == .streaming {
            guard chunkCount > 0 else { // no chunk was ever sent: skip finalize entirely
                indicatorPanel.hide()
                return
            }
            isFinalizing = true
            indicatorPanel.show(state: .transcribing)
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

    /// Cancel key while dictating. Streaming has already put the words on
    /// screen, so "discard" could only drop the last word: it stops exactly
    /// like releasing the key. Fast mode stops capture and inserts nothing.
    private func cancelDictation() {
        guard isDictating else { return }
        if appState.mode == .streaming {
            finishDictation()
            return
        }
        isDictating = false
        dictationStartedAt = nil
        pendingDuration = nil
        isToggleActive = false
        audioCapture.stop() // discard whatever was captured
        indicatorPanel.hide()
    }

    /// Called directly from AudioCapture's render-thread callback; must
    /// stay AppState-free. SidecarClient.stream is thread-safe (it just
    /// enqueues onto its own write queue).
    private func handleChunk(_ chunk: [Float]) {
        sidecarClient.stream(pcm: chunk)
    }

    /// ponytail: dev loop to tune the indicator without dictating
    /// (`OpenVox --indicator-demo`). Feeds simulated RMS at 30 Hz through
    /// the same show() calls the real path uses, then transcribes and ticks.
    private func runIndicatorDemo() {
        var cycleStart = Date()
        var sentDone = false
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = Date().timeIntervalSince(cycleStart)
            let state: IndicatorState?
            switch t {
            case ..<2.4: // silence: room noise only
                state = .listening(level: 0.005 + Float.random(in: 0...0.005))
            case ..<6.2: // speech: syllables grouped into words
                let syll = max(0, sin(t * 9.5)) * max(0, sin(t * 2.1 + 0.7) + 0.3)
                let word = (sin(t * 1.1) + 1) / 2 > 0.25 ? 1.0 : 0.15
                state = .listening(level: Float(min(1, 0.08 + syll * word * Double.random(in: 0.75...1.1))) / 6)
            case ..<8.3:
                state = .transcribing
            case ..<10.0:
                state = sentDone ? nil : .done
                sentDone = true
            default:
                cycleStart = Date(); sentDone = false
                state = nil
            }
            if let state { indicatorPanel.show(state: state) }
        }
    }

    private func handleLevel(_ level: Float) {
        guard isDictating else { return }
        appState.micLevel = level
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
