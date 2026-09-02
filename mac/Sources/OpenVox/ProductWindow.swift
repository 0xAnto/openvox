import AppKit
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

    init(selection: Destination = .home) {
        self.selection = selection
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
        window.titleVisibility = .hidden
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
                    ProductHomeView(appState: appState) {
                        navigation.selection = .history
                    }
                case .history:
                    HistoryView(appState: appState)
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
    let openHistory: () -> Void

    private var entriesToday: [DictationEntry] {
        appState.history.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var entriesThisWeek: [DictationEntry] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else {
            return appState.history
        }
        return appState.history.filter { $0.date >= cutoff }
    }

    private var totalWords: Int {
        appState.history.reduce(into: 0) { total, entry in
            total += entry.text.split(whereSeparator: { $0.isWhitespace }).count
        }
    }

    private var recentEntries: [DictationEntry] {
        Array(appState.history.suffix(5).reversed())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Home")
                        .font(.largeTitle.bold())
                    Text("Your private voice workspace")
                        .foregroundStyle(.secondary)
                }

                statusCard

                HStack(spacing: 14) {
                    MetricCard(value: entriesToday.count.formatted(), label: "Dictations today", systemImage: "sun.max")
                    MetricCard(value: entriesThisWeek.count.formatted(), label: "Last 7 days", systemImage: "calendar")
                    MetricCard(value: totalWords.formatted(), label: "Words saved", systemImage: "text.word.spacing")
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent")
                            .font(.title2.bold())
                        Spacer()
                        if !appState.history.isEmpty {
                            Button("View All", action: openHistory)
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    if recentEntries.isEmpty {
                        EmptyRecentCard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(recentEntries.enumerated()), id: \.element.id) { index, entry in
                                RecentEntryRow(entry: entry)
                                if index < recentEntries.count - 1 {
                                    Divider().padding(.leading, 42)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.primary.opacity(0.08))
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: statusSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusTint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("Shortcut")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(KeyLabel.name(for: appState.hotkey))
                    .font(.system(.body, design: .rounded, weight: .semibold))
            }
        }
        .padding(20)
        .background(statusBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(statusTint.opacity(0.16))
        }
    }

    private enum Status {
        case failure(String)
        case preparing(String)
        case paused
        case ready
        case starting(String)
    }

    private var status: Status {
        if appState.provisioningFailed { return .failure(appState.sidecarStatus) }
        if appState.pendingMode != nil { return .preparing(appState.sidecarStatus) }
        if !appState.dictationEnabled { return .paused }
        if appState.sidecarReady { return .ready }
        return .starting(appState.sidecarStatus)
    }

    private var statusTitle: String {
        switch status {
        case .failure: "Needs attention"
        case .preparing: "Preparing dictation"
        case .paused: "Dictation paused"
        case .ready: "Ready to dictate"
        case .starting: "Starting OpenVox"
        }
    }

    private var statusDetail: String {
        switch status {
        case .failure(let message), .preparing(let message), .starting(let message):
            message
        case .paused:
            "Enable dictation from the menu bar when you’re ready."
        case .ready:
            "Hold your shortcut and speak in any app."
        }
    }

    private var statusSymbol: String {
        switch status {
        case .failure: "exclamationmark.triangle.fill"
        case .preparing, .starting: "arrow.down.circle"
        case .paused: "pause.fill"
        case .ready: "waveform.badge.mic"
        }
    }

    private var statusTint: Color {
        if case .failure = status { return .orange }
        return .accentColor
    }

    private var statusBackground: Color {
        statusTint.opacity(0.08)
    }
}

private struct MetricCard: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }
}

private struct RecentEntryRow: View {
    let entry: DictationEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .lineLimit(2)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 13)
    }
}

private struct EmptyRecentCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
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
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
    }
}

private struct ProductSettingsView: View {
    @Bindable var appState: AppState
    let onSelectMode: (AppState.Mode) -> Void
    let onCancelSwitch: () -> Void
    let onRetryLoad: () -> Void

    var body: some View {
        Form {
            Section("Dictation") {
                if let pending = appState.pendingMode {
                    ProvisioningView(appState: appState, mode: pending, onCancel: onCancelSwitch)
                } else if appState.provisioningFailed {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Model couldn’t start")
                                .font(.headline)
                            Text(appState.sidecarStatus)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Try Again", action: onRetryLoad)
                    }
                } else if !appState.sidecarReady {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(appState.sidecarStatus)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Mode", selection: Binding(
                        get: { appState.mode },
                        set: { onSelectMode($0) }
                    )) {
                        ForEach(AppState.Mode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }

            SetupFormSections(appState: appState)

            Section("History") {
                Picker("Keep dictations for", selection: $appState.historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.label).tag(retention)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 20)
        .navigationTitle("Settings")
    }
}
