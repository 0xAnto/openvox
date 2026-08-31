import Carbon.HIToolbox
import Cocoa

/// Hold-to-talk hotkey via an active session CGEventTap. Supports either a
/// plain key (swallowed while dictating so it never types into the focused
/// app) or a single modifier such as Right Option, matched by keycode via
/// flagsChanged. Default: Right Option (keycode 61).
final class HotkeyMonitor {
    var keyCode: CGKeyCode
    /// Returns whether the press was accepted (dictation actually started).
    /// A plain key is only swallowed when accepted; if rejected (not
    /// ready / finalizing) the event -- and its matching release -- pass
    /// through so the key still types normally.
    var onDown: (() -> Bool)?
    var onUp: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var plainKeyIsDown = false
    private var plainKeyPassedThrough = false
    private var modifierIsDown = false

    /// Keycodes that only ever generate flagsChanged, never keyDown/keyUp.
    /// Caps Lock is listed for display purposes only -- the hotkey
    /// recorder excludes it (toggle key, no hold semantics).
    static let modifierNames: [CGKeyCode: String] = [
        54: "Right Command", 55: "Command", 56: "Shift", 57: "Caps Lock",
        58: "Option", 59: "Control", 60: "Right Shift", 61: "Right Option",
        62: "Right Control", 63: "Fn",
    ]

    init(keyCode: CGKeyCode) {
        self.keyCode = keyCode
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
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The tap disables itself if our callback is judged too slow, or if
        // the user toggles it off in System Settings > Accessibility. Both
        // cases arrive as control events on this same callback; re-enable
        // and pass the event through untouched. If the hotkey was tracked
        // as down, we'll never see its real release now (the gap may have
        // eaten it), so synthesize onUp and reset local state rather than
        // leaving dictation stuck on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let wasDown = plainKeyIsDown || modifierIsDown
            plainKeyIsDown = false
            plainKeyPassedThrough = false
            modifierIsDown = false
            if wasDown { onUp?() }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if code == keyCode, Self.modifierNames[code] != nil {
                // Do not derive down/up from the shared flag bit: holding
                // Left Option keeps .maskAlternate set while Right Option
                // (the configured key) is released, which would make a
                // mask-based read see "still down". Instead trust that a
                // flagsChanged event carrying this exact keycode is itself
                // the press/release edge for THIS key, and toggle.
                modifierIsDown.toggle()
                if modifierIsDown {
                    _ = onDown?() // modifiers don't type; accept/reject is irrelevant
                } else {
                    onUp?()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard Self.modifierNames[keyCode] == nil else {
            // Configured hotkey is a modifier; plain keyDown/keyUp are irrelevant.
            return Unmanaged.passUnretained(event)
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == keyCode else { return Unmanaged.passUnretained(event) }

        if type == .keyDown {
            if plainKeyIsDown || plainKeyPassedThrough {
                // Key-repeat while already tracked: keep the same treatment
                // as the initial press.
                return plainKeyPassedThrough ? Unmanaged.passUnretained(event) : nil
            }
            let accepted = onDown?() ?? true
            if accepted {
                plainKeyIsDown = true
                return nil // swallow: don't let the hotkey type into the focused app
            } else {
                plainKeyPassedThrough = true
                return Unmanaged.passUnretained(event) // rejected: let it type normally
            }
        }
        if type == .keyUp {
            if plainKeyPassedThrough {
                plainKeyPassedThrough = false
                return Unmanaged.passUnretained(event) // matching release for a passed-through press
            }
            if plainKeyIsDown {
                plainKeyIsDown = false
                onUp?()
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
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
