import SwiftUI

/// The Wilted wordmark: outlined lowercase "wilted" with a leaf replacing the
/// dot on the i.
///
/// Unlike ``WiltedMark``, this is not transcribed into a `Shape`. The
/// letterforms are outlined EB Garamond derivatives — several hundred Bézier
/// segments with no font dependency — so they ship as the vendored
/// `brand/wilted-wordmark-*.svg` masters, copied verbatim into each target's
/// asset catalog as a light/dark pair. Xcode preserves the vector
/// representation, so this still scales without raster assets.
///
/// The masters are drawn on a 1120x330 artboard with generous, asymmetric
/// margins (the glyphs occupy 623x230 at an 83,21 origin). Fitting the whole
/// artboard would leave 37% of the width as trailing dead space, which pushes
/// neighbouring toolbar items right on macOS and visibly off-centres the
/// wordmark in an iOS navigation bar. So this view scales the artboard to the
/// requested *glyph* height and then crops back to the ink, letting callers
/// size the wordmark by what they can actually see.
public struct WiltedWordmark: View {
    /// Artboard and ink geometry of the vendored masters, in SVG user units.
    /// Update these together if `brand/wilted-wordmark-*.svg` is re-cut.
    private enum Artboard {
        static let width: CGFloat = 1120
        static let height: CGFloat = 330
        static let inkX: CGFloat = 83
        static let inkY: CGFloat = 21
        static let inkWidth: CGFloat = 623
        static let inkHeight: CGFloat = 230
    }

    private let height: CGFloat

    /// - Parameter height: Height of the visible letterforms, cap to baseline
    ///   descender, in points. The leaf on the i loses its shape below about
    ///   14pt and reads as a plain blob, so keep header and toolbar uses at or
    ///   above that.
    public init(height: CGFloat = 20) {
        self.height = height
    }

    public var body: some View {
        let scale = height / Artboard.inkHeight

        Image("Wordmark")
            .resizable()
            .interpolation(.high)
            .frame(width: Artboard.width * scale, height: Artboard.height * scale)
            .offset(x: -Artboard.inkX * scale, y: -Artboard.inkY * scale)
            .frame(
                width: Artboard.inkWidth * scale,
                height: height,
                alignment: .topLeading
            )
            .clipped()
            .accessibilityElement()
            .accessibilityLabel("Wilted")
            .accessibilityIdentifier("wilted-wordmark")
    }
}
