import SwiftUI

/// The app-wide visual palette. The accent is sampled from the OpenVox
/// icon's cobalt and cyan range; every other tint is that accent at low
/// opacity, so a surface stays in key with the accent in light and dark
/// mode. Every other colour in the app is a system semantic colour.
enum OpenVoxPalette {
    /// Text and glyphs use this, so it stays dark enough on a light surface
    /// and light enough on a dark one.
    static func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.35, green: 0.78, blue: 1.00)
            : Color(red: 0.10, green: 0.36, blue: 0.78)
    }

    /// A tint behind an icon. Decoration only: nothing reads against it.
    static func wash(for colorScheme: ColorScheme) -> Color {
        accent(for: colorScheme).opacity(colorScheme == .dark ? 0.26 : 0.12)
    }

    /// A tint over a card that is selected. It sits on the card surface, so
    /// the card keeps the standard control background under it.
    static func selection(for colorScheme: ColorScheme) -> Color {
        accent(for: colorScheme).opacity(colorScheme == .dark ? 0.20 : 0.08)
    }

    /// Card fill on the window background. Light cards are white. Dark
    /// cards sit a shade above the window, never below it, so they read as
    /// raised content the way grouped rows do in System Settings.
    static func cardFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color(nsColor: .controlBackgroundColor)
    }

    static func cardStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.08)
    }
}

/// The grouped-content card: white in Light, a shade lighter than the
/// window in Dark, with a hairline, the way System Settings draws its rows.
struct CardBackground: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(OpenVoxPalette.cardFill(for: colorScheme), in: shape)
            .overlay { shape.strokeBorder(OpenVoxPalette.cardStroke(for: colorScheme)) }
    }
}

extension View {
    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}
