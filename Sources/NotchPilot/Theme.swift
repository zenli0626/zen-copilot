import SwiftUI

/// Claude brand design tokens — the single source of truth for color, radius,
/// spacing, and typography across the notch UI.
///
/// The palette is Claude's authentic WARM-DARK product-chrome (not pure black,
/// not cream): a low-chroma warm-grey surface, warm cream-white text, a single
/// reserved coral accent for the brand mark + primary action, and warm semantic
/// status tones. Serif (New York) is reserved for the wordmark/display text;
/// everything else stays the humanist system sans, and code-ish text is mono.
///
/// Usage: `Color.cl.surfaceDark`, `Theme.Radius.lg`, `Theme.Space.md`,
/// `Theme.serif(15)`.
enum Theme {

    // MARK: - Radii

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        // `pill` → use `Capsule()` at the call site.
    }

    // MARK: - Spacing scale (pts): 4 / 8 / 12 / 16 / 24

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - Typography

    /// Serif display font (New York) — approximates Claude's editorial serif
    /// (Copernicus/Tiempos). Reserve for the "Zen-Copilot" wordmark + display text.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Color: hex initializer + Claude palette

extension Color {

    /// Build a `Color` from a hex string (`"#RRGGBB"`, `"RRGGBB"`, or
    /// `"#RRGGBBAA"`). Falls back to opaque black on a malformed string.
    init(hex: String, opacity: Double = 1.0) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)

        let r, g, b: Double
        var a = opacity
        switch s.count {
        case 8: // RRGGBBAA
            r = Double((value & 0xFF00_0000) >> 24) / 255
            g = Double((value & 0x00FF_0000) >> 16) / 255
            b = Double((value & 0x0000_FF00) >> 8) / 255
            a = Double(value & 0x0000_00FF) / 255
        case 6: // RRGGBB
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Namespace for Claude brand colors: `Color.cl.surfaceDark`, etc.
    static let cl = ClaudeColors()
}

/// Claude brand color constants. Accessed via `Color.cl`.
struct ClaudeColors {
    // Surfaces (warm product-chrome dark — replaces pure black).
    let surfaceDark        = Color(hex: "#181715") // panel background
    let surfaceDarkElevated = Color(hex: "#252320") // cards / hovered rows / reply box
    let surfaceDarkSoft    = Color(hex: "#1f1e1b") // insets / input field bg

    // Text on dark.
    let onDark     = Color(hex: "#faf9f5") // primary — warm cream-white
    let onDarkSoft = Color(hex: "#a09d96") // secondary / muted

    // Subtle divider / border on dark (≈10% of onDark).
    let hairline = Color(hex: "#faf9f5", opacity: 0.10)

    // Accent — RESERVED for the brand mark + primary action. Do not splash.
    let coral       = Color(hex: "#cc785c")
    let coralActive = Color(hex: "#a9583e")

    // Semantic status tones (warm Claude palette).
    let success = Color(hex: "#5db872") // working
    let amber   = Color(hex: "#e8a55a") // waiting
    let teal    = Color(hex: "#5db8a6") // done
    let error   = Color(hex: "#c64545") // error
    // idle reuses `onDarkSoft`.
}
