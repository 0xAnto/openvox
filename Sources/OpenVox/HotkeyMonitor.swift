import Carbon.HIToolbox
import Cocoa

/// Hybrid tap/hold hotkey plus a separate cancel key, both via one active
/// session CGEventTap. Each key can be either a plain key (swallowed while
/// active, so it never types into the focused app) or a single modifier
/// such as Right Option, matched by keycode via flagsChanged.
final class HotkeyMonitor {
    var keyCode: CGKeyCode
    var cancelKeyCode: CGKeyCode

    /// Cheap, synchronous prediction of whether a plain-key hotkey press
    /// should be swallowed, evaluated INSIDE the tap callback. Must never
    /// touch AVAudioEngine or the sidecar -- see the comment on
    /// `handle(type:event:)` for why. The real accept/reject re-check (and
    /// all the actual work) happens afterwards, asynchronously, when
    /// `onDown` fires.
    var canAcceptPress: (() -> Bool)?
    /// Fired asynchronously (main queue) on a genuine or predicted-accepted
    /// press. Modifiers have no swallow decision to make, so they always
    /// fire this; plain keys only fire it when `canAcceptPress` said yes.
    var onDown: (() -> Void)?
    /// Fired asynchronously (main queue) on release. `heldFor` is the
    /// press-to-release duration measured from the CGEvents' own
    /// timestamps (never Date() at handling time), so the async hop can
    /// never inflate or deflate it. `synthesized` is true only when
    /// HotkeyMonitor manufactured this release itself after a
    /// tap-disabled recovery -- the real key-up may have been lost in the
    /// gap. A synthesized release must always finish dictation, never
    /// enter toggle mode (see AppDelegate.HotkeyEdge).
    var onUp: ((_ heldFor: TimeInterval, _ synthesized: Bool) -> Void)?

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

    /// Runs INSIDE the CGEventTap callback, so it must do near-zero work:
    /// macOS disables a tap whose callback overruns its timeout budget,
    /// delivering .tapDisabledByTimeout. This used to run AppDelegate's
    /// dictation start/stop directly (including AVAudioEngine setup, which
    /// takes hundreds of ms) and that overrun was exactly what broke
    /// hold-to-talk: the tap got disabled while the hotkey was still held,
    /// the recovery below synthesized a release, and that fake release
    /// landed under the hold threshold and flipped into toggle mode on
    /// every press. Every AppDelegate-facing closure here is therefore
    /// only ever invoked via DispatchQueue.main.async; the only synchronous
    /// work is classifying the edge and (for a plain key) deciding
    /// swallow-or-pass-through from cheap cached state.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The tap disables itself if our callback is judged too slow, or if
        // the user toggles it off in System Settings > Accessibility. Both
        // cases arrive as control events on this same callback; re-enable
        // and pass the event through untouched. If the hotkey was tracked
        // as down, we'll never see its real release now (the gap may have
        // eaten it), so synthesize a release and reset local state rather
        // than leaving dictation stuck on. This synthesized release is
        // marked as such (never treated like a genuine quick tap) -- see
        // onUp's doc comment. The cancel key needs no synthesized
        // follow-up: onCancel already fired at press-time.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let hotkeyWasDown = hotkeyTracker.isDown || hotkeyTracker.modifierIsDown
            hotkeyTracker = KeyTracker()
            cancelTracker = KeyTracker()
            if hotkeyWasDown {
                DispatchQueue.main.async { [weak self] in self?.onUp?(0, true) }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard Self.modifierNames[code] != nil else { return Unmanaged.passUnretained(event) }
            let timestamp = event.timestamp
            if code == keyCode {
                // Do not derive down/up from the shared flag bit: holding
                // Left Option keeps .maskAlternate set while Right Option
                // (the configured key) is released, which would make a
                // mask-based read see "still down". Instead trust that a
                // flagsChanged event carrying this exact keycode is itself
                // the press/release edge for THIS key, and toggle.
                hotkeyTracker.modifierIsDown.toggle()
                if hotkeyTracker.modifierIsDown {
                    hotkeyTracker.downTimestamp = timestamp
                    DispatchQueue.main.async { [weak self] in self?.onDown?() } // modifiers don't type; no swallow decision needed
                } else {
                    let held = Self.seconds(from: hotkeyTracker.downTimestamp, to: timestamp)
                    DispatchQueue.main.async { [weak self] in self?.onUp?(held, false) }
                }
            }
            if code == cancelKeyCode {
                cancelTracker.modifierIsDown.toggle()
                if cancelTracker.modifierIsDown, isCancelActiveProvider?() ?? false {
                    DispatchQueue.main.async { [weak self] in self?.onCancel?() }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if code == keyCode, Self.modifierNames[keyCode] == nil {
            return handlePlainKeyEvent(
                type: type, event: event, tracker: &hotkeyTracker,
                isActive: { [weak self] in self?.canAcceptPress?() ?? false },
                fireDown: { [weak self] in self?.onDown?() },
                fireUp: { [weak self] held in self?.onUp?(held, false) }
            )
        }
        if code == cancelKeyCode, Self.modifierNames[cancelKeyCode] == nil {
            return handlePlainKeyEvent(
                type: type, event: event, tracker: &cancelTracker,
                isActive: { [weak self] in self?.isCancelActiveProvider?() ?? false },
                fireDown: { [weak self] in self?.onCancel?() },
                fireUp: { _ in }
            )
        }
        return Unmanaged.passUnretained(event)
    }

    /// Shared press/release swallow-or-pass-through logic for a plain
    /// (non-modifier) key. `isActive()` must be cheap (no AVAudioEngine, no
    /// sidecar work): it decides, on the initial press, whether to swallow
    /// (and dispatch `fireDown`) or let the key pass through normally;
    /// key-repeat while already tracked keeps the same treatment. Both
    /// `fireDown` and `fireUp` are dispatched via DispatchQueue.main.async,
    /// never called synchronously here.
    private func handlePlainKeyEvent(
        type: CGEventType, event: CGEvent, tracker: inout KeyTracker,
        isActive: () -> Bool, fireDown: @escaping () -> Void, fireUp: @escaping (TimeInterval) -> Void
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
            tracker.isDown = true
            tracker.downTimestamp = event.timestamp
            DispatchQueue.main.async(execute: fireDown)
            return nil // swallow: don't let the key type into the focused app
        }
        if type == .keyUp {
            if tracker.passedThrough {
                tracker.passedThrough = false
                return Unmanaged.passUnretained(event) // matching release for a passed-through press
            }
            if tracker.isDown {
                tracker.isDown = false
                let held = Self.seconds(from: tracker.downTimestamp, to: event.timestamp)
                DispatchQueue.main.async { fireUp(held) }
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// CGEventTimestamp is nanoseconds since boot. Computing the held
    /// duration from the events' own timestamps (rather than Date() taken
    /// whenever the async-dispatched handler happens to run) means the
    /// main-queue hop introduced above can never skew the measured hold
    /// length.
    private static func seconds(from start: CGEventTimestamp, to end: CGEventTimestamp) -> TimeInterval {
        guard end >= start else { return 0 }
        return TimeInterval(end - start) / 1_000_000_000
    }
}

/// Down/up tracking for one plain or modifier key.
private struct KeyTracker {
    var isDown = false
    var passedThrough = false
    var modifierIsDown = false
    /// CGEvent timestamp (nanoseconds since boot) of the press edge.
    var downTimestamp: CGEventTimestamp = 0
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

/// Human-readable label for a keycode, used by the hotkey recorder UI.
enum KeyLabel {
    /// Keys with no printable character, or whose layout-derived character
    /// is a non-printing control code (Escape, Return, Tab, arrows, ...),
    /// get an explicit name here. Without this, `characterName` still
    /// "succeeds" for these (UCKeyTranslate returns a real control
    /// character) and the recorder renders a blank/garbled label instead
    /// of a name -- this is the actual bug behind "the cancel key row
    /// doesn't show Escape": the Text view was always there, it just had
    /// nothing readable to show for keycode 53.
    static let namedKeys: [CGKeyCode: String] = [
        CGKeyCode(kVK_Escape): "Escape",
        CGKeyCode(kVK_Space): "Space",
        CGKeyCode(kVK_Tab): "Tab",
        CGKeyCode(kVK_Return): "Return",
        CGKeyCode(kVK_Delete): "Delete",
        CGKeyCode(kVK_ForwardDelete): "Forward Delete",
        CGKeyCode(kVK_LeftArrow): "Left Arrow",
        CGKeyCode(kVK_RightArrow): "Right Arrow",
        CGKeyCode(kVK_UpArrow): "Up Arrow",
        CGKeyCode(kVK_DownArrow): "Down Arrow",
        CGKeyCode(kVK_F1): "F1", CGKeyCode(kVK_F2): "F2", CGKeyCode(kVK_F3): "F3",
        CGKeyCode(kVK_F4): "F4", CGKeyCode(kVK_F5): "F5", CGKeyCode(kVK_F6): "F6",
        CGKeyCode(kVK_F7): "F7", CGKeyCode(kVK_F8): "F8", CGKeyCode(kVK_F9): "F9",
        CGKeyCode(kVK_F10): "F10", CGKeyCode(kVK_F11): "F11", CGKeyCode(kVK_F12): "F12",
    ]

    static func name(for keyCode: CGKeyCode) -> String {
        if let modifierName = HotkeyMonitor.modifierNames[keyCode] { return modifierName }
        if let named = namedKeys[keyCode] { return named }
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
