import SwiftUI
import WiltedDomain

/// A large lettuce, cropped by the bottom corner, drawn faintly over a page. The same mark sits
/// behind Settings and the Larder so the two read as one app. It never takes a touch.
///
/// The phone draws it at a fixed size, cropped by the corner. A window has room to show the whole
/// mark, so `fitting` draws it larger and keeps all of it inside the area it is given, clear of the
/// scroller, shrinking it for a short or narrow area instead of clipping it. `topInset` keeps the
/// top of that area clear too, for a page whose head (title, totals, filters) the mark must not
/// sit under.
public struct LibraryWatermark: View {
    /// The phone's size and offset. Fixed: `fitting` is the only way to change either.
    public static let phoneSize: CGFloat = 380
    public static let phoneOffset = CGSize(width: 80, height: 90)
    /// The largest the windowed form grows to, twice the phone's.
    public static let windowedSize: CGFloat = 760
    static let rotationDegrees: Double = -14
    /// What a square turned by `rotationDegrees` needs, as a multiple of its side.
    static let rotatedExtent: CGFloat = cos(14 * .pi / 180) + sin(14 * .pi / 180)
    /// The room left clear on the right (the scroller) and at the bottom.
    static let fittingInset = EdgeInsets(top: 0, leading: 0, bottom: 24, trailing: 36)

    @Environment(\.colorScheme) private var colorScheme
    private let fitting: Bool
    private let topInset: CGFloat

    public init(fitting: Bool = false, topInset: CGFloat = 0) {
        self.fitting = fitting
        self.topInset = max(0, topInset)
    }

    /// The side the glyph is drawn at inside an area of this size, with `topInset` kept clear.
    static func fittedSize(in area: CGSize, topInset: CGFloat = 0) -> CGFloat {
        let room = min(
            area.width - fittingInset.trailing - fittingInset.leading,
            area.height - topInset - fittingInset.top - fittingInset.bottom)
        return max(0, min(windowedSize, room / rotatedExtent))
    }

    public var body: some View {
        if fitting {
            GeometryReader { geometry in
                let side = Self.fittedSize(in: geometry.size, topInset: topInset)
                fittedGlyph(side)
                    .frame(width: side * Self.rotatedExtent, height: side * Self.rotatedExtent)
                    .padding(Self.fittingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            glyph(Self.phoneSize)
                .offset(x: Self.phoneOffset.width, y: Self.phoneOffset.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Sized by its frame rather than a font, so the drawn mark fills the square the fit was worked
    /// out for: a font-sized symbol sits in a taller box and would drift out of its area.
    private func fittedGlyph(_ side: CGFloat) -> some View {
        Image(.lettuce)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.09))
            .rotationEffect(.degrees(Self.rotationDegrees))
    }

    private func glyph(_ side: CGFloat) -> some View {
        Image(.lettuce)
            .font(.system(size: side))
            .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.09))
            .rotationEffect(.degrees(Self.rotationDegrees))
    }
}
