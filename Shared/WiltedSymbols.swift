import SwiftUI

/// The app's own symbols, drawn in the SF Symbols app and exported as
/// variable templates into `WiltedSymbols.xcassets`, which both app targets
/// compile. They take weights, scales, and rendering modes like any system
/// symbol; the difference is only where `Image` looks them up.
///
/// Where each one belongs: the larder is the Larder, the cutting board is
/// Prep, the food processor is a preparation in progress, and the produce is
/// the produce -- lettuce for an article, cabbage for an episode, broccoli for
/// a feed.
public enum WiltedSymbol: String, CaseIterable, Sendable {
    case larder = "wilted.larder"
    case prep = "wilted.prep"
    case processor = "wilted.processor"
    case lettuce = "wilted.lettuce"
    case cabbage = "wilted.cabbage"
    case broccoli = "wilted.broccoli"

    /// Every custom symbol's name starts with this; nothing in SF Symbols does.
    public static let prefix = "wilted."

    public static func isCustom(_ name: String) -> Bool { name.hasPrefix(prefix) }
}

public extension Image {
    /// A symbol by name: one of ours when the name carries the `wilted.`
    /// prefix, otherwise a system symbol. Lets one `symbolName` string
    /// describe either without every call site knowing which.
    init(symbol name: String) {
        if WiltedSymbol.isCustom(name) {
            self.init(name)
        } else {
            self.init(systemName: name)
        }
    }

    init(_ symbol: WiltedSymbol) {
        self.init(symbol.rawValue)
    }
}

public extension Label where Title == Text, Icon == Image {
    /// `Label(_:systemImage:)` for a name that may be one of ours.
    init(_ title: String, symbol name: String) {
        self.init { Text(title) } icon: { Image(symbol: name) }
    }

    init(_ title: String, symbol: WiltedSymbol) {
        self.init(title, symbol: symbol.rawValue)
    }
}

/// The square tile a row shows in place of artwork: a produce symbol on a
/// leaf-tinted ground, the same size the artwork would be.
public struct WiltedProduceTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbol: WiltedSymbol
    let size: CGFloat

    public init(symbol: WiltedSymbol, size: CGFloat) {
        self.symbol = symbol
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
            .fill(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.2))
            .frame(width: size, height: size)
            .overlay(
                Image(symbol)
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            )
    }
}
