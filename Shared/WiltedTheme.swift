import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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

    /// How much bigger than the platform's own text the app draws itself.
    ///
    /// macOS has no Dynamic Type: the pixel gate renders every state at both
    /// `.medium` and `.xxxLarge` and all 38 pairs are byte-identical, so
    /// `.dynamicTypeSize` cannot carry this on the Mac and the app has to own
    /// the scale. `standard` is the platform's own sizing, kept exactly --
    /// it returns the same semantic fonts the app used before there was a
    /// choice -- so it stays the reference the other steps are measured from.
    public enum TextScale: String, CaseIterable, Sendable, Identifiable {
        case standard
        case large
        case larger
        case largest

        public var id: String { rawValue }

        public var multiplier: CGFloat {
            switch self {
            case .standard: 1.0
            case .large: 1.2
            case .larger: 1.4
            case .largest: 1.6
            }
        }

        /// What the setting calls each step. `standard` says whose standard it
        /// is, because on a Mac 13pt body text is the system's choice, not ours.
        public var label: String {
            switch self {
            case .standard: "System"
            case .large: "Large"
            case .larger: "Larger"
            case .largest: "Largest"
            }
        }
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
        font(role, scale: .standard)
    }

    /// The role's font at a chosen scale.
    ///
    /// At `.standard` this returns exactly what it always returned, semantic
    /// text styles included, so nothing about the platform's own rendering is
    /// reinterpreted when the reader has not asked for a change. Above it the
    /// two semantic roles have to become concrete point sizes, because a text
    /// style cannot be multiplied -- the size they resolve to is read from the
    /// platform rather than written down here, so a system that changes its
    /// own metrics moves this with it.
    public static func font(_ role: TypographyRole, scale: TextScale) -> Font {
        guard scale != .standard else {
            switch role {
            case .display:
                return .system(size: 30, weight: .semibold, design: .default)
            case .title:
                return .system(.title2, design: .default).weight(.semibold)
            case .body:
                return .system(.body, design: .default)
            case .utility:
                return .system(size: 12, weight: .medium, design: .monospaced)
            case .caption:
                return .system(.caption, design: .monospaced)
            }
        }
        let size = scaled(baseSize(role), scale: scale)
        switch role {
        case .display:
            return .system(size: size, weight: .semibold, design: .default)
        case .title:
            return .system(size: size, weight: .semibold, design: .default)
        case .body:
            return .system(size: size, design: .default)
        case .utility:
            return .system(size: size, weight: .medium, design: .monospaced)
        case .caption:
            return .system(size: size, design: .monospaced)
        }
    }

    /// A fixed measurement -- an artwork tile, a symbol well -- carried up with
    /// the text so an enlarged row does not draw big words beside a small
    /// picture. Rounded, because a half-pixel frame blurs the edge it draws.
    public static func scaled(_ base: CGFloat, scale: TextScale) -> CGFloat {
        (base * scale.multiplier).rounded()
    }

    /// What the two semantic roles actually measure on this platform. The
    /// display and utility roles were always literal sizes and stay literal.
    static func baseSize(_ role: TypographyRole) -> CGFloat {
        switch role {
        case .display: 30
        case .utility: 12
        case .title: platformSize(.title2, fallback: 17)
        case .body: platformSize(.body, fallback: 13)
        case .caption: platformSize(.caption, fallback: 10)
        }
    }

    /// The roles this app names, mapped to the styles the platform names.
    enum PlatformTextStyle { case title2, body, caption }

    private static func platformSize(_ style: PlatformTextStyle, fallback: CGFloat) -> CGFloat {
#if canImport(AppKit)
        let mapped: NSFont.TextStyle = switch style {
        case .title2: .title2
        case .body: .body
        case .caption: .caption1
        }
        return NSFont.preferredFont(forTextStyle: mapped).pointSize
#elseif canImport(UIKit)
        let mapped: UIFont.TextStyle = switch style {
        case .title2: .title2
        case .body: .body
        case .caption: .caption1
        }
        return UIFont.preferredFont(forTextStyle: mapped).pointSize
#else
        return fallback
#endif
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

/// The app's chosen text scale, read by `wiltedFont` and by the few fixed
/// measurements that have to keep pace with it. It defaults to `.standard`,
/// so a surface that never sets it -- the iPhone listener, which already has
/// the system's own Dynamic Type -- is unchanged by any of this.
private struct WiltedTextScaleKey: EnvironmentKey {
    static let defaultValue: WiltedTheme.TextScale = .standard
}

public extension EnvironmentValues {
    var wiltedTextScale: WiltedTheme.TextScale {
        get { self[WiltedTextScaleKey.self] }
        set { self[WiltedTextScaleKey.self] = newValue }
    }
}

private struct WiltedFontModifier: ViewModifier {
    @Environment(\.wiltedTextScale) private var scale
    let role: WiltedTheme.TypographyRole

    func body(content: Content) -> some View {
        content.font(WiltedTheme.font(role, scale: scale))
    }
}

private struct WiltedScaledSquare: ViewModifier {
    @Environment(\.wiltedTextScale) private var scale
    let base: CGFloat

    func body(content: Content) -> some View {
        let side = WiltedTheme.scaled(base, scale: scale)
        return content.frame(width: side, height: side)
    }
}

public extension View {
    /// A square well -- artwork, a transport glyph -- that grows with the text
    /// around it. A fixed frame would clip a symbol once the font moved.
    func wiltedSquare(_ base: CGFloat) -> some View {
        modifier(WiltedScaledSquare(base: base))
    }
}

public extension View {
    /// `.font(WiltedTheme.font(role))` that honours the reader's chosen scale.
    /// Every typographic site in both apps goes through this rather than
    /// setting a font directly, so there is one place the scale can miss.
    func wiltedFont(_ role: WiltedTheme.TypographyRole) -> some View {
        modifier(WiltedFontModifier(role: role))
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
