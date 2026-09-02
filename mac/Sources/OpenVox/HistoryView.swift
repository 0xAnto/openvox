import AppKit
import Foundation
import SwiftUI

/// The unified app's history destination: newest dictation first, grouped by
/// day, with retention still controlled from Settings.
struct HistoryView: View {
    let appState: AppState
    @State private var searchText = ""
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

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var dictationCountLabel: String {
        let count = appState.history.count
        return "\(count) \(count == 1 ? "dictation" : "dictations")"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if appState.history.isEmpty {
                emptyHistory
            } else if visibleEntries.isEmpty {
                emptySearch
            } else {
                List {
                    ForEach(groupedEntries) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                historyRow(entry)
                            }
                        } header: {
                            Text(dayLabel(for: group.date))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.title2.weight(.semibold))
                Text("Review and reuse your recent dictations.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if !appState.history.isEmpty {
                Text(dictationCountLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

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

    private func historyRow(_ entry: DictationEntry) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.text)
                    .font(.body)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
            .controlSize(.small)
            .help("Copy dictation")
        }
        .padding(.vertical, 8)
        .listRowSeparator(.visible)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Label(appState.historyRetention.label, systemImage: "calendar.badge.clock")
            Text("·")
            Text(dictationCountLabel)

            if !trimmedSearchText.isEmpty, !visibleEntries.isEmpty {
                Text("·")
                Text("\(visibleEntries.count) shown")
            }

            Spacer()

            Button("Clear History", role: .destructive) {
                isConfirmingClear = true
            }
            .disabled(appState.history.isEmpty)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
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
