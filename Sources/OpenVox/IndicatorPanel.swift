import SwiftUI
import Cocoa

enum IndicatorState: Equatable {
    case listening(level: Float)
    case transcribing
    case notReady(String)
}

/// Small floating capsule that shows dictation state without ever taking
/// focus from the app the user is dictating into.
final class IndicatorPanel: NSPanel {
    private let hosting: NSHostingView<IndicatorView>

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
        // it can never steal keyboard focus from the app being dictated into.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        contentView = hosting
    }

    func show(state: IndicatorState) {
        hosting.rootView = IndicatorView(state: state)
        // Level updates call show() at audio-callback rate (~40 Hz); only
        // re-position/re-order when the panel isn't already on screen, so a
        // running utterance doesn't reorder-front dozens of times a second.
        guard !isVisible else { return }
        contentView?.layoutSubtreeIfNeeded()
        positionBottomCenter()
        orderFrontRegardless() // shows without activating the app or taking key focus
    }

    func hide() {
        orderOut(nil)
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

    var body: some View {
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

    private var iconName: String {
        switch state {
        case .listening: return "mic.fill"
        case .transcribing: return "waveform"
        case .notReady: return "mic.slash"
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
        }
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
