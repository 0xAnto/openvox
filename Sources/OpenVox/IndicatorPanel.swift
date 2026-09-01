import SwiftUI
import Cocoa

enum IndicatorState: Equatable {
    case listening(level: Float)
    case transcribing
    case notReady(String)
    /// No confirmed text target was found for this utterance. `isFinal`
    /// is false while a streaming utterance is still being spoken (text
    /// updates live); true once there's nothing more coming, which is
    /// when the ~15 s auto-dismiss timer arms.
    case transcriptCard(text: String, isFinal: Bool)
}

/// Small floating capsule that shows dictation state without ever taking
/// focus from the app the user is dictating into. Expands into a fixed-size
/// transcript card (scrollable text + Copy / Insert Anyway) when no text
/// target was found to insert into.
final class IndicatorPanel: NSPanel {
    private let hosting: NSHostingView<IndicatorView>
    private var dismissWorkItem: DispatchWorkItem?
    private var cardIsShowing = false

    /// Fired whenever the transcript card stops showing, for any reason
    /// (Copy, Insert Anyway, the close button, the ~15 s timeout, or the
    /// panel being told to show something else / hide). Lets AppDelegate
    /// know the cancel key no longer needs to intercept Esc for this.
    var onCardDismissed: (() -> Void)?

    init() {
        hosting = NSHostingView(rootView: IndicatorView(state: .transcribing))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 48),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        isFloatingPanel = true
        // Never becomes key even though it's technically activatable, so
        // it can never steal keyboard focus from the app being dictated
        // into -- including the transcript card's buttons, which are
        // clickable without the panel becoming key.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        contentView = hosting
    }

    func show(state: IndicatorState) {
        var isCard = false
        var isFinalCard = false
        if case .transcriptCard(_, let isFinal) = state {
            isCard = true
            isFinalCard = isFinal
        }
        if cardIsShowing, !isCard { closeCardBookkeeping() }
        if !isCard {
            // Drop a pending card auto-dismiss: otherwise it fires later and
            // hides the indicator in the middle of the next utterance.
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
        }
        cardIsShowing = isCard

        hosting.rootView = IndicatorView(
            state: state,
            onCopy: { [weak self] in
                guard case .transcriptCard(let text, _) = state else { return }
                TextInserter.copyToPasteboard(text)
                self?.hide()
            },
            onInsertAnyway: { [weak self] in
                guard case .transcriptCard(let text, _) = state else { return }
                TextInserter.insert(text)
                self?.hide()
            },
            onClose: { [weak self] in self?.hide() }
        )
        if isFinalCard, dismissWorkItem == nil {
            let item = DispatchWorkItem { [weak self] in self?.hide() }
            dismissWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
        }

        // Level updates call show() at audio-callback rate (~40 Hz); only
        // re-position/re-order when the panel isn't already on screen, so a
        // running utterance doesn't reorder-front dozens of times a second.
        guard !isVisible else { return }
        contentView?.layoutSubtreeIfNeeded()
        positionBottomCenter()
        orderFrontRegardless() // shows without activating the app or taking key focus
    }

    func hide() {
        if cardIsShowing { closeCardBookkeeping() }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        orderOut(nil)
    }

    private func closeCardBookkeeping() {
        cardIsShowing = false
        onCardDismissed?()
    }

    private func positionBottomCenter() {
        let screen = targetScreen()
        let frameSize = hosting.fittingSize
        let width = max(frameSize.width, 160)
        let height = max(frameSize.height, 44)
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - width / 2, y: visible.minY + 56)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func targetScreen() -> NSScreen {
        if let keyScreen = NSApp.keyWindow?.screen { return keyScreen }
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

struct IndicatorView: View {
    let state: IndicatorState
    var onCopy: (() -> Void)?
    var onInsertAnyway: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        if case .transcriptCard(let text, _) = state {
            TranscriptCardView(text: text, onCopy: onCopy, onInsertAnyway: onInsertAnyway, onClose: onClose)
        } else {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .fixedSize()
        }
    }

    private var iconName: String {
        switch state {
        case .listening: return "mic.fill"
        case .transcribing: return "waveform"
        case .notReady: return "mic.slash"
        case .transcriptCard: return "doc.plaintext"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .listening(let level):
            LevelBars(level: level)
        case .transcribing:
            Text("Transcribing…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        case .notReady(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        case .transcriptCard:
            EmptyView() // rendered by TranscriptCardView instead
        }
    }
}

private struct TranscriptCardView: View {
    let text: String
    let onCopy: (() -> Void)?
    let onInsertAnyway: (() -> Void)?
    let onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("No text field found", systemImage: "doc.plaintext")
                    .font(.headline)
                Spacer()
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 100)
            HStack {
                Button("Insert Anyway") { onInsertAnyway?() }
                Spacer()
                Button("Copy") { onCopy?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .frame(width: 3, height: barHeight(for: i))
                    .foregroundStyle(.tint)
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let threshold = Float(index) / 5.0
        let active = min(1.0, max(0.15, CGFloat(level) * 6.0))
        return level > threshold ? 4 + active * 12 : 4
    }
}
