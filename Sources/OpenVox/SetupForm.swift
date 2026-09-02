import SwiftUI

/// The "essentials" form: permissions, hotkey, microphone, launch at login.
/// Used both as onboarding step 4 (standalone, via `SetupForm`) and inside
/// the Settings window (composed alongside a mode picker, via
/// `SetupFormSections`) -- one set of sections, two homes.
struct SetupForm: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            SetupFormSections(appState: appState)
        }
        .formStyle(.grouped)
    }
}

private enum RecordingTarget: Equatable {
    case hotkey, cancelKey
}

struct SetupFormSections: View {
    @Bindable var appState: AppState

    @State private var devices: [(uid: String, name: String)] = []
    @State private var recordingTarget: RecordingTarget?
    @State private var recordingMonitor: Any?
    @State private var capturedHotkeyCodes: Set<CGKeyCode> = []
    @State private var pressedHotkeyCodes: Set<CGKeyCode> = []
    /// Full releases of the captured chord so far (double/triple tap).
    @State private var hotkeyTapCount = 0
    /// Pending single/double-tap commit, waiting one tap window for another tap.
    @State private var hotkeyCommit: DispatchWorkItem?

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            Section("Permissions") {
                PermissionRow(
                    name: "Microphone",
                    granted: appState.micPermissionGranted,
                    grantTitle: "Grant Access",
                    action: { PermissionsHelper.requestMic { granted in appState.micPermissionGranted = granted } }
                )
                PermissionRow(
                    name: "Accessibility",
                    granted: appState.accessibilityGranted,
                    grantTitle: "Open System Settings",
                    action: {
                        _ = PermissionsHelper.isAccessibilityTrusted(prompt: true)
                        PermissionsHelper.openAccessibilitySettings()
                    }
                )
            }

            Section("Hotkey") {
                HStack {
                    Text("Hold to dictate")
                    Spacer()
                    Text(KeyLabel.name(for: appState.hotkey))
                        .foregroundStyle(.secondary)
                    Button(recordingTarget == .hotkey ? "Press or double-tap…" : "Change") {
                        startRecording(.hotkey)
                    }
                    .disabled(recordingTarget != nil)
                    Button("Reset") { appState.hotkey = AppState.defaultHotkey }
                        .disabled(recordingTarget != nil || appState.hotkey == AppState.defaultHotkey)
                }
                HStack {
                    Text("Cancel key — press while dictating to stop (Fast mode inserts nothing)")
                    Spacer()
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

            Section("Microphone") {
                Picker("Input", selection: Binding(
                    get: { appState.micDeviceUID ?? "" },
                    set: { appState.micDeviceUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("System Default").tag("")
                    ForEach(devices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }

            Section("Indicator") {
                Picker("Style", selection: $appState.indicatorAccent) {
                    Text("Accent").tag(true)
                    Text("White").tag(false)
                }
                .pickerStyle(.segmented)
            }

            Section("Startup") {
                Toggle("Launch OpenVox at Login", isOn: $appState.launchAtLogin)
            }
        }
        .onAppear {
            devices = AudioCapture.inputDevices()
            refreshPermissions()
        }
        .onReceive(refreshTimer) { _ in refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshPermissions()
        }
        // The window is kept alive after close, so do not rely on
        // onDisappear alone: a recording left armed would keep the global
        // hotkey suppressed and rebind it to the next key pressed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stopRecording() }
        .onDisappear { stopRecording() }
    }

    private func refreshPermissions() {
        appState.micPermissionGranted = PermissionsHelper.micAuthorized()
        appState.accessibilityGranted = PermissionsHelper.isAccessibilityTrusted()
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

private struct PermissionRow: View {
    let name: String
    let granted: Bool
    let grantTitle: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(granted ? "Granted" : "Not Granted")
                .foregroundStyle(granted ? .green : .secondary)
            if !granted {
                Button(grantTitle, action: action)
            }
        }
    }
}
