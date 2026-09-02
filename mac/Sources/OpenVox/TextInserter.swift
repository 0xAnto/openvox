import Cocoa

/// Inserts text into the focused app with the standard paste command.
/// Streaming partials are full transcripts (append-only), so only the new
/// suffix after what's already on screen gets inserted.
///
/// ponytail: no focus-target detection. The Accessibility API cannot see
/// into Chromium web content reliably (Chrome/Arc/Electron build their AX
/// tree lazily, and Slack/X composers came back as "no text field"), so
/// like Apple's own dictation we always insert into whatever has focus.
/// Add a heuristic only if stray pastes into non-text UI become a real
/// complaint.
enum TextInserter {
    // One shared pasteboard lease covers both a one-shot offline result and
    // the sequence of suffixes produced in streaming mode. Without this,
    // each partial would snapshot the preceding partial as the user's old
    // clipboard and overlapping restore timers would corrupt it.
    private static var savedPasteboardItems: [NSPasteboardItem]?
    private static var ownedPasteboardChangeCount: Int?
    private static var pasteGeneration = 0

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

    /// A real Cmd-V is understood by Cocoa, browser `contenteditable`
    /// editors, Electron, Catalyst, and terminal controls, and causes
    /// JavaScript editors to receive the same input events as an ordinary
    /// user paste.
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        pasteAndInsert(text)
    }

    /// Temporarily owns the pasteboard, sends Cmd-V, and restores the
    /// user's prior clipboard one second after the latest insertion. If
    /// the user copies something in the meantime, their new clipboard is
    /// never overwritten.
    static func pasteAndInsert(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Start a lease on the first insertion. If the user copied
        // something since our preceding partial, that new content becomes
        // the value restored at the end of this lease.
        let userChangedPasteboard = ownedPasteboardChangeCount.map { pasteboard.changeCount != $0 } ?? false
        if savedPasteboardItems == nil || userChangedPasteboard {
            savedPasteboardItems = snapshotPasteboardItems(pasteboard)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ownedPasteboardChangeCount = pasteboard.changeCount
        postCommandV()

        pasteGeneration &+= 1
        let generation = pasteGeneration
        let expectedChangeCount = ownedPasteboardChangeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard pasteGeneration == generation else { return }
            guard pasteboard.changeCount == expectedChangeCount else {
                // The user copied something after our last paste. Relinquish
                // the lease and leave their clipboard exactly as it is.
                savedPasteboardItems = nil
                ownedPasteboardChangeCount = nil
                return
            }
            let items = savedPasteboardItems ?? []
            pasteboard.clearContents()
            if !items.isEmpty {
                pasteboard.writeObjects(items)
            }
            savedPasteboardItems = nil
            ownedPasteboardChangeCount = nil
        }
    }

    private static func snapshotPasteboardItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        // Snapshot every type of every item, not just the plain string, so
        // restoring doesn't quietly drop rich text or a copied file.
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}

/// Tracks what's been inserted for the current utterance so streaming partials
/// only add their new suffix. One instance per utterance; call reset()
/// before starting a new one.
final class PartialTyper {
    private let insertText: (String) -> Void
    private var typed = ""
    private var stoppedPartials = false

    init(insertText: @escaping (String) -> Void = { TextInserter.insert($0) }) {
        self.insertText = insertText
    }

    func reset() {
        typed = ""
        stoppedPartials = false
    }

    /// ponytail: each partial is its own paste. If a slow target ever
    /// mixes suffixes (Cmd-V read after the next partial rewrote the
    /// pasteboard), coalesce partials that land within ~150 ms.
    func partial(_ full: String) {
        guard !stoppedPartials else { return }
        guard let suffix = TextInserter.suffixToType(typed: typed, full: full) else {
            stoppedPartials = true
            return
        }
        if !suffix.isEmpty { insertText(suffix) }
        typed = full
    }

    func final(_ full: String) {
        defer { reset() }
        if let suffix = TextInserter.suffixToType(typed: typed, full: full), !suffix.isEmpty {
            insertText(suffix)
        }
    }
}
