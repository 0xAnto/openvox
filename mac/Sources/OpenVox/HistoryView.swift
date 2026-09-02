import AppKit
import Foundation
import SwiftUI

/// The unified app's history destination: a day-grouped list on the left and
/// the full text of the selected dictation on the right. Retention is still
/// controlled from Settings.
struct HistoryView: View {
    let appState: AppState
    @State private var searchText = ""
    @State private var selectedID: DictationEntry.ID?
    @State private var copiedEntryID: DictationEntry.ID?
    @State private var isConfirmingClear = false

    private var visibleEntries: [DictationEntry] {
        DictationHistory.matching(Array(appState.history.reversed()), query: searchText)
    }

    private var groupedEntries: [HistoryDay] {
        var groups: [HistoryDay] = []

        for entry in visibleEntries {
            let day = Calendar.current.startOfDay(for: entry.date)
            if groups.last?.date == day {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(HistoryDay(date: day, entries: [entry]))
            }
        }

        return groups
    }

    private var selectedEntry: DictationEntry? {
        visibleEntries.first { $0.id == selectedID }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var dictationCountLabel: String {
        let count = appState.history.count
        return "\(count) \(count == 1 ? "dictation" : "dictations")"
    }

    var body: some View {
        Group {
            if appState.history.isEmpty {
                emptyHistory
            } else {
                VStack(spacing: 0) {
                    HSplitView {
                        listColumn
                            .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
                        detailColumn
                            .frame(minWidth: 380, maxWidth: .infinity)
                    }

                    Divider()
                    footer
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("History")
        .navigationSubtitle(appState.history.isEmpty ? "" : dictationCountLabel)
        .searchable(text: $searchText, prompt: "Search dictations")
        .confirmationDialog(
            "Clear all dictation history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                appState.clearHistory()
                searchText = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(dictationCountLabel) from this Mac.")
        }
    }

    // MARK: - List column

    private var listColumn: some View {
        Group {
            if visibleEntries.isEmpty {
                emptySearch
            } else {
                List(selection: $selectedID) {
                    ForEach(groupedEntries) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                historyRow(entry)
                                    .tag(entry.id)
                            }
                        } header: {
                            dayHeader(group)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear(perform: selectFirstVisibleIfNeeded)
        .onChange(of: visibleEntries) { _, _ in selectFirstVisibleIfNeeded() }
    }

    private func dayHeader(_ group: HistoryDay) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(dayLabel(for: group.date))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(group.entries.count) · \(totalWords(of: group.entries)) words")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .textCase(nil)
    }

    private func historyRow(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(entry.text)
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }

            Text(rowMeta(entry))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    /// "21 words · 0:09". Entries recorded before v1.0.2 carry no duration, so
    /// they show the word count alone.
    private func rowMeta(_ entry: DictationEntry) -> String {
        let words = DictationStats.wordCount(entry.text)
        guard let duration = entry.duration else { return "\(words) words" }
        let clock = Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
        return "\(words) words · \(clock)"
    }

    /// Keeps one row selected. Runs on appear and after every list change, so a
    /// search, a delete, or a new dictation never leaves a stale selection.
    private func selectFirstVisibleIfNeeded() {
        guard selectedEntry == nil else { return }
        selectedID = visibleEntries.first?.id
    }

    // MARK: - Detail column

    private var detailColumn: some View {
        Group {
            if let entry = selectedEntry {
                detail(entry)
            } else {
                ContentUnavailableView(
                    "Select a Dictation",
                    systemImage: "text.alignleft",
                    description: Text("Pick an entry to read or copy it.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayLabel(for: entry.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.title2.bold())
                }

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    copyButton(entry)

                    Button("Delete") {
                        delete(entry)
                    }
                    .buttonStyle(.bordered)
                    .help("Delete dictation")
                }
            }

            ScrollView {
                Text(entry.text)
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            .padding(.top, 22)

            facts(entry)
                .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 30)
        .padding(.top, 26)
        // The footer sits under the whole split, so the facts row needs its
        // own bottom room.
        .padding(.bottom, 26)
    }

    private func copyButton(_ entry: DictationEntry) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(entry.text, forType: .string) else { return }
            let copiedID = entry.id
            copiedEntryID = copiedID
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedEntryID == copiedID { copiedEntryID = nil }
            }
        } label: {
            Label(
                copiedEntryID == entry.id ? "Copied" : "Copy",
                systemImage: copiedEntryID == entry.id ? "checkmark" : "doc.on.doc"
            )
        }
        .buttonStyle(.bordered)
        .help("Copy dictation")
    }

    private func facts(_ entry: DictationEntry) -> some View {
        let words = DictationStats.wordCount(entry.text)

        return HStack(spacing: 28) {
            Fact(key: "Words", value: words.formatted())
            Fact(key: "Duration", value: durationText(entry))
            Fact(key: "Pace", value: paceText(entry, words: words))
            Fact(key: "Mode", value: modeText(entry))
        }
    }

    private func durationText(_ entry: DictationEntry) -> String {
        guard let duration = entry.duration else { return "—" }
        return Duration.seconds(duration)
            .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    private func paceText(_ entry: DictationEntry, words: Int) -> String {
        guard let duration = entry.duration,
              let wpm = DictationStats.pace(words: words, seconds: duration) else { return "—" }
        return "\(wpm) wpm"
    }

    private func modeText(_ entry: DictationEntry) -> String {
        switch entry.mode {
        case "fast": "Fast"
        case "streaming": "Streaming"
        default: "—"
        }
    }

    /// Moves the selection to the next older entry, or to the newer one when
    /// the deleted entry is the oldest, then removes the entry.
    private func delete(_ entry: DictationEntry) {
        selectedID = neighbourID(of: entry)
        appState.deleteDictation(entry.id)
    }

    private func neighbourID(of entry: DictationEntry) -> DictationEntry.ID? {
        guard let index = visibleEntries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        if index + 1 < visibleEntries.count { return visibleEntries[index + 1].id }
        return index > 0 ? visibleEntries[index - 1].id : nil
    }

    // MARK: - Empty states and footer

    private var emptyHistory: some View {
        ContentUnavailableView {
            Label("No Dictations Yet", systemImage: "text.bubble")
        } description: {
            Text("Your completed dictations will appear here, ready to copy and reuse.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySearch: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            Text("No dictations match “\(trimmedSearchText)”.")
        } actions: {
            Button("Clear Search") {
                searchText = ""
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Keeping dictations for \(retentionPhrase)")

            Spacer()

            Button("Clear History…", role: .destructive) {
                isConfirmingClear = true
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var retentionPhrase: String {
        switch appState.historyRetention {
        case .days7: "7 days"
        case .days30: "30 days"
        case .forever: "all time"
        }
    }

    // MARK: - Helpers

    private func totalWords(of entries: [DictationEntry]) -> Int {
        entries.reduce(0) { $0 + DictationStats.wordCount($1.text) }
    }

    private func dayLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let includesYear = Calendar.current.component(.year, from: date)
            != Calendar.current.component(.year, from: Date())
        if includesYear {
            return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
        }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

/// One key and value in the detail column's facts row.
private struct Fact: View {
    let key: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(value)
                .font(.callout.weight(.medium))
        }
    }
}

private struct HistoryDay: Identifiable {
    let date: Date
    var entries: [DictationEntry]

    var id: Date { date }
}
