import ApplicationServices
import Cocoa

/// Accessibility-based check for whether the system's currently focused UI
/// element looks like a text input.
///
/// Polarity: type unless we are CONFIDENT there is no target. Native AppKit
/// controls report a small, stable set of roles (AXTextField etc.), but
/// browser/Electron web inputs frequently report something else entirely --
/// AXWebArea, AXGroup, AXScrollArea, or a role with a subrole -- and Chrome
/// only exposes rich AX info under certain conditions. A role allow-list
/// (the old behavior) meant every one of those unrecognized-role cases fell
/// back to "no target", so dictating into a Slack or Twitter/X text field in
/// a browser produced the transcript card instead of typed text. We now
/// only refuse to type when a role is a KNOWN non-text control; everything
/// else (including total unknowns) is treated as a target, same as it
/// behaved before role detection existed.
enum FocusTarget {
    static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    /// Roles that are unambiguously NOT a place to type text. Anything not
    /// in this set (including AXWebArea/AXGroup and any role we don't
    /// recognize) falls through to "treat as a text target".
    static let nonTextRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXSlider", "AXImage", "AXStaticText", "AXRow", "AXCell", "AXTable",
        "AXList", "AXToolbar",
    ]

    /// Pure logic (no AX calls), exercised directly by --selftest. Mirrors
    /// hasFocusedTextInput()'s three-tier decision: a strong positive signal
    /// wins outright; otherwise a known-non-text role loses; otherwise
    /// (ambiguous/unknown) it's treated as a target.
    static func isTextTarget(role: String?, hasSelectedTextRange: Bool, valueIsSettable: Bool) -> Bool {
        if let role, textInputRoles.contains(role) { return true }
        if hasSelectedTextRange || valueIsSettable { return true } // the reliable signal for web/Electron editable content
        if let role, nonTextRoles.contains(role) { return false }
        return true // ambiguous: unknown role, AXWebArea/AXGroup, or a query failure below
    }

    static func hasFocusedTextInput() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2) // never hang on a wedged/sandboxed app

        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusStatus == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false // no focused element at all: definitely no target
        }
        let element = focusedRef as! AXUIElement // swiftlint:disable:this force_cast -- type checked above
        AXUIElementSetMessagingTimeout(element, 0.2)

        var roleRef: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleStatus == .success ? roleRef as? String : nil

        var rangeRef: CFTypeRef?
        let hasSelectedTextRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success

        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let valueIsSettable = settableStatus == .success && settable.boolValue

        return isTextTarget(role: role, hasSelectedTextRange: hasSelectedTextRange, valueIsSettable: valueIsSettable)
    }
}

/// Types text into the focused app via synthetic CGEvents. Streaming
/// partials are full transcripts (append-only), so only the new suffix
/// after what's already on screen gets typed.
enum TextInserter {
    static let maxUnitsPerEvent = 20
    static let pasteThreshold = 300

    /// Returns the suffix of `full` that comes after `typed`, or nil if
    /// `typed` is not a prefix of `full` (the never-observed mismatch case:
    /// caller should stop typing partials and let `final` supply the rest).
    static func suffixToType(typed: String, full: String) -> String? {
        let typedUnits = Array(typed.utf16)
        let fullUnits = Array(full.utf16)
        guard fullUnits.count >= typedUnits.count else { return nil }
        guard Array(fullUnits.prefix(typedUnits.count)) == typedUnits else { return nil }
        let suffixUnits = Array(fullUnits.suffix(from: typedUnits.count))
        return String(utf16CodeUnits: suffixUnits, count: suffixUnits.count)
    }

    /// Types `text` as a sequence of synthetic key events, at most 20 UTF-16
    /// units per event, posted to the HID event tap.
    static func type(_ text: String) {
        for chunk in chunks(for: text) {
            postUnicode(chunk)
        }
    }

    /// Splits `text` into UTF-16 chunks of at most `maxUnitsPerEvent`,
    /// backing a boundary off by one when it would fall between a high
    /// surrogate and its low surrogate (e.g. an emoji), so a pair is never
    /// split across two key events. Pure logic, exercised directly by
    /// --selftest.
    static func chunks(for text: String, maxUnitsPerEvent: Int = TextInserter.maxUnitsPerEvent) -> [[UniChar]] {
        guard !text.isEmpty else { return [] }
        let units = Array(text.utf16)
        var result: [[UniChar]] = []
        var i = 0
        while i < units.count {
            var end = min(i + maxUnitsPerEvent, units.count)
            if end < units.count, isHighSurrogate(units[end - 1]), isLowSurrogate(units[end]) {
                end -= 1
            }
            if end <= i { end = i + 1 } // defensive: never emit an empty/backwards chunk
            result.append(Array(units[i..<end]))
            i = end
        }
        return result
    }

    private static func isHighSurrogate(_ unit: UniChar) -> Bool { (0xD800...0xDBFF).contains(unit) }
    private static func isLowSurrogate(_ unit: UniChar) -> Bool { (0xDC00...0xDFFF).contains(unit) }

    private static func postUnicode(_ units: [UniChar]) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.post(tap: .cghidEventTap)
    }

    /// Single insertion dispatch point (type vs paste, by length), shared
    /// by the confirmed-text-target path and the transcript card's
    /// "Insert Anyway" button.
    static func insert(_ text: String) {
        if text.utf16.count > pasteThreshold {
            pasteAndInsert(text)
        } else {
            type(text)
        }
    }

    /// Offline finals over the threshold go through the pasteboard + a
    /// synthesized Cmd-V, since chunked key events for a long paragraph are
    /// slow and visually noisy.
    static func pasteAndInsert(_ text: String) {
        let pasteboard = NSPasteboard.general
        // Snapshot every type of every item, not just the plain string, so
        // restoring doesn't quietly drop e.g. rich text or a file the user
        // had copied.
        let previousItems: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount
        postCommandV()

        // Restore ~1 s later, but only if nothing else touched the
        // pasteboard meanwhile (e.g. the user copied something else) --
        // never clobber a copy that isn't ours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard pasteboard.changeCount == ourChangeCount else { return }
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                pasteboard.writeObjects(previousItems)
            }
        }
    }

    /// Plain pasteboard write for the transcript card's Copy button -- no
    /// snapshot/restore dance, the user explicitly asked for the copy.
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Tracks what's been typed for the current utterance so streaming partials
/// only add their new suffix. One instance per utterance; call reset()
/// before starting a new one.
final class PartialTyper {
    private var typed = ""
    private var stoppedPartials = false
    private var cancelled = false

    func reset() {
        typed = ""
        stoppedPartials = false
        cancelled = false
    }

    /// Discards the rest of this utterance: already-typed partials stay on
    /// screen, but further partial()/final() calls (including the
    /// finalize-triggered `final` that still arrives, to reset the
    /// sidecar's stream state) type nothing more.
    func cancel() {
        cancelled = true
    }

    func partial(_ full: String) {
        guard !stoppedPartials, !cancelled else { return }
        guard let suffix = TextInserter.suffixToType(typed: typed, full: full) else {
            stoppedPartials = true
            return
        }
        if !suffix.isEmpty { TextInserter.type(suffix) }
        typed = full
    }

    func final(_ full: String) {
        defer { reset() }
        guard !cancelled else { return }
        if let suffix = TextInserter.suffixToType(typed: typed, full: full), !suffix.isEmpty {
            TextInserter.type(suffix)
        }
    }
}
