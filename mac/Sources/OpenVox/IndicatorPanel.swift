import SwiftUI
import Cocoa

enum IndicatorState: Equatable {
    case listening(level: Float)
    case transcribing
    case done
    case notReady(String)
}

/// What the capsule is doing right now. `show`/`hide` map IndicatorState
/// onto this; the view animates between phases.
enum IndicatorPhase: Equatable {
    case hidden        // off screen (or animating out)
    case dot           // just appeared as a circle, about to open
    case listening     // pill open, the thread rings with the voice
    case transcribing  // thread taut, pulses of light run away from the mic
    case done          // one pulse returns to the mic
    case tick          // mic has become the check, pill closing
    case notReady(String)

    var needsFrames: Bool {
        switch self {
        case .listening, .transcribing, .done, .tick: return true
        default: return false
        }
    }
}

/// Level smoothing plus the string physics. The thread is driven only by
/// real RMS samples from AudioCapture (~30 Hz): the level sets the
/// fundamental, transients pluck the overtone, and both ring down on
/// their own like a real string.
final class IndicatorModel: ObservableObject {
    @Published var phase: IndicatorPhase = .hidden
    @Published var accent = true // tint the string, glow and flash with the macOS accent colour
    private(set) var smooth: CGFloat = 0 // drives glow, lift, scale
    private(set) var bump: CGFloat = 0   // transient: mic scales up on a syllable
    private(set) var a1: CGFloat = 0     // fundamental amplitude (0...1)
    private(set) var a2: CGFloat = 0     // overtone amplitude (0...1)
    private(set) var ph1: CGFloat = 0    // fundamental phase (rad)
    private(set) var ph2: CGFloat = 0    // overtone phase (rad)
    private var recent: [CGFloat] = [0, 0, 0]
    private var slow: CGFloat = 0
    private var lastFrame: Date?
    var phaseStart = Date()

    func reset() {
        recent = [0, 0, 0]
        smooth = 0; bump = 0; slow = 0
        a1 = 0; a2 = 0
        lastFrame = nil
    }

    func push(_ rms: Float) {
        let v = min(1, CGFloat(rms) * 6) // ponytail: same linear gain the old bars used; speech RMS ~0.02-0.2
        recent.removeFirst()
        recent.append(v)
        smooth = (recent[0] + recent[1] + recent[2]) / 3
        slow += (smooth - slow) * 0.06
        let target = max(0, min(1, (v - slow) * 2.2))
        bump += (target - bump) * (target > bump ? 0.55 : 0.12)
    }

    /// Advances the string by one display frame.
    func step(now: Date) {
        let dt = CGFloat(min(0.05, now.timeIntervalSince(lastFrame ?? now)))
        lastFrame = now
        let live = phase == .listening
        let d1: CGFloat = live ? min(1, smooth * 1.1) : 0
        let d2: CGFloat = live ? bump * 0.45 : 0
        a1 += (d1 - a1) * (d1 > a1 ? 0.5 : 0.045) // ponytail: per-frame lerps tuned at 60 Hz, like the mockup
        a2 += (d2 - a2) * (d2 > a2 ? 0.6 : 0.09)
        ph1 += 2 * .pi * 6 * dt
        ph2 += 2 * .pi * 11 * dt
    }
}

/// Small floating capsule that shows dictation state without ever taking
/// focus from the app the user is dictating into.
final class IndicatorPanel: NSPanel {
    private let model = IndicatorModel()
    private let hosting: NSHostingView<IndicatorView>
    private var generation = 0 // invalidates pending phase timers on any new show/hide
    /// Settings > Indicator: accent colour or white light.
    var accent: Bool {
        get { model.accent }
        set { model.accent = newValue }
    }

    // Fixed frame with room for the shadow and glow, so the pill can open
    // and close inside it without the window ever resizing.
    private static let frameSize = NSSize(width: 360, height: 140)

    init() {
        hosting = NSHostingView(rootView: IndicatorView(model: model))
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.frameSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the view draws its own lit shadow and glow
        ignoresMouseEvents = true
        level = .statusBar
        isFloatingPanel = true
        // Never becomes key, so it can never steal keyboard focus from the
        // app being dictated into.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hosting.appearance = NSAppearance(named: .darkAqua) // ponytail: the design is white light on smoked glass; keep it that way in light mode too
        contentView = hosting
    }

    func show(state: IndicatorState) {
        generation += 1
        let gen = generation
        switch state {
        case .listening(let level):
            switch model.phase {
            case .listening, .dot:
                model.push(level) // steady state: just a new sample
            default:
                model.reset()
                model.push(level)
                model.phaseStart = Date()
                present()
                withAnimation(.bouncy(duration: 0.3)) { model.phase = .dot }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.model.phase == .dot else { return }
                    self.model.phaseStart = Date()
                    withAnimation(.snappy(duration: 0.3, extraBounce: 0.1)) { self.model.phase = .listening }
                }
            }
        case .transcribing:
            guard model.phase != .transcribing else { return }
            present()
            model.phaseStart = Date()
            withAnimation(.smooth(duration: 0.3)) { model.phase = .transcribing }
        case .done:
            guard model.phase != .done, model.phase != .tick else { return }
            present()
            model.phaseStart = Date()
            model.phase = .done // the returning pulse is frame-driven; nothing to animate here
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.model.phaseStart = Date()
                withAnimation(.bouncy(duration: 0.3)) { self.model.phase = .tick }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.hide()
                }
            }
        case .notReady(let message):
            present()
            withAnimation(.bouncy(duration: 0.4)) { model.phase = .notReady(message) }
        }
    }

    func hide() {
        guard model.phase != .hidden else { return }
        generation += 1
        let gen = generation
        withAnimation(.smooth(duration: 0.18)) { model.phase = .hidden }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.orderOut(nil)
        }
    }

    private func present() {
        guard !isVisible else { return }
        positionBottomCenter()
        orderFrontRegardless() // shows without activating the app or taking key focus
    }

    private func positionBottomCenter() {
        let visible = targetScreen().visibleFrame
        let size = Self.frameSize
        // The pill is centred in the frame; keep its bottom edge 56 pt above the Dock.
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 56 - (size.height - IndicatorView.pillHeight) / 2)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func targetScreen() -> NSScreen {
        if let keyScreen = NSApp.keyWindow?.screen { return keyScreen }
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel

    // ponytail: one size knob. Every dimension below is the mockup's 1× value times this.
    static let scale: CGFloat = 1.0
    static let pillHeight: CGFloat = 38 * scale
    private static let mic: CGFloat = 14 * scale
    private static let slotSize = CGSize(width: 66 * scale, height: 22 * scale)
    private static let padding: CGFloat = 12 * scale
    private static let gap: CGFloat = 10 * scale

    var body: some View {
        TimelineView(.animation(paused: !model.phase.needsFrames)) { timeline in
            capsule(now: timeline.date)
        }
        .frame(width: 360, height: 140)
    }

    private func capsule(now: Date) -> some View {
        model.step(now: now)
        let k = Self.scale
        let phase = model.phase
        let live = phase == .listening
        let open = phase == .listening || phase == .transcribing || phase == .done
        let hidden = phase == .hidden
        let lv = live ? model.smooth : 0
        let flash = phase == .tick ? CGFloat(min(1, now.timeIntervalSince(model.phaseStart) / 0.4)) : 0
        let tint: Color = model.accent ? .accentColor : .white
        let tickColor: Color = model.accent ? Color(nsColor: .systemGreen) : .white

        return HStack(spacing: 0) {
            if case .notReady(let message) = phase {
                Image(systemName: "mic.slash")
                    .font(.system(size: Self.mic, weight: .medium))
                Text(message)
                    .font(.system(size: 12 * k, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 8 * k)
            } else {
                Image(systemName: phase == .tick ? "checkmark" : "mic.fill")
                    .font(.system(size: Self.mic, weight: .semibold))
                    .foregroundStyle(phase == .tick ? tickColor : Color.white)
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .symbolEffect(.pulse, isActive: phase == .transcribing)
                    .scaleEffect(1 + (live ? model.bump : 0) * 0.28)
                    .shadow(color: tint.opacity(0.85), radius: (2 + lv * 6) * k)
                    .frame(width: Self.mic, height: Self.mic)
                ThreadCanvas(model: model, now: now, tint: tint)
                    .frame(width: open ? Self.slotSize.width : 0, alignment: .leading)
                    .clipped()
                    .opacity(open ? 1 : 0)
                    .padding(.leading, open ? Self.gap : 0)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Self.padding)
        .frame(height: Self.pillHeight)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color(white: 0.17).opacity(0.55), in: Capsule())
        .overlay { // specular top edge and shaded bottom
            Capsule().fill(LinearGradient(stops: [
                .init(color: .white.opacity(0.17), location: 0),
                .init(color: .white.opacity(0.03), location: 0.48),
                .init(color: .black.opacity(0.08), location: 1),
            ], startPoint: .top, endPoint: .bottom))
        }
        .overlay { // inner glow that follows the level
            Capsule().stroke(tint.opacity(lv * 0.5), lineWidth: (2 + lv * 10) * k)
                .blur(radius: (3 + lv * 8) * k)
                .clipShape(Capsule())
        }
        .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
        .overlay { // ring of light that leaves the pill as the check lands
            Capsule().stroke(tint.opacity(0.55 * (1 - flash)), lineWidth: 2 * k)
                .padding(-18 * k * flash)
        }
        .scaleEffect(1 + lv * 0.05)
        .shadow(color: .black.opacity(0.5), radius: (14 + lv * 8) * k, y: (10 + lv * 6) * k)
        .shadow(color: tint.opacity(lv * 0.5), radius: lv * 17 * k)
        // appear/dismiss: tilt up out of the desk through a blur
        .scaleEffect(hidden ? 0.7 : 1, anchor: .bottom)
        .offset(y: hidden ? 16 * k : 0)
        .rotation3DEffect(.degrees(hidden ? 38 : 0), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
        .blur(radius: hidden ? 6 : 0)
        .opacity(hidden ? 0 : 1)
    }
}

/// One luminous string from the mic to the end of the pill. It rings with
/// the voice, goes taut while transcribing with light running along it,
/// and sends one pulse back to the mic when the text has landed.
private struct ThreadCanvas: View {
    let model: IndicatorModel
    let now: Date
    let tint: Color

    var body: some View {
        Canvas { context, size in draw(context, size) }
            .frame(width: 66 * IndicatorView.scale, height: 22 * IndicatorView.scale)
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let k = IndicatorView.scale
        let length = size.width
        let mid = size.height / 2
        let segments = 40
        let a1 = model.a1, a2 = model.a2, ph1 = model.ph1, ph2 = model.ph2
        func y(_ x: CGFloat, _ ph: CGFloat) -> CGFloat {
            let u = x / length
            return mid + (a1 * sin(.pi * u) * sin(ph1 + ph) + a2 * sin(2 * .pi * u) * sin(ph2 + ph)) * mid * 0.9
        }
        func envelope(_ x: CGFloat) -> CGFloat {
            let u = x / length
            return (a1 * sin(.pi * u) + a2 * abs(sin(2 * .pi * u))) * mid * 0.9
        }
        func string(_ ph: CGFloat) -> Path {
            var p = Path()
            for i in 0...segments {
                let x = CGFloat(i) / CGFloat(segments) * length
                i == 0 ? p.move(to: CGPoint(x: x, y: y(x, ph))) : p.addLine(to: CGPoint(x: x, y: y(x, ph)))
            }
            return p
        }
        var band = Path()
        for i in 0...segments {
            let x = CGFloat(i) / CGFloat(segments) * length
            i == 0 ? band.move(to: CGPoint(x: x, y: mid - envelope(x))) : band.addLine(to: CGPoint(x: x, y: mid - envelope(x)))
        }
        for i in stride(from: segments, through: 0, by: -1) {
            let x = CGFloat(i) / CGFloat(segments) * length
            band.addLine(to: CGPoint(x: x, y: mid + envelope(x)))
        }
        band.closeSubpath()
        let full = Path(CGRect(origin: .zero, size: size))

        // light on the wire: where it is, how bright, how big
        let t = now.timeIntervalSince(model.phaseStart)
        var px: CGFloat = -1, bright: CGFloat = 0, big: CGFloat = 1
        switch model.phase {
        case .listening: // a slow light every 2.2 s, fading out while speaking
            let p = t.truncatingRemainder(dividingBy: 2.2) / 2.2
            if p < 0.55 { px = CGFloat(p / 0.55) * length; bright = 0.55 * (1 - min(1, model.smooth * 4)) }
        case .transcribing:
            px = CGFloat(t.truncatingRemainder(dividingBy: 0.9) / 0.9) * length; bright = 1; big = 1.4
        case .done:
            let p = CGFloat(min(1, t / 0.15))
            if p < 1 { px = (1 - p) * length; bright = 1 - p * 0.5; big = 1.4 }
        default: break
        }

        context.drawLayer { layer in
            var glow = layer // the blur of the moving string
            glow.addFilter(.shadow(color: tint.opacity(0.8), radius: 6 * k))
            glow.fill(band, with: .color(tint.opacity(0.16)))
            for j in 0..<3 { // three phases of the string
                let path = string(CGFloat(j) * 2.094)
                if j == 0 {
                    var main = layer
                    main.addFilter(.shadow(color: tint.opacity(0.9), radius: 3 * k))
                    main.stroke(path, with: .color(tint.opacity(0.92)), lineWidth: 1.4 * k)
                    layer.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.6 * k) // hot core
                } else {
                    layer.stroke(path, with: .color(tint.opacity(0.3)), lineWidth: 0.9 * k)
                }
            }
            if px >= 0, bright > 0.01 {
                let half = length * 0.14
                layer.blendMode = .sourceAtop
                layer.fill(full, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), .white.opacity(bright), .white.opacity(0)]),
                    startPoint: CGPoint(x: px - half, y: 0), endPoint: CGPoint(x: px + half, y: 0)))
                layer.blendMode = .normal
                var dot = layer
                dot.addFilter(.shadow(color: .white, radius: 8 * big * k))
                let r = 1.1 * big * k
                dot.fill(Path(ellipseIn: CGRect(x: px - r, y: y(px, 0) - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.5 + bright * 0.5)))
            }
        }
    }
}
