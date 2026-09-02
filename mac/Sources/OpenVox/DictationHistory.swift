import Foundation

/// One finished, non-empty, non-cancelled dictation, recorded from the
/// sidecar's `final` event whether the text was typed into a target or
/// shown on the transcript card.
struct DictationEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    /// Seconds from shortcut press to release. Nil for entries recorded
    /// before v1.0.2.
    var duration: TimeInterval? = nil
    /// `AppState.Mode.rawValue`: "fast" or "streaming".
    var mode: String? = nil
}

/// How long recorded dictations stay. `days == nil` keeps them forever.
enum HistoryRetention: String, CaseIterable, Identifiable {
    case days7, days30, forever

    var id: String { rawValue }

    /// The picker label. It reads the same words as `phrase`, capitalised
    /// for a standalone control.
    var label: String {
        self == .forever ? "All time" : phrase
    }

    /// The window in lowercase, for use mid-sentence: "Keeping dictations
    /// for 30 days".
    var phrase: String {
        switch self {
        case .days7: "7 days"
        case .days30: "30 days"
        case .forever: "all time"
        }
    }

    var days: Int? {
        switch self {
        case .days7: 7
        case .days30: 30
        case .forever: nil
        }
    }
}

/// On-disk history: a single JSON array next to the runtime RuntimeSetup
/// installs.
// ponytail: whole-file rewrite on every change; dictations are rare and
// short. Move to an append-only log or SQLite if an all-time history ever
// grows past a few MB.
enum DictationHistory {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OpenVox/history.json")

    /// Drops entries older than the retention window. Calendar days, not
    /// 86 400 s multiples, so a DST shift can't move the boundary. Pure so
    /// --selftest can pin the boundary without touching the clock or disk.
    static func prune(_ entries: [DictationEntry], retention: HistoryRetention, now: Date = Date()) -> [DictationEntry] {
        guard let days = retention.days,
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return entries }
        return entries.filter { $0.date >= cutoff }
    }

    /// Small histories are faster and simpler to search in memory than
    /// through a database. Whitespace-only queries show every entry.
    static func matching(_ entries: [DictationEntry], query rawQuery: String) -> [DictationEntry] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    static func load() -> [DictationEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([DictationEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [DictationEntry]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("openvox: history save failed: \(error)\n".utf8))
        }
    }
}
