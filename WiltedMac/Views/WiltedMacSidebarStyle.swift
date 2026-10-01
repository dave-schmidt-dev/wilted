import SwiftUI

/// The colours a sidebar row names for itself.
///
/// Sidebar rows must never inherit the system accent: on macOS 26+ the
/// sidebar list style tints row icons with it, and an unset accent is system
/// blue. Selection is carried by the leaf, everything else by the palette's
/// text tokens. Kept as pure token choices so a test can pin them.
enum WiltedMacSidebarStyle {
    static func iconToken(isSelected: Bool) -> WiltedTheme.ColorToken {
        isSelected ? .wiltedLeaf : .secondaryText
    }

    static func titleToken(isSelected: Bool) -> WiltedTheme.ColorToken {
        isSelected ? .primaryText : .secondaryText
    }

    static func iconColor(isSelected: Bool, scheme: ColorScheme) -> Color {
        WiltedTheme.color(iconToken(isSelected: isSelected), scheme: scheme)
    }

    static func titleColor(isSelected: Bool, scheme: ColorScheme) -> Color {
        WiltedTheme.color(titleToken(isSelected: isSelected), scheme: scheme)
    }
}
