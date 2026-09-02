import AppKit
import Foundation
import SwiftUI

/// The unified app's history destination: a day-grouped list that fills the
/// pane, plus a trailing inspector that shows the selected dictation. The
/// selection drives the inspector, so the list stands alone until the user
/// picks a row. Retention is still controlled from Settings.
struct HistoryView: View {
    let appState: AppState
    let navigation: ProductNavigation
    @State private var searchText = ""
    @State private var selectedID: DictationEntry.ID?
    @State private var copiedEntryID: DictationEntry.ID?
    @State private var isConfirmingClear = false
    @State private var escapeMonitor: Any?

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

    /// "12 dictations", or "1 dictation" for a single entry.
    private var dictationCountLabel: String {
        let count = appState.history.count
        return "\(count) \(count == 1 ? "dictation" : "dictations")"
    }

    /// A search reports how much of the history it shows: "3 of 12
    /// dictations". Without a search the count stands alone.
    private var subtitle: String {
        if appState.history.isEmpty { return "" }
        if trimmedSearchText.isEmpty { return dictationCountLabel }
        return "\(visibleEntries.count) of \(dictationCountLabel)"
    }

    /// The selection is the only state behind the inspector. Any dismiss the
    /// pane offers writes `false`, which clears the selected row.
    private var isInspectorPresented: Binding<Bool> {
        Binding(
            get: { selectedID != nil },
            set: { if !$0 { selectedID = nil } }
        )
    }

    var body: some View {
        Group {
            if appState.history.isEmpty {
                emptyHistory
            } else {
                VStack(spacing: 0) {
                    listColumn

                    Divider()
                    footer
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .inspector(isPresented: isInspectorPresented) {
            inspector
                .inspectorColumnWidth(min: 320, ideal: 420, max: 520)
        }
        .onAppear(perform: watchEscape)
        .onDisappear(perform: stopWatchingEscape)
        .onChange(of: visibleEntries) { _, entries in
            // A search, a delete, or a prune can hide the selected entry.
            // Drop the selection so the inspector never shows a stale row.
            if let id = selectedID, !entries.contains(where: { $0.id == id }) {
                selectedID = nil
            }
        }
        .onAppear(perform: openPendingEntry)
        .onChange(of: navigation.pendingHistoryEntry) { _, _ in openPendingEntry() }
        .navigationTitle("History")
        .navigationSubtitle(subtitle)
        .searchable(text: $searchText, prompt: "Search dictations")
        .confirmationDialog(
            "Clear all dictation history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                appState.clearHistory()
                searchText = ""
                selectedID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(dictationCountLabel) from this Mac.")
        }
    }

    /// Escape closes the inspector. A local monitor sees the key before the
    /// responder chain, so it works whatever view has focus. A text field
    /// keeps its own Escape, so a search clears its text first.
    // ponytail: keyed on the window of the event, not on this view, so a
    // second product window would share the handler. There is one window.
    private func watchEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, selectedID != nil,
                  !(event.window?.firstResponder is NSTextView) else { return event }
            selectedID = nil
            return nil
        }
    }

    private func stopWatchingEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// Home hands over an entry to open. Consume it once, so a later visit
    /// starts with no selection again.
    private func openPendingEntry() {
        guard let id = navigation.pendingHistoryEntry else { return }
        navigation.pendingHistoryEntry = nil
        searchText = ""
        selectedID = id
    }

    // MARK: - List

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
    }

    private func dayHeader(_ group: HistoryDay) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(dayLabel(for: group.date))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(group.entries.count) · \(wordsLabel(totalWords(of: group.entries)))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .textCase(nil)
    }

    /// The row reads the same at inspector width and at full width: two lines
    /// of text on the leading edge, the time pinned to the trailing edge.
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
                    .monospacedDigit()
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
        let words = wordsLabel(DictationStats.wordCount(entry.text))
        guard let duration = entry.duration else { return words }
        let clock = Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
        return "\(words) · \(clock)"
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let entry = selectedEntry {
            detail(entry)
        } else {
            // The pane opens with a selection, so this frame only shows while
            // the inspector slides shut.
            Color.clear
        }
    }

    private func detail(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(entry)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(entry.text)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: 560, alignment: .leading)

                    facts(entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayLabel(for: entry.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.title2.bold())
                }

                Spacer(minLength: 12)

                Button {
                    selectedID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close inspector")
            }

            HStack(spacing: 8) {
                copyButton(entry)

                Button("Delete", role: .destructive) {
                    delete(entry)
                }
                .buttonStyle(.bordered)
                .help("Delete dictation")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
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
        VStack(spacing: 0) {
            ForEach(factList(entry), id: \.key) { fact in
                Divider()
                HStack {
                    Text(fact.key)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(fact.value)
                        .fontWeight(.medium)
                }
                .padding(.vertical, 8)
            }
        }
        .font(.callout)
    }

    /// Every fact the entry can answer. Entries recorded before v1.0.2 carry
    /// no duration and no mode, so they list the word count alone instead of
    /// a row of dashes.
    private func factList(_ entry: DictationEntry) -> [(key: String, value: String)] {
        let words = DictationStats.wordCount(entry.text)
        var facts = [(key: "Words", value: words.formatted())]

        if let duration = entry.duration {
            let clock = Duration.seconds(duration)
                .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
            facts.append((key: "Duration", value: clock))

            if let wpm = DictationStats.pace(words: words, seconds: duration) {
                facts.append((key: "Pace", value: "\(wpm) wpm"))
            }
        }

        if let mode = modeName(entry.mode) {
            facts.append((key: "Mode", value: mode))
        }

        return facts
    }

    private func modeName(_ mode: String?) -> String? {
        switch mode {
        case "fast": "Fast"
        case "streaming": "Streaming"
        default: nil
        }
    }

    /// Moves the selection to the next older entry, or to the newer one when
    /// the deleted entry is the oldest, then removes the entry. The last
    /// delete leaves no neighbour, so the inspector closes.
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
            Text("Keeping dictations for \(appState.historyRetention.phrase)")
                .foregroundStyle(.secondary)

            Spacer()

            Button("Clear History…", role: .destructive) {
                isConfirmingClear = true
            }
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func totalWords(of entries: [DictationEntry]) -> Int {
        entries.reduce(0) { $0 + DictationStats.wordCount($1.text) }
    }

    /// "1 word" or "1,240 words".
    private func wordsLabel(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "word" : "words")"
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

private struct HistoryDay: Identifiable {
    let date: Date
    var entries: [DictationEntry]

    var id: Date { date }
}
