import SwiftUI

/// The app-wide visual palette, sampled from the OpenVox icon's cobalt and
/// cyan range. Every product surface uses these adaptive colors so the main
/// window and onboarding feel like one macOS app in light and dark mode.
enum OpenVoxPalette {
    static func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.35, green: 0.78, blue: 1.00)
            : Color(red: 0.10, green: 0.36, blue: 0.78)
    }

    static func wash(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.07, green: 0.16, blue: 0.29)
            : Color(red: 0.90, green: 0.95, blue: 1.00)
    }

    static func selection(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.14, blue: 0.27)
            : Color(red: 0.93, green: 0.96, blue: 1.00)
    }

    static func footer(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(nsColor: .underPageBackgroundColor).opacity(0.42)
            : Color(nsColor: .underPageBackgroundColor).opacity(0.55)
    }
}
