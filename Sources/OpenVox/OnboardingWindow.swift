import SwiftUI
import Cocoa

/// First-launch setup assistant: fixed 640x520, centered, standard title
/// bar (traffic lights) but not resizable. Shown once, until
/// `appState.setupCompleted` is set.
final class OnboardingWindowController: NSWindowController {
    convenience init(appState: AppState, onDownload: @escaping (AppState.Mode) -> Void, onFinish: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to OpenVox"
        // `isReleasedWhenClosed = false` plus AppDelegate holding a strong
        // reference to this controller means the window is never
        // deallocated when the user closes it mid-onboarding -- it can
        // always be shown again via showOnboarding().
        window.isReleasedWhenClosed = false
        window.center()
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentView = NSHostingView(rootView: OnboardingView(appState: appState, onDownload: onDownload, onFinish: onFinish))
        self.init(window: window)
    }
}

struct OnboardingView: View {
    @Bindable var appState: AppState
    let onDownload: (AppState.Mode) -> Void
    let onFinish: () -> Void

    @State private var step = 0
    @State private var chosenMode: AppState.Mode = .fast

    var body: some View {
        VStack(spacing: 0) {
            stepContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if step == 3 {
                    Button("Back") { step = 1 }
                }
                Spacer()
                footerButton
            }
            .padding()
        }
        .frame(width: 640, height: 520)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: WelcomeStep()
        case 1: ChooseModeStep(chosenMode: $chosenMode)
        case 2: ProvisioningView(appState: appState, mode: chosenMode)
        case 3: SetupForm(appState: appState).padding()
        default: ReadyStep(hotkeyName: KeyLabel.name(for: appState.hotkey))
        }
    }

    private var downloadIsReady: Bool { appState.sidecarReady && appState.mode == chosenMode }

    @ViewBuilder
    private var footerButton: some View {
        switch step {
        case 0:
            Button("Continue") { step = 1 }.keyboardShortcut(.defaultAction)
        case 1:
            Button("Download (\(chosenMode == .fast ? "~1.1 GB" : "~5 GB"))") {
                onDownload(chosenMode)
                step = 2
            }.keyboardShortcut(.defaultAction)
        case 2:
            // Does not auto-advance: the user confirms "Everything's ready"
            // themselves before moving into Set up.
            if appState.provisioningFailed {
                Button("Retry") { onDownload(chosenMode) }.keyboardShortcut(.defaultAction)
            } else if downloadIsReady {
                Button("Continue") { step = 3 }.keyboardShortcut(.defaultAction)
            } else {
                EmptyView()
            }
        case 3:
            // Both permissions are required for the hotkey to do anything;
            // the rows above show which one is still missing.
            Button("Continue") { step = 4 }
                .keyboardShortcut(.defaultAction)
                .disabled(!appState.micPermissionGranted || !appState.accessibilityGranted)
        default:
            Button("Done") { onFinish() }.keyboardShortcut(.defaultAction)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to OpenVox").font(.largeTitle.bold())
            Text("Hold a key, speak, and your words appear where you're typing. Everything runs on this Mac. Nothing leaves it.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
    }
}

private struct ChooseModeStep: View {
    @Binding var chosenMode: AppState.Mode

    var body: some View {
        VStack(spacing: 20) {
            Text("Choose how you dictate").font(.title.bold())
            HStack(spacing: 16) {
                ModeCard(title: "Fast", subtitle: "Recommended. Transcribes the moment you release the key.",
                         detail: "~1.1 GB · lowest memory", selected: chosenMode == .fast) { chosenMode = .fast }
                ModeCard(title: "Streaming", subtitle: "Text appears while you speak.",
                         detail: "~5 GB incl. runtime · uses more memory", selected: chosenMode == .streaming) { chosenMode = .streaming }
            }
            Text("You can switch anytime in Settings. The other option downloads then.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}

private struct ModeCard: View {
    let title: String
    let subtitle: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .frame(width: 220, height: 140, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: selected ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Shared provisioning progress view: onboarding's Download step, and (per
/// item 12) Settings' inline mode-switch progress reuses this rather than
/// a second progress UI. `onCancel == nil` hides the Cancel button
/// (onboarding's first-run setup has no previous mode to fall back to).
struct ProvisioningView: View {
    @Bindable var appState: AppState
    let mode: AppState.Mode
    var onCancel: (() -> Void)?

    private var isReady: Bool { appState.sidecarReady && appState.mode == mode }

    var body: some View {
        VStack(spacing: 20) {
            Text("Setting up \(mode.label)").font(.title.bold())
            if isReady {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("Everything's ready").font(.headline)
                }
            } else if appState.provisioningFailed {
                VStack(spacing: 12) {
                    Text(appState.sidecarStatus).foregroundStyle(.secondary)
                    if let onCancel { Button("Cancel", action: onCancel) }
                }
            } else {
                ProgressView(value: Double(appState.progressPct ?? 0), total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 360)
                Text(stageLabel).font(.callout).foregroundStyle(.secondary)
                if let onCancel { Button("Cancel", action: onCancel) }
            }
        }
        .padding(40)
    }

    private var stageLabel: String {
        switch appState.progressStage {
        case "download": return "Downloading speech model — \(appState.progressPct ?? 0)%"
        case "load": return "Loading…"
        default: return appState.sidecarStatus
        }
    }
}

private struct ReadyStep: View {
    let hotkeyName: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("You're all set").font(.largeTitle.bold())
            Text("Hold \(hotkeyName) and speak.").font(.title3).foregroundStyle(.secondary)
        }
        .padding(40)
    }
}
