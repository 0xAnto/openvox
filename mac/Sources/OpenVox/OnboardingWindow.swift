import SwiftUI
import Cocoa

/// First-launch setup assistant. Shown until `appState.setupCompleted` is set.
final class OnboardingWindowController: NSWindowController {
    convenience init(appState: AppState, onDownload: @escaping (AppState.Mode) -> Void, onFinish: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up OpenVox"
        // The app delegate keeps this controller alive so setup can be
        // reopened after the window is closed part-way through.
        window.isReleasedWhenClosed = false
        window.center()
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentView = NSHostingView(
            rootView: OnboardingView(
                appState: appState,
                onDownload: onDownload,
                onFinish: onFinish
            )
        )
        self.init(window: window)
    }
}

struct OnboardingView: View {
    @Bindable var appState: AppState
    let onDownload: (AppState.Mode) -> Void
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var step = 0
    @State private var chosenMode: AppState.Mode = .fast

    private let stepNames = ["Welcome", "Speech model", "Download", "Essentials", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 680, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(OpenVoxPalette.accent(for: colorScheme))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("OpenVox")
                    .font(.headline)
                Text(stepNames[step])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StepIndicator(currentStep: step, stepCount: stepNames.count)
        }
        .padding(.horizontal, 24)
        // Step 4 fills the window with rows. A tighter header and action
        // bar give the form the height it needs inside a fixed window.
        .frame(height: 52)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            WelcomeStep()
        case 1:
            ChooseModeStep(chosenMode: $chosenMode)
        case 2:
            ProvisioningView(appState: appState, mode: chosenMode)
        case 3:
            // The grouped form insets itself. Extra padding here only costs
            // the height this fixed window has to spare.
            SetupForm(appState: appState)
        default:
            ReadyStep(hotkeyName: KeyLabel.name(for: appState.hotkey))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step == 3 {
                Button("Back") { move(to: 1) }
                    .buttonStyle(.bordered)
            }

            Spacer()
            footerButton
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .frame(height: 56)
        // The system bar material sits a step off the window background in
        // both modes, so the action bar reads as a bar in light and dark.
        .background(.bar)
    }

    private var downloadIsReady: Bool {
        appState.sidecarReady && appState.mode == chosenMode
    }

    @ViewBuilder
    private var footerButton: some View {
        switch step {
        case 0:
            primaryButton("Get Started") { move(to: 1) }
        case 1:
            primaryButton("Download") {
                onDownload(chosenMode)
                move(to: 2)
            }
        case 2:
            // The user explicitly confirms a successful download before
            // proceeding to system permissions and shortcut setup.
            if appState.provisioningFailed {
                primaryButton("Try Again") { onDownload(chosenMode) }
            } else if downloadIsReady {
                primaryButton("Continue") { move(to: 3) }
            }
        case 3:
            Button("Continue") { move(to: 4) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!appState.micPermissionGranted || !appState.accessibilityGranted)
        default:
            Button("Start Using OpenVox") { onFinish() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }

    private func move(to nextStep: Int) {
        withAnimation(.easeInOut(duration: 0.18)) {
            step = nextStep
        }
    }
}

private struct StepIndicator: View {
    let currentStep: Int
    let stepCount: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(currentStep + 1), total: Double(stepCount))
                .progressViewStyle(.linear)
                .frame(width: 92)

            Text("\(currentStep + 1) of \(stepCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("Step \(currentStep + 1) of \(stepCount)")
    }
}

private struct WelcomeStep: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(OpenVoxPalette.wash(for: colorScheme))
                    .frame(width: 132, height: 132)

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 92, height: 92)
            }
            .accessibilityHidden(true)
            .padding(.bottom, 26)

            Text("Voice to text, instantly.")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text("Private, on-device dictation for any app.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
        .padding(44)
    }
}

private struct ChooseModeStep: View {
    @Binding var chosenMode: AppState.Mode

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose a speech model")
                .font(.title.bold())

            Text("Both options run entirely on your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack(spacing: 16) {
                ModeCard(
                    icon: "bolt.fill",
                    title: "Fast",
                    badge: "Recommended",
                    subtitle: "Transcribes when you release the key.",
                    detail: "Lower memory use",
                    selected: chosenMode == .fast
                ) {
                    chosenMode = .fast
                }

                ModeCard(
                    icon: "waveform",
                    title: "Streaming",
                    subtitle: "Shows text while you speak.",
                    detail: "Higher memory use",
                    selected: chosenMode == .streaming
                ) {
                    chosenMode = .streaming
                }
            }
            .padding(.top, 24)

            Text("You can switch models later in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 18)
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 34)
    }
}

private struct ModeCard: View {
    let icon: String
    let title: String
    var badge: String?
    let subtitle: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(OpenVoxPalette.accent(for: colorScheme))
                        .frame(width: 32, height: 32)
                        .background(OpenVoxPalette.wash(for: colorScheme), in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.headline)

                    Spacer(minLength: 4)

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(OpenVoxPalette.accent(for: colorScheme))
                            .accessibilityHidden(true)
                    }
                }

                if let badge {
                    Text(badge.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.4)
                        .foregroundStyle(OpenVoxPalette.accent(for: colorScheme))
                        .padding(.top, 14)
                }

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, badge == nil ? 14 : 5)

                Spacer(minLength: 12)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(width: 264, height: 174, alignment: .topLeading)
            // The selection tint is translucent, so the card surface goes
            // behind it. Both cards then share one surface colour.
            .background(
                selected ? OpenVoxPalette.selection(for: colorScheme) : .clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        selected ? OpenVoxPalette.accent(for: colorScheme) : Color(nsColor: .separatorColor),
                        lineWidth: selected ? 2 : (colorSchemeContrast == .increased ? 1.5 : 1)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) model")
        .accessibilityValue(
            [selected ? "Selected" : "Not selected", badge, detail]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityHint(subtitle)
    }
}

/// Shared by first-run onboarding and Settings when a model is changed.
/// `onCancel == nil` hides Cancel during initial setup, where no previous
/// model is available to restore.
struct ProvisioningView: View {
    @Bindable var appState: AppState
    let mode: AppState.Mode
    var onCancel: (() -> Void)?
    /// Settings shows this inside a form row, where the full-page hero
    /// would dwarf every neighbouring row.
    var inline = false

    @Environment(\.colorScheme) private var colorScheme

    private var isReady: Bool {
        appState.sidecarReady && appState.mode == mode
    }

    @ViewBuilder
    var body: some View {
        if inline { row } else { page }
    }

    /// One form row: a small state icon, the same words as the page, and a
    /// slim progress bar.
    private var row: some View {
        HStack(spacing: 12) {
            rowIcon
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let percentage = appState.progressPct, !isReady, !appState.provisioningFailed {
                    ProgressView(value: Double(percentage), total: 100)
                        .frame(maxWidth: 240)
                        .accessibilityLabel("Model download progress")
                }
            }

            Spacer(minLength: 12)

            if let onCancel, !isReady {
                Button("Cancel", action: onCancel)
            }
        }
        // Matches the 12 pt row rhythm of the card it sits in: Settings is
        // the only caller that sets `inline`.
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var rowIcon: some View {
        if isReady {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if appState.provisioningFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            statusIcon
                .padding(.bottom, 22)

            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 7)

            if !isReady && !appState.provisioningFailed {
                progress
                    .padding(.top, 28)
            }

            if let onCancel, !isReady {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.top, 24)
            }
        }
        .frame(maxWidth: 440)
        .padding(44)
        .tint(OpenVoxPalette.accent(for: colorScheme))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isReady {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        } else if appState.provisioningFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        } else {
            Image(systemName: mode == .fast ? "arrow.down.circle.fill" : "waveform.circle.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(OpenVoxPalette.accent(for: colorScheme))
                .accessibilityHidden(true)
        }
    }

    private var title: String {
        if isReady { return "Model ready" }
        if appState.provisioningFailed { return inline ? "Could not switch" : "Download interrupted" }
        return inline ? "Preparing \(mode.shortLabel)" : "Downloading \(mode.shortLabel)"
    }

    private var description: String {
        if isReady { return "OpenVox is ready for private, on-device transcription." }
        if appState.provisioningFailed { return appState.sidecarStatus }
        return stageLabel
    }

    @ViewBuilder
    private var progress: some View {
        VStack(spacing: 10) {
            if let percentage = appState.progressPct {
                ProgressView(value: Double(percentage), total: 100)
                    .progressViewStyle(.linear)

                HStack {
                    Spacer()
                    Text("\(percentage)%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 380)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model download progress")
    }

    private var stageLabel: String {
        switch appState.progressStage {
        case "download":
            return inline ? "Preparing the model…" : "Downloading the speech model…"
        case "load":
            return "Preparing the model…"
        default:
            return appState.sidecarStatus
        }
    }
}

private struct ReadyStep: View {
    let hotkeyName: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(OpenVoxPalette.wash(for: colorScheme))
                    .frame(width: 112, height: 112)

                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(OpenVoxPalette.accent(for: colorScheme))
            }
            .accessibilityHidden(true)
            .padding(.bottom, 24)

            Text("You’re ready")
                .font(.system(size: 32, weight: .bold, design: .rounded))

            Text("Hold \(hotkeyName) and speak.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 9)
        }
        .padding(44)
    }
}

/// Short, user-facing names for a mode. Onboarding and Settings both name
/// the two models and what each one costs.
extension AppState.Mode {
    var shortLabel: String {
        self == .fast ? "Fast" : "Streaming"
    }

    /// What the mode does, then what it costs. Settings shows this under
    /// the mode control, in the words the setup cards use.
    ///
    /// ponytail: the setup cards hold the same words in their own layout,
    /// so a copy change means two edits. Split the sentence into parts the
    /// cards can lay out themselves once a third surface needs it.
    var summary: String {
        self == .fast
            ? "Transcribes when you release the key. Lower memory use."
            : "Shows text while you speak. Higher memory use."
    }
}
