import CoreGraphics
import Foundation
import Observation
import ServiceManagement

/// Central, persisted app state. UserDefaults-backed settings plus the
/// live status the menu, indicator, and onboarding window all read from.
///
/// `mode` is the user's selected/target mode (persisted, drives the menu
/// checkmark). `activeMode` is whichever engine is actually warm and ready
/// in the sidecar right now. They differ while a mode switch is being
/// provisioned; UI reads both to show "preparing" instead of lying about
/// which engine answers the hotkey.
@Observable
final class AppState {
    enum Mode: String, CaseIterable, Identifiable {
        case fast, streaming

        var id: String { rawValue }
        var label: String { self == .fast ? "Fast (Offline)" : "Streaming" }
        var engine: String { self == .fast ? "moonshine" : "nemotron" }
    }

    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) }
    }

    var activeMode: Mode?
    var sidecarReady = false
    var sidecarStatus = "Not started"
    var progressStage: String?
    var progressPct: Int?
    var provisioningFailed = false

    var setupCompleted: Bool {
        didSet { UserDefaults.standard.set(setupCompleted, forKey: Keys.setupCompleted) }
    }

    var hotkeyKeyCode: CGKeyCode {
        didSet {
            UserDefaults.standard.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode)
            onHotkeyKeyCodeChange?(hotkeyKeyCode)
        }
    }

    var micDeviceUID: String? {
        didSet {
            UserDefaults.standard.set(micDeviceUID, forKey: Keys.micDeviceUID)
            onMicDeviceChange?(micDeviceUID)
        }
    }

    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            LaunchAtLogin.set(launchAtLogin)
        }
    }

    var micLevel: Float = 0
    var micPermissionGranted = false

    /// Live status from the permission poll (SetupFormSections' 1 s timer).
    /// Flipping false -> true fires `onAccessibilityGranted`, so granting
    /// Accessibility during onboarding arms the hotkey immediately instead
    /// of only at next launch.
    var accessibilityGranted = false {
        didSet {
            if accessibilityGranted, !oldValue { onAccessibilityGranted?() }
        }
    }

    /// Hooked by AppDelegate: fires when the user picks a different mode
    /// (onboarding step 2's Download, or the Settings/menu mode picker).
    var onModeSelected: ((Mode) -> Void)?
    var onHotkeyKeyCodeChange: ((CGKeyCode) -> Void)?
    var onMicDeviceChange: ((String?) -> Void)?
    var onAccessibilityGranted: (() -> Void)?

    /// Sets the target mode and notifies AppDelegate to (re)provision it.
    /// A no-op if the mode is already selected, so re-clicking the current
    /// mode in the menu doesn't restart the sidecar.
    func selectMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        onModeSelected?(newMode)
    }

    init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: Keys.mode) ?? "") ?? .fast
        setupCompleted = d.bool(forKey: Keys.setupCompleted)
        let storedKeyCode = d.object(forKey: Keys.hotkeyKeyCode) as? Int
        hotkeyKeyCode = storedKeyCode.map { CGKeyCode($0) } ?? 61 // kVK_RightOption
        micDeviceUID = d.string(forKey: Keys.micDeviceUID)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
    }

    private enum Keys {
        static let mode = "mode"
        static let setupCompleted = "setupCompleted"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let micDeviceUID = "micDeviceUID"
        static let launchAtLogin = "launchAtLogin"
    }
}

enum LaunchAtLogin {
    static func set(_ enabled: Bool) {
        // Best-effort: SMAppService can throw when the app isn't running
        // from a stable /Applications install (common during development).
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            FileHandle.standardError.write(Data("openvox: launch-at-login change failed: \(error)\n".utf8))
        }
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
}
