import SwiftUI

/// Palette from the reference image.
enum Theme {
    static let sage      = Color(hex: 0x719A73) // Sage Green
    static let evergreen = Color(hex: 0x003A35) // Evergreen
    static let ink       = Color(hex: 0x001F27) // Ink Black
    static let marine    = Color(hex: 0x1F73C2) // Bright Marine

    static let background = ink
    static let surface    = evergreen
    static let textPrimary = Color.white
    static let textMuted   = sage

    // Overspending
    static let amaranth    = Color(hex: 0x961737) // Dark Amaranth: over-budget bar fill
    static let blackCherry = Color(hex: 0x5A1010) // Black Cherry: over-budget bar track
    /// Over-budget text and outlines. A lighter amaranth tint: the swatches themselves are too dark
    /// to read on `ink`/`evergreen` (~1.5:1), this is ~5:1 on evergreen and ~6.8:1 on ink.
    static let overspend   = Color(hex: 0xE8879A)

    static let categoryColors: [Color] = [marine, sage, Color(hex: 0x4F8FD6), Color(hex: 0x9DBF9E), Color(hex: 0x2E6B5E)]
    static let corner: CGFloat = 20
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension Font {
    static let heroNumber = Font.system(size: 40, weight: .heavy, design: .rounded)
    static let cardTitle  = Font.system(.headline, design: .rounded).weight(.bold)
}
