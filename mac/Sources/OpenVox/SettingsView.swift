import SwiftUI

/// The Settings destination of the product window.
struct ProductSettingsView: View {
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
