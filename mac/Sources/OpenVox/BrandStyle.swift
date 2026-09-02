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
}
