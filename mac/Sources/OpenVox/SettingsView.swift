import SwiftUI

/// The Settings destination of the product window. It uses the same page
/// language as Home and History — a centred scrolling column, an in-content
/// title, `.title3.bold()` section headers, and `cardBackground()` cards —
/// instead of a native `Form`, so the three pages read as one app.
///
/// The sections run in the order a user reaches for them: the app itself,
/// then dictation and its shortcut, then the indicator, the permissions,
/// and the history.
struct ProductSettingsView: View {
    @Bindable var appState: AppState
    let onSelectMode: (AppState.Mode) -> Void
    let onCancelSwitch: () -> Void
    let onRetryLoad: () -> Void

    /// The width a segmented picker gets so its labels never squeeze at the
    /// 860 pt minimum window width.
    private static let pickerWidth: CGFloat = 240

    @State private var confirmsClearHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings")
                    .font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 22) {
                    generalSection
                    dictationSection
                    indicatorSection
                    permissionsSection
                    historySection
                }
            }
            .padding(32)
            // The column stops growing at 1200 pt so the lines stay readable,
            // then centers itself in whatever width is left. Matches Home.
            .frame(maxWidth: 1_200)
            .frame(maxWidth: .infinity)
        }
        // The page names itself in its content, so the titlebar keeps the
        // app name instead of the last page's title.
        .navigationTitle("OpenVox")
        .confirmationDialog("Clear all dictations?", isPresented: $confirmsClearHistory) {
            Button("Clear History", role: .destructive) { appState.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every saved dictation on this Mac. You cannot undo it.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        settingsSection("General") {
            SettingsRow("Launch OpenVox at Login") {
                Toggle("", isOn: $appState.launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Divider()
            SettingsRow("Appearance") {
                Picker("", selection: $appState.appearance) {
                    ForEach(AppState.Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: Self.pickerWidth)
            }
        }
    }

    // MARK: - Dictation

    private var dictationSection: some View {
        settingsSection("Dictation") {
            modeContent
            Divider()
            ShortcutRows(appState: appState)
            Divider()
            MicrophoneInputPicker(appState: appState)
        }
    }

    private var showsModePicker: Bool {
        appState.pendingMode == nil && !appState.provisioningFailed && appState.sidecarReady
    }

    @ViewBuilder
    private var modeContent: some View {
        if let pending = appState.pendingMode {
            ProvisioningView(appState: appState, mode: pending, onCancel: onCancelSwitch, inline: true)
        } else if appState.provisioningFailed {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
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
            .padding(.vertical, 12)
        } else if !appState.sidecarReady {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(appState.sidecarStatus)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        } else {
            // Two modes, one choice: a segmented control reads as the
            // toggle it is, and the row note says what the chosen one does.
            SettingsRow("Mode", description: appState.mode.summary) {
                Picker("Mode", selection: Binding(
                    get: { appState.mode },
                    set: { onSelectMode($0) }
                )) {
                    ForEach(AppState.Mode.allCases) { mode in
                        Text(mode.shortLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: Self.pickerWidth)
            }
        }
    }

    // MARK: - Indicator

    private var indicatorSection: some View {
        settingsSection("Indicator") {
            IndicatorStylePicker(appState: appState, label: "Style")
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        settingsSection("Permissions") {
            PermissionRows(appState: appState)
        }
    }

    // MARK: - History

    private var historySection: some View {
        settingsSection("History") {
            SettingsRow("Keep dictations for") {
                Picker("", selection: $appState.historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.label).tag(retention)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Divider()
            SettingsRow("") {
                Button("Clear History…", role: .destructive) { confirmsClearHistory = true }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Section scaffold

    /// A `.title3.bold()` header over one `cardBackground()` card of rows.
    /// Notes ride the row they explain, so a section carries no footer.
    private func settingsSection<Rows: View>(
        _ title: String,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            card { rows() }
        }
    }

    /// Rows in a `VStack(spacing: 0)`, the same shape as the Home Recent
    /// card: 16 pt horizontal padding on the card, each row 12 pt tall.
    @ViewBuilder
    private func card<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: 0) { rows() }
            .padding(.horizontal, 16)
            .cardBackground()
    }
}

/// One settings row: a leading label and trailing content, the shape every
/// row in a Settings card and every row group it shares with onboarding's
/// `Form` uses.
struct SettingsRow<Content: View>: View {
    let label: String
    /// A note that explains this row alone. It sits under the label, the way
    /// System Settings writes one, instead of floating under the whole card.
    let description: String?
    let content: Content

    init(_ label: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.description = description
        self.content = content()
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            content
        }
        .padding(.vertical, 12)
        .font(.body)
    }
}
