import Carbon.HIToolbox
import Cocoa

/// Hybrid tap/hold hotkey plus a separate cancel key, both via one active
/// session CGEventTap. Each key can be either a plain key (swallowed while
/// active, so it never types into the focused app) or a single modifier
/// such as Right Option, matched by keycode via flagsChanged.
final class HotkeyMonitor {
    var keyCode: CGKeyCode
    var cancelKeyCode: CGKeyCode

    /// Returns whether the press was accepted (dictation actually started
    /// or a toggle-stop was handled). A plain key is only swallowed when
    /// accepted; if rejected (not ready / finalizing) the event -- and its
    /// matching release -- pass through so the key still types normally.
    var onDown: (() -> Bool)?
    var onUp: (() -> Void)?

    /// Fired when the cancel key is pressed while `isCancelActiveProvider`
    /// returns true. A discrete action (not a start/stop pair): AppDelegate
    /// decides on press whether it means "discard the utterance" or
    /// "dismiss the transcript card".
    var onCancel: (() -> Void)?
    /// Whether the cancel key should be intercepted right now. False the
    /// rest of the time, so the default Escape still types/closes dialogs
    /// normally when nothing is dictating and no card is showing.
    var isCancelActiveProvider: (() -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkeyTracker = KeyTracker()
    private var cancelTracker = KeyTracker()

    /// Keycodes that only ever generate flagsChanged, never keyDown/keyUp.
    /// Caps Lock is listed for display purposes only -- the hotkey
    /// recorder excludes it (toggle key, no hold semantics).
    static let modifierNames: [CGKeyCode: String] = [
        54: "Right Command", 55: "Command", 56: "Shift", 57: "Caps Lock",
        58: "Option", 59: "Control", 60: "Right Shift", 61: "Right Option",
        62: "Right Control", 63: "Fn",
    ]

    init(keyCode: CGKeyCode, cancelKeyCode: CGKeyCode) {
        self.keyCode = keyCode
        self.cancelKeyCode = cancelKeyCode
    }

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: refcon
        ) else {
            FileHandle.standardError.write(Data("openvox: failed to create event tap (Accessibility permission missing?)\n".utf8))
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        self.tap = nil
        runLoopSource = nil
        hotkeyTracker = KeyTracker()
        cancelTracker = KeyTracker()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The tap disables itself if our callback is judged too slow, or if
        // the user toggles it off in System Settings > Accessibility. Both
        // cases arrive as control events on this same callback; re-enable
        // and pass the event through untouched. If the hotkey was tracked
        // as down, we'll never see its real release now (the gap may have
        // eaten it), so synthesize onUp and reset local state rather than
        // leaving dictation stuck on. The cancel key needs no synthesized
        // follow-up: onCancel already fired at press-time.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let hotkeyWasDown = hotkeyTracker.isDown || hotkeyTracker.modifierIsDown
            hotkeyTracker = KeyTracker()
            cancelTracker = KeyTracker()
            if hotkeyWasDown { onUp?() }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard Self.modifierNames[code] != nil else { return Unmanaged.passUnretained(event) }
            if code == keyCode {
                // Do not derive down/up from the shared flag bit: holding
                // Left Option keeps .maskAlternate set while Right Option
                // (the configured key) is released, which would make a
                // mask-based read see "still down". Instead trust that a
                // flagsChanged event carrying this exact keycode is itself
                // the press/release edge for THIS key, and toggle.
                hotkeyTracker.modifierIsDown.toggle()
                if hotkeyTracker.modifierIsDown {
                    _ = onDown?() // modifiers don't type; accept/reject is irrelevant
                } else {
                    onUp?()
                }
            }
            if code == cancelKeyCode {
                cancelTracker.modifierIsDown.toggle()
                if cancelTracker.modifierIsDown, isCancelActiveProvider?() ?? false {
                    onCancel?()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if code == keyCode, Self.modifierNames[keyCode] == nil {
            return handlePlainKeyEvent(type: type, event: event, tracker: &hotkeyTracker, isActive: { true }, fire: { [weak self] in self?.onDown?() ?? true }, fireUp: { [weak self] in self?.onUp?() })
        }
        if code == cancelKeyCode, Self.modifierNames[cancelKeyCode] == nil {
            return handlePlainKeyEvent(type: type, event: event, tracker: &cancelTracker, isActive: { [weak self] in self?.isCancelActiveProvider?() ?? false }, fire: { [weak self] in self?.onCancel?(); return true }, fireUp: {})
        }
        return Unmanaged.passUnretained(event)
    }

    /// Shared press/release swallow-or-pass-through logic for a plain
    /// (non-modifier) key. `isActive()` decides, on the initial press,
    /// whether to swallow (and call `fire()`) or let the key pass through
    /// normally; key-repeat while already tracked keeps the same
    /// treatment. `fire()` returning false means "rejected" (pass through).
    private func handlePlainKeyEvent(
        type: CGEventType, event: CGEvent, tracker: inout KeyTracker,
        isActive: () -> Bool, fire: () -> Bool, fireUp: () -> Void
    ) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            if tracker.isDown || tracker.passedThrough {
                // Key-repeat while already tracked: keep the same treatment
                // as the initial press.
                return tracker.passedThrough ? Unmanaged.passUnretained(event) : nil
            }
            guard isActive() else {
                tracker.passedThrough = true
                return Unmanaged.passUnretained(event)
            }
            let accepted = fire()
            if accepted {
                tracker.isDown = true
                return nil // swallow: don't let the key type into the focused app
            } else {
                tracker.passedThrough = true
                return Unmanaged.passUnretained(event)
            }
        }
        if type == .keyUp {
            if tracker.passedThrough {
                tracker.passedThrough = false
                return Unmanaged.passUnretained(event) // matching release for a passed-through press
            }
            if tracker.isDown {
                tracker.isDown = false
                fireUp()
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

/// Down/up tracking for one plain or modifier key.
private struct KeyTracker {
    var isDown = false
    var passedThrough = false
    var modifierIsDown = false
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

/// Human-readable label for a keycode, used by the hotkey recorder UI.
enum KeyLabel {
    static func name(for keyCode: CGKeyCode) -> String {
        if let modifierName = HotkeyMonitor.modifierNames[keyCode] { return modifierName }
        return characterName(for: keyCode) ?? "Key \(keyCode)"
    }

    private static func characterName(for keyCode: CGKeyCode) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(base, UInt16(keyCode), UInt16(kUCKeyActionDown),
                                   0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                   &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
