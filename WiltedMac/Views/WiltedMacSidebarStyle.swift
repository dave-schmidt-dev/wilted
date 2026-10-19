import SwiftUI
import WiltedProducer

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

    /// A playlist kind tag's text and fill. The fill makes the tag read as a label of its own,
    /// not a second line of the name; Smart takes the leaf and Manual the steel, so the two
    /// kinds differ at a glance as well as by word.
    static func kindTag(_ kind: PlaylistKind) -> (text: WiltedTheme.ColorToken, fill: WiltedTheme.ColorToken, fillOpacity: Double) {
        switch kind {
        case .automatic: (.wiltedLeaf, .wiltedLeaf, 0.18)
        case .manual: (.secondaryText, .steel, 0.7)
        }
    }
}

extension PlaylistKind {
    /// The word the Mac shows for the kind: Smart for a playlist built from rules.
    var displayName: String {
        switch self {
        case .manual: "Manual"
        case .automatic: "Smart"
        }
    }

    /// Hand-picked items go in a basket; rules strain the Larder like a colander.
    var symbol: WiltedSymbol {
        switch self {
        case .manual: .basket
        case .automatic: .colander
        }
    }
}

/// The capsule that names a playlist's kind beside its name in the sidebar and on its page.
struct WiltedMacPlaylistKindTag: View {
    let kind: PlaylistKind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = WiltedMacSidebarStyle.kindTag(kind)
        Text(kind.displayName)
            .fontWeight(.semibold)
            .wiltedFont(.caption)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(WiltedTheme.color(style.text, scheme: colorScheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(WiltedTheme.color(style.fill, scheme: colorScheme).opacity(style.fillOpacity), in: Capsule())
            .accessibilityLabel("\(kind.displayName) playlist")
            .accessibilityIdentifier("wilted-playlist-kind-\(kind.rawValue)")
    }
}
