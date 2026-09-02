import AppKit
import Foundation
import SwiftUI

/// One finished, non-empty, non-cancelled dictation, recorded from the
/// sidecar's `final` event whether the text was typed into a target or
/// shown on the transcript card.
struct DictationEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
}

/// How long recorded dictations stay. `days == nil` keeps them forever.
enum HistoryRetention: String, CaseIterable, Identifiable {
    case days7, days30, forever

    var id: String { rawValue }

    var label: String {
        switch self {
        case .days7: "7 days"
        case .days30: "30 days"
        case .forever: "All time"
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

/// The "History…" window: newest dictation first, each with its date and
/// time and a Copy button. Retention is chosen in Settings.
struct HistoryView: View {
    let appState: AppState
    @State private var searchText = ""

    private var visibleEntries: [DictationEntry] {
        DictationHistory.matching(Array(appState.history.reversed()), query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.history.isEmpty {
                ContentUnavailableView(
                    "No Dictations Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Finished dictations appear here.")
                )
            } else if visibleEntries.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No dictations match “\(searchText)”.")
                )
            } else {
                List(visibleEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            }
                            .controlSize(.small)
                        }
                        Text(entry.text).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                Text("Keeping \(appState.historyRetention.label.lowercased()) · \(appState.history.count) dictations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History", role: .destructive) { appState.clearHistory() }
                    .disabled(appState.history.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 360)
        .searchable(text: $searchText, prompt: "Search dictations")
    }
}
