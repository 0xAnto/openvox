import Cocoa

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
        guard !text.isEmpty else { return }
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let end = min(i + maxUnitsPerEvent, units.count)
            postUnicode(Array(units[i..<end]))
            i = end
        }
    }

    private static func postUnicode(_ units: [UniChar]) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.post(tap: .cghidEventTap)
    }

    /// Offline finals over the threshold go through the pasteboard + a
    /// synthesized Cmd-V, since chunked key events for a long paragraph are
    /// slow and visually noisy.
    static func pasteAndInsert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postCommandV()
        // Restore the previous clipboard ~1 s later: gives the target app
        // time to read the pasteboard on paste before we put it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }
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

    func reset() {
        typed = ""
        stoppedPartials = false
    }

    func partial(_ full: String) {
        guard !stoppedPartials else { return }
        guard let suffix = TextInserter.suffixToType(typed: typed, full: full) else {
            stoppedPartials = true
            return
        }
        if !suffix.isEmpty { TextInserter.type(suffix) }
        typed = full
    }

    func final(_ full: String) {
        if let suffix = TextInserter.suffixToType(typed: typed, full: full), !suffix.isEmpty {
            TextInserter.type(suffix)
        }
        reset()
    }
}
