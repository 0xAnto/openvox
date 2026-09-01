import CoreGraphics
import Foundation
import Observation
import ServiceManagement

/// Central, persisted app state. UserDefaults-backed settings plus the
/// live status the menu, indicator, and onboarding window all read from.
///
/// `mode` is the currently-confirmed/active engine (persisted); it only
/// changes once a switch actually succeeds. `pendingMode` is non-nil only
/// while an explicit user-initiated switch (via Settings) is being
/// provisioned -- nil during the very first launch's warm-up, since there's
/// no previous mode to fall back to there.
@Observable
final class AppState {
    static let defaultHotkeyKeyCode: CGKeyCode = 61 // kVK_RightOption
    static let defaultCancelKeyCode: CGKeyCode = 53 // kVK_Escape

    enum Mode: String, CaseIterable, Identifiable {
        case fast, streaming

        var id: String { rawValue }
        var label: String { self == .fast ? "Fast (Offline)" : "Streaming" }
        var engine: String { self == .fast ? "moonshine" : "nemotron" }
    }

    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) }
    }

    /// Non-nil only while an explicit Settings-initiated mode switch is
    /// provisioning. Nil during the initial post-launch warm-up.
    var pendingMode: Mode?
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

    /// Discards the in-progress utterance when pressed while dictating.
    /// Default Escape (keycode 53).
    var cancelKeyCode: CGKeyCode {
        didSet {
            UserDefaults.standard.set(Int(cancelKeyCode), forKey: Keys.cancelKeyCode)
            onCancelKeyCodeChange?(cancelKeyCode)
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

    /// Menu's "Enable Dictation" toggle: off means the hotkey tap is
    /// inactive and the indicator never shows. Default on.
    var dictationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(dictationEnabled, forKey: Keys.dictationEnabled)
            onDictationEnabledChange?(dictationEnabled)
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

    var onHotkeyKeyCodeChange: ((CGKeyCode) -> Void)?
    var onCancelKeyCodeChange: ((CGKeyCode) -> Void)?
    var onMicDeviceChange: ((String?) -> Void)?
    var onAccessibilityGranted: (() -> Void)?
    var onDictationEnabledChange: ((Bool) -> Void)?

    init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: Keys.mode) ?? "") ?? .fast
        setupCompleted = d.bool(forKey: Keys.setupCompleted)
        let storedKeyCode = d.object(forKey: Keys.hotkeyKeyCode) as? Int
        hotkeyKeyCode = storedKeyCode.map { CGKeyCode($0) } ?? Self.defaultHotkeyKeyCode
        let storedCancelKeyCode = d.object(forKey: Keys.cancelKeyCode) as? Int
        cancelKeyCode = storedCancelKeyCode.map { CGKeyCode($0) } ?? Self.defaultCancelKeyCode
        micDeviceUID = d.string(forKey: Keys.micDeviceUID)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        dictationEnabled = d.object(forKey: Keys.dictationEnabled) as? Bool ?? true
    }

    private enum Keys {
        static let mode = "mode"
        static let setupCompleted = "setupCompleted"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let cancelKeyCode = "cancelKeyCode"
        static let micDeviceUID = "micDeviceUID"
        static let launchAtLogin = "launchAtLogin"
        static let dictationEnabled = "dictationEnabled"
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
