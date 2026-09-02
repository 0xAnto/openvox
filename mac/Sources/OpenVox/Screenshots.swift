import AppKit

@_silgen_name("CGWindowListCreateImage")
private func cgWindowListCreateImage(_ rect: CGRect, _ option: UInt32, _ windowID: UInt32, _ imageOption: UInt32) -> Unmanaged<CGImage>?

/// Dev tooling behind `OpenVox --screenshots <dir>`. It captures the app's
/// own windows through the window server, which needs no Screen Recording
/// grant, and writes the PNGs a pull request needs. Not part of the product.
enum WindowCapture {
    /// The window as the window server composites it, at Retina scale.
    // ponytail: CGWindowListCreateImage is deprecated in favour of
    // ScreenCaptureKit, but the C symbol still works for a process's own
    // windows on macOS 14 and 15 without a Screen Recording grant. Move to
    // SCScreenshotManager if a later macOS drops it.
    static func image(of window: NSWindow) -> CGImage? {
        cgWindowListCreateImage(
            .null,
            CGWindowListOption.optionIncludingWindow.rawValue,
            CGWindowID(window.windowNumber),
            CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
        )?.takeRetainedValue()
    }

    /// Writes `image` as PNG. `background` fills behind a translucent
    /// window, so the indicator panel can be shown over a light and a dark
    /// desktop.
    static func write(_ image: CGImage, to url: URL, over background: NSColor? = nil) throws {
        let size = NSSize(width: image.width, height: image.height)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let background {
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        NSGraphicsContext.current?.cgContext.draw(image, in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    static func capture(_ window: NSWindow, name: String, in directory: URL, over background: NSColor? = nil) {
        guard let image = image(of: window) else {
            FileHandle.standardError.write(Data("openvox: capture failed for \(name) (window \(window.windowNumber), visible \(window.isVisible))\n".utf8))
            return
        }
        do {
            try write(image, to: directory.appendingPathComponent("\(name).png"), over: background)
        } catch {
            FileHandle.standardError.write(Data("openvox: write failed for \(name): \(error)\n".utf8))
        }
    }
}

/// Walks the product window through every page, theme, and size, then the
/// indicator through its states, and captures each one. Runs behind
/// `OpenVox --screenshots <dir>` and quits when done.
final class ScreenshotRun {
    struct Hooks {
        let window: () -> NSWindow?
        let show: (ProductNavigation.Destination) -> Void
        /// Opens History on the newest entry, so the inspector is open.
        let openNewestEntry: () -> Void
        let setAppearance: (AppState.Appearance) -> Void
        let showOnboarding: () -> NSWindow?
        let indicator: IndicatorPanel
    }

    private let directory: URL
    private let hooks: Hooks
    private var steps: [(delay: TimeInterval, action: () -> Void)] = []
    private var levelTimer: Timer?

    init(directory: URL, hooks: Hooks) {
        self.directory = directory
        self.hooks = hooks
    }

    private func step(after delay: TimeInterval, _ action: @escaping () -> Void) {
        steps.append((delay, action))
    }

    private func capture(_ name: String, over background: NSColor? = nil) {
        guard let window = hooks.window() else { return }
        WindowCapture.capture(window, name: name, in: directory, over: background)
    }

    private func pages(_ suffix: String) {
        for page in ProductNavigation.Destination.allCases {
            step(after: 0.9) { self.hooks.show(page) }
            step(after: 1.2) { self.capture("\(page.rawValue)-\(suffix)") }
        }
        step(after: 0.2) { self.hooks.openNewestEntry() }
        step(after: 1.2) { self.capture("history-inspector-\(suffix)") }
        // Escape closes the inspector. This also proves the key path works.
        step(after: 0.2) { self.pressEscape() }
        step(after: 0.8) { self.capture("history-after-escape-\(suffix)") }
    }

    /// Escape from the list, as a user who clicked a row would send it.
    private func pressEscape() {
        guard let window = hooks.window() else { return }
        if let content = window.contentView,
           let table = Self.tableViews(in: content).max(by: { $0.bounds.width < $1.bounds.width }) {
            window.makeFirstResponder(table)
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false, keyCode: 53
            ) else { return }
            NSApp.sendEvent(event)
        }
    }

    private static func tableViews(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView { found.append(table) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    private func setSize(_ size: NSSize) {
        guard let window = hooks.window(), let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private func indicator(_ theme: String) {
        let panel = hooks.indicator
        let light = NSColor(white: 0.93, alpha: 1)
        let dark = NSColor(white: 0.16, alpha: 1)
        func captureIndicator(_ state: String) {
            WindowCapture.capture(panel, name: "indicator-\(state)-\(theme)-on-light", in: directory, over: light)
            WindowCapture.capture(panel, name: "indicator-\(state)-\(theme)-on-dark", in: directory, over: dark)
        }
        step(after: 0.5) {
            var t = 0.0
            self.levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                t += 1.0 / 30.0
                let syllable = max(0, sin(t * 9.5)) * max(0, sin(t * 2.1 + 0.7) + 0.3)
                panel.show(state: .listening(level: Float(0.03 + syllable * 0.12)))
            }
        }
        step(after: 1.6) { captureIndicator("listening") }
        step(after: 0.1) {
            self.levelTimer?.invalidate()
            self.levelTimer = nil
            panel.show(state: .transcribing)
        }
        step(after: 0.7) { captureIndicator("transcribing") }
        step(after: 0.1) { panel.show(state: .done) }
        step(after: 0.28) { captureIndicator("done") }
        step(after: 1.5) {}
    }

    func start(completion: @escaping () -> Void) {
        for theme in [AppState.Appearance.light, .dark] {
            step(after: 0.3) { self.hooks.setAppearance(theme) }
            step(after: 0.3) { self.setSize(NSSize(width: 1_020, height: 720)) }
            pages(theme.rawValue)
            step(after: 0.3) { self.setSize(NSSize(width: 860, height: 600)) }
            pages("\(theme.rawValue)-860")
            step(after: 0.3) { self.hooks.window()?.toggleFullScreen(nil) }
            step(after: 2.5) {}
            pages("\(theme.rawValue)-fullscreen")
            step(after: 0.3) { self.hooks.window()?.toggleFullScreen(nil) }
            step(after: 2.5) { self.setSize(NSSize(width: 1_020, height: 720)) }
            step(after: 0.5) {
                if let onboarding = self.hooks.showOnboarding() {
                    WindowCapture.capture(onboarding, name: "onboarding-\(theme.rawValue)", in: self.directory)
                }
            }
            step(after: 1.2) {
                if let onboarding = self.hooks.showOnboarding() {
                    WindowCapture.capture(onboarding, name: "onboarding-\(theme.rawValue)", in: self.directory)
                    onboarding.orderOut(nil)
                }
            }
            indicator(theme.rawValue)
        }
        step(after: 0.2, completion)
        run(index: 0)
    }

    private func run(index: Int) {
        guard index < steps.count else { return }
        let step = steps[index]
        DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
            step.action()
            self.run(index: index + 1)
        }
    }
}
