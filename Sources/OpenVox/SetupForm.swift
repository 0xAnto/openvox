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
                    Text(KeyLabel.name(for: appState.hotkeyKeyCode))
                        .foregroundStyle(.secondary)
                    Button(recordingTarget == .hotkey ? "Press a key…" : "Change") {
                        startRecording(.hotkey)
                    }
                    .disabled(recordingTarget != nil)
                    Button("Reset") { appState.hotkeyKeyCode = AppState.defaultHotkeyKeyCode }
                        .disabled(recordingTarget != nil || appState.hotkeyKeyCode == AppState.defaultHotkeyKeyCode)
                }
                HStack {
                    Text("Cancel key — press while dictating to discard")
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
    }

    private func refreshPermissions() {
        appState.micPermissionGranted = PermissionsHelper.micAuthorized()
        appState.accessibilityGranted = PermissionsHelper.isAccessibilityTrusted()
    }

    private func startRecording(_ target: RecordingTarget) {
        recordingTarget = target
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard recordingTarget == target else { return event }
            let code = CGKeyCode(event.keyCode)
            if code == 57 { return event } // Caps Lock is a toggle key, no hold semantics -- not a valid hotkey/cancel key
            // A plain key's own keyDown ends the recording; a modifier's
            // flagsChanged fires on both press and release, so only commit
            // on the press (flag now present in the event).
            if event.type == .flagsChanged, HotkeyMonitor.modifierNames[code] == nil { return event }
            switch target {
            case .hotkey: appState.hotkeyKeyCode = code
            case .cancelKey: appState.cancelKeyCode = code
            }
            recordingTarget = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            return nil
        }
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
