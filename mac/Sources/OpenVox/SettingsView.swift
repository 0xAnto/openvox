import SwiftUI

/// The Settings destination of the product window. The sections run in the
/// order a user reaches for them: the app itself, then dictation and its
/// shortcut, then the indicator, the permissions, and the history.
struct ProductSettingsView: View {
    @Bindable var appState: AppState
    let onSelectMode: (AppState.Mode) -> Void
    let onCancelSwitch: () -> Void
    let onRetryLoad: () -> Void

    /// The widest the form grows. Past this a row pushes its label and its
    /// control to opposite edges and becomes hard to read.
    private static let contentWidth: CGFloat = 720

    @State private var confirmsClearHistory = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch OpenVox at Login", isOn: $appState.launchAtLogin)
                Picker("Appearance", selection: $appState.appearance) {
                    ForEach(AppState.Appearance.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                modeContent
            } header: {
                Text("Dictation")
            } footer: {
                if showsModePicker { SectionFooter(appState.mode.summary) }
            }

            Section {
                ShortcutRows(appState: appState)
            } header: {
                Text("Shortcut")
            } footer: {
                SectionFooter(ShortcutRows.cancelKeyFooter)
            }

            Section("Microphone") {
                MicrophoneInputPicker(appState: appState)
            }

            Section {
                IndicatorStylePicker(appState: appState)
            } header: {
                Text("Indicator")
            } footer: {
                SectionFooter(IndicatorStylePicker.footer)
            }

            Section("Permissions") {
                PermissionRows(appState: appState)
            }

            Section("History") {
                Picker("Keep dictations for", selection: $appState.historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.label).tag(retention)
                    }
                }
                Button("Clear History…", role: .destructive) { confirmsClearHistory = true }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity)
        .navigationTitle("Settings")
        .confirmationDialog("Clear all dictations?", isPresented: $confirmsClearHistory) {
            Button("Clear History", role: .destructive) { appState.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every saved dictation on this Mac. You cannot undo it.")
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
        } else if !appState.sidecarReady {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(appState.sidecarStatus)
                    .foregroundStyle(.secondary)
            }
        } else {
            // Two modes, one choice: a segmented control reads as the
            // toggle it is, and the footer says what the chosen one does.
            Picker("Mode", selection: Binding(
                get: { appState.mode },
                set: { onSelectMode($0) }
            )) {
                ForEach(AppState.Mode.allCases) { mode in
                    Text(mode.shortLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
