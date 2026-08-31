import Carbon.HIToolbox
import Cocoa

/// Hold-to-talk hotkey via an active session CGEventTap. Supports either a
/// plain key (swallowed while dictating so it never types into the focused
/// app) or a single modifier such as Right Option, matched by keycode via
/// flagsChanged. Default: Right Option (keycode 61).
final class HotkeyMonitor {
    var keyCode: CGKeyCode
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var plainKeyIsDown = false
    private var modifierIsDown = false

    /// Keycodes that only ever generate flagsChanged, never keyDown/keyUp.
    static let modifierNames: [CGKeyCode: String] = [
        54: "Right Command", 55: "Command", 56: "Shift", 57: "Caps Lock",
        58: "Option", 59: "Control", 60: "Right Shift", 61: "Right Option",
        62: "Right Control", 63: "Fn",
    ]

    private static func maskFor(_ keyCode: CGKeyCode) -> CGEventFlags {
        switch keyCode {
        case 55, 54: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 57: return .maskAlphaShift
        case 63: return .maskSecondaryFn
        default: return []
        }
    }

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
        // and pass the event through untouched.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged {
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if code == keyCode, Self.modifierNames[code] != nil {
                let mask = Self.maskFor(code)
                let down = !mask.isEmpty && event.flags.contains(mask)
                if down != modifierIsDown {
                    modifierIsDown = down
                    down ? onDown?() : onUp?()
                }
            }
            return Unmanaged.passRetained(event)
        }

        guard Self.modifierNames[keyCode] == nil else {
            // Configured hotkey is a modifier; plain keyDown/keyUp are irrelevant.
            return Unmanaged.passRetained(event)
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == keyCode else { return Unmanaged.passRetained(event) }

        if type == .keyDown {
            if !plainKeyIsDown {
                plainKeyIsDown = true
                onDown?()
            }
            return nil // swallow: don't let the hotkey type into the focused app
        }
        if type == .keyUp {
            plainKeyIsDown = false
            onUp?()
            return nil
        }
        return Unmanaged.passRetained(event)
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
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
