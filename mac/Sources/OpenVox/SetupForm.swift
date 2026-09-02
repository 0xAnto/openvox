import SwiftUI

/// Onboarding step 4: the settings a new user must set before the first
/// dictation. Settings composes the same row groups (`PermissionRows`,
/// `ShortcutRows`, `MicrophoneInputPicker`, `IndicatorStylePicker`) into its
/// own sections, so a choice like Appearance stays out of setup.
struct SetupForm: View {
    @Bindable var appState: AppState

    var body: some View {
        // Three sections, no more: the setup window is a fixed 680 x 560,
        // and every row here has to be visible before Continue. The
        // indicator joins Dictation, since it only shows while dictating.
        Form {
            Section("Permissions") {
                PermissionRows(appState: appState, showsDivider: false)
            }

            Section {
                ShortcutRows(appState: appState, showsDivider: false)
                MicrophoneInputPicker(appState: appState)
                IndicatorStylePicker(appState: appState, label: "Indicator")
            } header: {
                Text("Dictation")
            } footer: {
                SectionFooter(ShortcutRows.cancelKeyFooter)
            }

            Section {
                Toggle("Launch OpenVox at Login", isOn: $appState.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}

/// Section footer text. macOS trails a footer under the control column;
/// under the rows it explains, a settings footer reads better leading.
struct SectionFooter: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum RecordingTarget: Equatable {
    case hotkey, cancelKey
}

/// The two shortcut rows and the recorder that captures a new chord. The
/// rows carry no `Section`, so each caller groups them its own way.
struct ShortcutRows: View {
    @Bindable var appState: AppState
    /// Settings stacks these in a `cardBackground()` card, where a
    /// `Divider()` marks the row boundary. The native `Form` in `SetupForm`
    /// draws its own row separation, so it opts out.
    var showsDivider = true

    static let cancelKeyFooter = "Press the cancel key while dictating to stop. Fast mode inserts nothing."

    @State private var recordingTarget: RecordingTarget?
    @State private var recordingMonitor: Any?
    @State private var capturedHotkeyCodes: Set<CGKeyCode> = []
    @State private var pressedHotkeyCodes: Set<CGKeyCode> = []
    /// Full releases of the captured chord so far (double/triple tap).
    @State private var hotkeyTapCount = 0
    /// Pending single/double-tap commit, waiting one tap window for another tap.
    @State private var hotkeyCommit: DispatchWorkItem?

    var body: some View {
        Group {
            SettingsRow("Hold to dictate") {
                HStack(spacing: 8) {
                    Text(KeyLabel.name(for: appState.hotkey))
                        .foregroundStyle(.secondary)
                    Button(recordingTarget == .hotkey ? "Press or double-tap…" : "Change") {
                        startRecording(.hotkey)
                    }
                    .disabled(recordingTarget != nil)
                    Button("Reset") { appState.hotkey = AppState.defaultHotkey }
                        .disabled(recordingTarget != nil || appState.hotkey == AppState.defaultHotkey)
                }
            }

            if showsDivider { Divider() }

            SettingsRow("Cancel key") {
                HStack(spacing: 8) {
                    Text(KeyLabel.name(for: appState.cancelKeyCode))
                        .foregroundStyle(.secondary)
                    Button(recordingTarget == .cancelKey ? "Press a key…" : "Change") {
                        startRecording(.cancelKey)
                    }
                    .disabled(recordingTarget != nil)
                    Button("Reset") { appState.cancelKeyCode = AppState.defaultCancelKeyCode }
                        .disabled(recordingTarget != nil || appState.cancelKeyCode == AppState.defaultCancelKeyCode)
                }
            }
        }
        // The window is kept alive after close, so do not rely on
        // onDisappear alone: a recording left armed would keep the global
        // hotkey suppressed and rebind it to the next key pressed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stopRecording() }
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ target: RecordingTarget) {
        stopRecording()
        recordingTarget = target
        capturedHotkeyCodes = []
        pressedHotkeyCodes = []
        appState.isRecordingShortcut = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard recordingTarget == target else { return event }
            let code = CGKeyCode(event.keyCode)
            if code == 57 { return event } // Caps Lock is a toggle key, no hold semantics -- not a valid hotkey/cancel key

            switch target {
            case .cancelKey:
                // Cancel remains a single discrete key. The first key-down
                // or modifier press commits it immediately.
                guard event.type == .keyDown || HotkeyMonitor.modifierNames[code] != nil else { return event }
                appState.cancelKeyCode = code
                stopRecording()

            case .hotkey:
                if event.type == .keyDown {
                    // A conventional modifier+plain-key shortcut commits on
                    // the plain key-down, after all held modifiers have been
                    // collected from their flagsChanged presses.
                    hotkeyCommit?.cancel()
                    capturedHotkeyCodes.insert(code)
                    commitHotkeyRecording(tapCount: 1)
                } else {
                    guard HotkeyMonitor.modifierNames[code] != nil else { return event }
                    if pressedHotkeyCodes.contains(code) {
                        pressedHotkeyCodes.remove(code)
                        if pressedHotkeyCodes.isEmpty { hotkeyChordReleased() }
                    } else {
                        if hotkeyCommit != nil, !capturedHotkeyCodes.contains(code) {
                            // A different chord after a full release starts over.
                            capturedHotkeyCodes = []
                            hotkeyTapCount = 0
                        }
                        hotkeyCommit?.cancel()
                        hotkeyCommit = nil
                        pressedHotkeyCodes.insert(code)
                        capturedHotkeyCodes.insert(code)
                    }
                }
            }
            return nil
        }
    }

    /// Modifier-only chords commit once fully released (so Right Command +
    /// Right Option is captured as a pair), after one tap window in which
    /// another tap of the same chord makes it a double or triple tap. The
    /// third tap commits at once; the recorder caps at three.
    private func hotkeyChordReleased() {
        hotkeyTapCount += 1
        if hotkeyTapCount >= 3 {
            commitHotkeyRecording(tapCount: 3)
            return
        }
        let tapCount = hotkeyTapCount
        let commit = DispatchWorkItem { commitHotkeyRecording(tapCount: tapCount) }
        hotkeyCommit = commit
        DispatchQueue.main.asyncAfter(deadline: .now() + HotkeyMonitor.tapWindow, execute: commit)
    }

    private func commitHotkeyRecording(tapCount: Int) {
        guard !capturedHotkeyCodes.isEmpty else { return }
        appState.hotkey = HotkeyShortcut(capturedHotkeyCodes, tapCount: tapCount)
        stopRecording()
    }

    private func stopRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        recordingTarget = nil
        hotkeyCommit?.cancel()
        hotkeyCommit = nil
        hotkeyTapCount = 0
        capturedHotkeyCodes = []
        pressedHotkeyCodes = []
        appState.isRecordingShortcut = false
    }
}

/// The input device a dictation records from.
struct MicrophoneInputPicker: View {
    @Bindable var appState: AppState

    @State private var devices: [(uid: String, name: String)] = []

    var body: some View {
        SettingsRow("Microphone") {
            Picker("Microphone", selection: Binding(
                get: { appState.micDeviceUID ?? "" },
                set: { appState.micDeviceUID = $0.isEmpty ? nil : $0 }
            )) {
                Text("System Default").tag("")
                ForEach(devices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
        }
        .onAppear { devices = AudioCapture.inputDevices() }
    }
}

/// Indicator colour. Onboarding and Settings show the same choice. Setup
/// names the row "Indicator" because it sits inside the Dictation section;
/// Settings gives it a section of its own and names the row "Style".
struct IndicatorStylePicker: View {
    @Bindable var appState: AppState
    var label = "Style"

    static let footer = "Neutral reads dark on a light panel and white on a dark panel."

    var body: some View {
        SettingsRow(label) {
            Picker(label, selection: $appState.indicatorAccent) {
                Text("Accent").tag(true)
                Text("Neutral").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
    }
}

/// Microphone and Accessibility, with the poll that keeps both rows and
/// onboarding's Continue button current while the user is in System
/// Settings.
struct PermissionRows: View {
    @Bindable var appState: AppState
    /// Settings stacks these in a `cardBackground()` card, where a
    /// `Divider()` marks the row boundary. The native `Form` in `SetupForm`
    /// draws its own row separation, so it opts out.
    var showsDivider = true

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            PermissionRow(
                name: "Microphone",
                granted: appState.micPermissionGranted,
                buttonTitle: micIsUndecided ? "Grant Access" : "Open System Settings",
                action: {
                    // The system asks once per install. After a decision
                    // only the privacy pane can change it.
                    if micIsUndecided {
                        PermissionsHelper.requestMic { granted in appState.micPermissionGranted = granted }
                    } else {
                        PermissionsHelper.openMicPrivacySettings()
                    }
                }
            )
            if showsDivider { Divider() }
            PermissionRow(
                name: "Accessibility",
                granted: appState.accessibilityGranted,
                buttonTitle: "Open System Settings",
                action: {
                    _ = PermissionsHelper.isAccessibilityTrusted(prompt: true)
                    PermissionsHelper.openAccessibilitySettings()
                }
            )
        }
        .onAppear { refreshPermissions() }
        .onReceive(refreshTimer) { _ in refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Returning from System Settings does not always make the
            // existing window key again. Re-read TCC whenever OpenVox
            // becomes active so the permission row updates immediately.
            refreshPermissions()
        }
    }

    private var micIsUndecided: Bool {
        PermissionsHelper.micAuthorizationStatus() == .notDetermined
    }

    private func refreshPermissions() {
        appState.micPermissionGranted = PermissionsHelper.micAuthorized()
        appState.accessibilityGranted = PermissionsHelper.isAccessibilityTrusted()
    }
}

/// One permission: the state, and a way back to the pane that holds it. The
/// button stays after the grant so a user can revisit the pane. The text
/// carries the state; the icon only tints it.
private struct PermissionRow: View {
    let name: String
    let granted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        SettingsRow(name) {
            HStack(spacing: 8) {
                if granted {
                    Text("Granted")
                        .foregroundStyle(.green)
                } else {
                    Text("Not Granted")
                        .foregroundStyle(.secondary)
                }
                Button(buttonTitle, action: action)
            }
        }
    }
}
