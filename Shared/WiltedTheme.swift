import SwiftUI

/// The visual vocabulary shared by the Mac producer and iPhone listener.
///
/// `WiltedTheme` keeps color selection in one place while retaining a pure
/// numeric palette for contrast tests. The light leaf is intentionally darker
/// than the identity leaf used on the dark page so it remains readable on
/// paper without turning the interface into a green-on-green theme.
public enum WiltedTheme {
    public enum ColorToken: String, CaseIterable, Sendable {
        case page
        case card
        case primaryText
        case secondaryText
        case wiltedLeaf
        case progress
        case steel
        case success
        case stale
        case degraded
        case error
    }

    public enum TypographyRole: String, CaseIterable, Sendable {
        case display
        case title
        case body
        case utility
        case caption
    }

    public enum Spacing {
        public static let xSmall: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xLarge: CGFloat = 24
        public static let section: CGFloat = 32
        public static let minimumTouchTarget: CGFloat = 44
    }

    /// Dark Zero Delta values from the native MVP design contract.
    public static let darkHex: [ColorToken: UInt32] = [
        .page: 0x0D110F,
        .card: 0x151B17,
        .primaryText: 0xECF2ED,
        .secondaryText: 0x92A398,
        .wiltedLeaf: 0x7FD48C,
        .progress: 0x4FB477,
        .steel: 0x26332C,
        .success: 0x6FCF97,
        .stale: 0xE8C468,
        .degraded: 0xE79A5C,
        .error: 0xF08585
    ]

    /// Accessible paper values. `wiltedLeaf` is frozen at #4D6B22 by the
    /// contrast tests in both native test targets.
    public static let lightHex: [ColorToken: UInt32] = [
        .page: 0xF4F7F3,
        .card: 0xFFFFFF,
        .primaryText: 0x141815,
        .secondaryText: 0x4F5D54,
        .wiltedLeaf: 0x4D6B22,
        .progress: 0x1E6F4C,
        .steel: 0xC3D2C7,
        .success: 0x1F6B3C,
        .stale: 0x7A5900,
        .degraded: 0x9A4B00,
        .error: 0xA93030
    ]

    public static func color(_ token: ColorToken, scheme: ColorScheme) -> Color {
        Color(hex: hex(for: token, scheme: scheme))
    }

    public static func hex(for token: ColorToken, scheme: ColorScheme) -> UInt32 {
        (scheme == .dark ? darkHex : lightHex)[token] ?? 0
    }

    /// Returns the WCAG relative-luminance contrast ratio for two sRGB colors.
    /// This pure helper lets native tests verify the palette without scraping
    /// SwiftUI's opaque `Color` representation.
    public static func contrastRatio(_ foreground: UInt32, _ background: UInt32) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public static func font(_ role: TypographyRole) -> Font {
        switch role {
        case .display:
            .system(size: 30, weight: .semibold, design: .default)
        case .title:
            .system(.title2, design: .default).weight(.semibold)
        case .body:
            .system(.body, design: .default)
        case .utility:
            .system(size: 12, weight: .medium, design: .monospaced)
        case .caption:
            .system(.caption, design: .monospaced)
        }
    }

    private static func relativeLuminance(_ hex: UInt32) -> Double {
        let components = [
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        ].map { component in
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
    }
}

extension Color {
    /// Creates an opaque sRGB color from a six-digit RGB value.
    public init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
