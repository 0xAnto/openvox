import AppKit
import Charts
import Observation
import SwiftUI

/// Shared selection state for the product window. Menu-bar actions can update
/// this model before presenting the window so History and Settings always open
/// in the same app surface.
@Observable
final class ProductNavigation {
    enum Destination: String, CaseIterable, Identifiable {
        case home
        case history
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .home: "Home"
            case .history: "History"
            case .settings: "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .home: "house"
            case .history: "clock.arrow.circlepath"
            case .settings: "gearshape"
            }
        }
    }

    var selection: Destination
    /// An entry History opens in its inspector on the next appearance.
    /// History clears it once consumed.
    var pendingHistoryEntry: DictationEntry.ID?

    init(selection: Destination = .home) {
        self.selection = selection
    }

    func openHistory(entry: DictationEntry.ID? = nil) {
        pendingHistoryEntry = entry
        selection = .history
    }
}

/// Owns the app's single, resizable Dock window.
final class ProductWindowController: NSWindowController {
    let navigation: ProductNavigation

    init(
        appState: AppState,
        navigation: ProductNavigation,
        onSelectMode: @escaping (AppState.Mode) -> Void,
        onCancelSwitch: @escaping () -> Void,
        onRetryLoad: @escaping () -> Void
    ) {
        self.navigation = navigation

        let rootView = ProductRootView(
            appState: appState,
            navigation: navigation,
            onSelectMode: onSelectMode,
            onCancelSwitch: onCancelSwitch,
            onRetryLoad: onRetryLoad
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenVox"
        window.titlebarAppearsTransparent = true
        // History and Settings put their names in `.navigationTitle`, so the
        // titlebar has to draw them.
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 860, height: 600)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("OpenVoxProductWindow")
        window.contentViewController = NSHostingController(rootView: rootView)

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}

private struct ProductRootView: View {
    @Bindable var appState: AppState
    @Bindable var navigation: ProductNavigation
    let onSelectMode: (AppState.Mode) -> Void
    let onCancelSwitch: () -> Void
    let onRetryLoad: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            List(ProductNavigation.Destination.allCases, selection: $navigation.selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle("OpenVox")
            .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 230)
        } detail: {
            Group {
                switch navigation.selection {
                case .home:
                    ProductHomeView(appState: appState) { entry in
                        navigation.openHistory(entry: entry)
                    }
                case .history:
                    HistoryView(appState: appState, navigation: navigation)
                case .settings:
                    ProductSettingsView(
                        appState: appState,
                        onSelectMode: onSelectMode,
                        onCancelSwitch: onCancelSwitch,
                        onRetryLoad: onRetryLoad
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(OpenVoxPalette.accent(for: colorScheme))
    }
}

private struct ProductHomeView: View {
    @Bindable var appState: AppState
    /// Opens History, on the given entry when there is one.
    let openHistory: (DictationEntry.ID?) -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// The period every tile reports on. It survives relaunches, so the page
    /// opens on the period the user last read. An unknown stored value falls
    /// back to this default.
    @AppStorage("homeStatsPeriod") private var period: StatsPeriod = .week

    private var recentEntries: [DictationEntry] {
        Array(appState.history.suffix(5).reversed())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home")
                        .font(.largeTitle.bold())
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    statusCard
                    statsRow
                    chartCard
                }

                recentSection
            }
            .padding(32)
            // The column stops growing at 1200 pt so the lines stay readable,
            // then centers itself in whatever width is left.
            .frame(maxWidth: 1_200)
            .frame(maxWidth: .infinity)
        }
        // TCC grants change outside the app, so Home re-reads them itself.
        .refreshesPermissions(appState)
        // The page names itself in its content, so the titlebar keeps the
        // app name instead of the last page's title.
        .navigationTitle("OpenVox")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Period", selection: $period) {
                    ForEach(StatsPeriod.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.14))
                    .frame(width: 46, height: 46)
                Image(systemName: statusSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    // Three lines, so the two-sentence Accessibility fix
                    // stays whole next to the button at the 860 pt minimum.
                    .lineLimit(3)
            }

            Spacer(minLength: 16)

            statusAccessory
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .cardBackground()
    }

    /// The trailing slot of the status card. A lost grant needs an action,
    /// so the button replaces the shortcut chip until the grant comes back.
    @ViewBuilder
    private var statusAccessory: some View {
        if case .accessibilityLost = status {
            Button("Open Accessibility Settings") {
                PermissionsHelper.openAccessibilitySettings()
            }
            .buttonStyle(.bordered)
            .fixedSize()
        } else {
            HStack(spacing: 8) {
                if isReady {
                    // The halo is padding around the dot, so the dot stays 8 pt.
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .padding(3)
                        .background(Color.green.opacity(0.18), in: Circle())
                }
                Text("Shortcut")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(KeyLabel.name(for: appState.hotkey))
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .cardBackground(cornerRadius: 6)
            }
        }
    }

    private var statsRow: some View {
        let stats = DictationStats.summary(DictationStats.entries(appState.history, in: period))
        let pace = DictationStats.pace(words: stats.timedWords, seconds: stats.timedSeconds)

        // Three cards share the row when each gets 220 pt or more. Below
        // that the grid reflows to two per row, then one, so a narrow
        // window stacks them instead of squeezing them.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                metricCards(stats, pace: pace)
                    .frame(minWidth: 220)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                metricCards(stats, pace: pace)
            }
        }
    }

    @ViewBuilder
    private func metricCards(_ stats: StatsSummary, pace: Int?) -> some View {
        MetricCard(
            label: "Words dictated",
            systemImage: "text.alignleft",
            value: stats.words.formatted(),
            footnote: "\(stats.dictations) \(stats.dictations == 1 ? "dictation" : "dictations")"
        )
        MetricCard(
            label: "Time spoken",
            systemImage: "clock",
            value: Self.tileDuration(stats.spokenSeconds),
            footnote: pace.map { "\($0) words per minute" } ?? "No timed dictations yet"
        )
        MetricCard(
            label: "Time saved",
            systemImage: "bolt",
            value: Self.tileDuration(stats.savedSeconds),
            footnote: "vs typing at 40 wpm"
        )
    }

    /// Tile duration: "41 min, 8 sec", "1 hr, 59 min". An empty period reads
    /// "0 sec", which this style already prints.
    private static func tileDuration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
    }

    /// Seven days of activity, whatever period the tiles report on. The chart
    /// gives the page a heartbeat, so it stays on screen with no history too.
    private var chartCard: some View {
        let days = DictationStats.wordsPerDay(appState.history)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Words per day")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 12)
                if let first = days.first, let last = days.last {
                    Text("\(first.day.formatted(.dateTime.month(.abbreviated).day())) – \(last.day.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Chart(days) { item in
                BarMark(
                    x: .value("Day", item.day, unit: .day),
                    y: .value("Words", item.words)
                )
                .foregroundStyle(
                    Calendar.current.isDateInToday(item.day)
                        ? OpenVoxPalette.accent(for: colorScheme)
                        : OpenVoxPalette.accent(for: colorScheme).opacity(0.28)
                )
                .cornerRadius(5)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 96)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .cardBackground()
    }

    private var recentSection: some View {
        let recent = recentEntries

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent")
                    .font(.title3.bold())
                Spacer()
                if !appState.history.isEmpty {
                    Button("See All") { openHistory(nil) }
                        .buttonStyle(.plain)
                        .foregroundStyle(OpenVoxPalette.accent(for: colorScheme))
                }
            }

            if recent.isEmpty {
                EmptyRecentCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                        RecentEntryRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture { openHistory(entry.id) }
                        if index < recent.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .cardBackground()
            }
        }
    }

    private enum Status {
        case accessibilityLost
        case failure(String)
        case preparing(String)
        case paused
        case ready
        case starting(String)
    }

    private var status: Status {
        // Release builds are ad-hoc signed, so macOS ties the grant to one
        // build and drops it on every update. Nothing types without it, so
        // this outranks every other status.
        if appState.setupCompleted, !appState.accessibilityGranted { return .accessibilityLost }
        if appState.provisioningFailed { return .failure(appState.sidecarStatus) }
        if appState.pendingMode != nil { return .preparing(appState.sidecarStatus) }
        if !appState.dictationEnabled { return .paused }
        if appState.sidecarReady { return .ready }
        return .starting(appState.sidecarStatus)
    }

    private var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    private var statusTitle: String {
        switch status {
        case .accessibilityLost: "Accessibility needs to be granted again"
        case .failure: "Needs attention"
        case .preparing: "Preparing dictation"
        case .paused: "Dictation paused"
        case .ready: "Ready to dictate"
        case .starting: "Starting OpenVox"
        }
    }

    /// `Mode.label` reads "Fast (Offline)", which does not fit a sentence.
    private var modeName: String {
        appState.mode == .fast ? "Fast" : "Streaming"
    }

    private var statusDetail: String {
        switch status {
        case .accessibilityLost:
            "macOS forgets the grant after an update. Remove OpenVox from the Accessibility list, then add it again."
        case .failure(let message), .preparing(let message), .starting(let message):
            message
        case .paused:
            "Enable dictation from the menu bar when you’re ready."
        case .ready:
            "Hold your shortcut and speak in any app. \(modeName) mode, on-device."
        }
    }

    private var statusSymbol: String {
        switch status {
        case .accessibilityLost: "accessibility.badge.arrow.up.right"
        case .failure: "exclamationmark.triangle.fill"
        case .preparing, .starting: "arrow.down.circle"
        case .paused: "pause.fill"
        case .ready: "waveform.badge.mic"
        }
    }

    private var statusTint: Color {
        switch status {
        case .accessibilityLost, .failure: .orange
        default: OpenVoxPalette.accent(for: colorScheme)
        }
    }
}

private struct MetricCard: View {
    let label: String
    let systemImage: String
    let value: String
    let footnote: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OpenVoxPalette.accent(for: colorScheme))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .cardBackground()
    }
}

private struct RecentEntryRow: View {
    let entry: DictationEntry

    /// Word count, plus the spoken time when the entry has one. Entries
    /// recorded before durations existed show the word count alone.
    private var meta: String {
        let words = DictationStats.wordCount(entry.text)
        let count = "\(words) \(words == 1 ? "word" : "words")"
        guard let duration = entry.duration else { return count }
        let clock = Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
        return "\(count) · \(clock)"
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(entry.text)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(meta)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()

            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }
}

private struct EmptyRecentCard: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(OpenVoxPalette.accent(for: colorScheme))
            VStack(alignment: .leading, spacing: 3) {
                Text("Your first dictation will appear here")
                    .font(.headline)
                Text("Use your shortcut in any app to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
