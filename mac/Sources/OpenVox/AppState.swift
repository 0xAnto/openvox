import AppKit
import CoreGraphics
import Foundation
import Observation
import ServiceManagement

/// A hold-to-dictate shortcut is a set of physical key codes. Keeping the
/// side-specific key codes (rather than only CGEventFlags) lets shortcuts
/// distinguish Right Command/Right Option from their left-hand variants.
struct HotkeyShortcut: Equatable {
    let keyCodes: Set<CGKeyCode>
    /// 1 = one press (hold or tap). 2 or 3 = press the same modifier chord
    /// that many times in quick succession; the last press is the one that
    /// is held or tapped. Only modifier-only chords can be multi-tap: the
    /// recorder commits plain-key shortcuts on their first key-down.
    let tapCount: Int

    init(_ keyCodes: Set<CGKeyCode>, tapCount: Int = 1) {
        precondition(!keyCodes.isEmpty, "a shortcut needs at least one key")
        self.keyCodes = keyCodes
        self.tapCount = max(1, tapCount)
    }

    init(keyCode: CGKeyCode) {
        self.init([keyCode])
    }
}

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
    static let defaultHotkey = HotkeyShortcut(keyCode: 61) // kVK_RightOption
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

    var hotkey: HotkeyShortcut {
        didSet {
            let storedCodes = hotkey.keyCodes.sorted().map(Int.init)
            UserDefaults.standard.set(storedCodes, forKey: Keys.hotkeyKeyCodes)
            UserDefaults.standard.set(hotkey.tapCount, forKey: Keys.hotkeyTapCount)
            onHotkeyChange?(hotkey)
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

    /// Window appearance: follow the system, or force light or dark.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        /// nil means follow the system.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// The app applies this to the windows it creates. The menu-bar item,
    /// the menus, and the indicator keep their own appearance: a template
    /// icon must follow the menu bar, and the indicator stays dark.
    var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
            onAppearanceChange?(appearance)
        }
    }

    /// Indicator colour: the macOS accent colour, or plain white light. Default accent.
    var indicatorAccent: Bool {
        didSet {
            UserDefaults.standard.set(indicatorAccent, forKey: Keys.indicatorAccent)
            onIndicatorAccentChange?(indicatorAccent)
        }
    }

    /// Finished dictations, oldest first. Pruned to `historyRetention` on
    /// load, on every record, and whenever the retention changes.
    var history: [DictationEntry]

    var historyRetention: HistoryRetention {
        didSet {
            UserDefaults.standard.set(historyRetention.rawValue, forKey: Keys.historyRetention)
            pruneHistory()
        }
    }

    func recordDictation(_ text: String, duration: TimeInterval?) {
        history.append(DictationEntry(date: Date(), text: text, duration: duration, mode: mode.rawValue))
        pruneHistory()
    }

    func deleteDictation(_ id: DictationEntry.ID) {
        history.removeAll { $0.id == id }
        DictationHistory.save(history)
    }

    func clearHistory() {
        history = []
        DictationHistory.save(history)
    }

    private func pruneHistory() {
        history = DictationHistory.prune(history, retention: historyRetention)
        DictationHistory.save(history)
    }

    var micLevel: Float = 0
    var micPermissionGranted = false
    /// Transient UI state used to suppress the currently configured global
    /// shortcut while Settings is listening for its replacement.
    var isRecordingShortcut = false

    /// Live status from the permission poll (SetupFormSections' 1 s timer).
    /// Flipping false -> true fires `onAccessibilityGranted`, so granting
    /// Accessibility during onboarding arms the hotkey immediately instead
    /// of only at next launch.
    var accessibilityGranted = false {
        didSet {
            if accessibilityGranted, !oldValue { onAccessibilityGranted?() }
        }
    }

    var onHotkeyChange: ((HotkeyShortcut) -> Void)?
    var onCancelKeyCodeChange: ((CGKeyCode) -> Void)?
    var onMicDeviceChange: ((String?) -> Void)?
    var onAccessibilityGranted: (() -> Void)?
    var onDictationEnabledChange: ((Bool) -> Void)?
    var onIndicatorAccentChange: ((Bool) -> Void)?
    var onAppearanceChange: ((Appearance) -> Void)?

    init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: Keys.mode) ?? "") ?? .fast
        setupCompleted = d.bool(forKey: Keys.setupCompleted)
        if let storedCodes = d.array(forKey: Keys.hotkeyKeyCodes) as? [Int], !storedCodes.isEmpty {
            hotkey = HotkeyShortcut(Set(storedCodes.map(CGKeyCode.init)), tapCount: d.integer(forKey: Keys.hotkeyTapCount)) // missing key reads 0, clamped to 1
        } else if let legacyKeyCode = d.object(forKey: Keys.hotkeyKeyCode) as? Int {
            // One-time migration from versions that only stored one key.
            hotkey = HotkeyShortcut(keyCode: CGKeyCode(legacyKeyCode))
        } else {
            hotkey = Self.defaultHotkey
        }
        let storedCancelKeyCode = d.object(forKey: Keys.cancelKeyCode) as? Int
        cancelKeyCode = storedCancelKeyCode.map { CGKeyCode($0) } ?? Self.defaultCancelKeyCode
        micDeviceUID = d.string(forKey: Keys.micDeviceUID)
        launchAtLogin = d.bool(forKey: Keys.launchAtLogin)
        dictationEnabled = d.object(forKey: Keys.dictationEnabled) as? Bool ?? true
        indicatorAccent = d.object(forKey: Keys.indicatorAccent) as? Bool ?? true
        appearance = Appearance(rawValue: d.string(forKey: Keys.appearance) ?? "") ?? .system
        let retention = HistoryRetention(rawValue: d.string(forKey: Keys.historyRetention) ?? "") ?? .days30
        historyRetention = retention
        let storedHistory = DictationHistory.load()
        history = DictationHistory.prune(storedHistory, retention: retention)
        // Honor the retention promise on disk too, not just in the list:
        // a user who shortens the window and never dictates again must
        // not keep the old entries around in the file.
        if history.count != storedHistory.count { DictationHistory.save(history) }
    }

    private enum Keys {
        static let mode = "mode"
        static let setupCompleted = "setupCompleted"
        static let hotkeyKeyCodes = "hotkeyKeyCodes"
        static let hotkeyTapCount = "hotkeyTapCount"
        /// Legacy single-key preference, read only for migration.
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let cancelKeyCode = "cancelKeyCode"
        static let micDeviceUID = "micDeviceUID"
        static let launchAtLogin = "launchAtLogin"
        static let dictationEnabled = "dictationEnabled"
        static let indicatorAccent = "indicatorAccent"
        static let appearance = "appearance"
        static let historyRetention = "historyRetention"
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
