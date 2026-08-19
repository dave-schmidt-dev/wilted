import SwiftUI

/// The Wilted brand mark: a single continuous stroke that draws a `W` whose
/// outer terminals curl over like a wilting stem.
///
/// The geometry is a direct transcription of the balanced D6 master in
/// `brand/wilted-mark-master.svg`, kept in that file's 1024-unit design space
/// so the in-app mark and the generated app icon cannot drift apart. It is a
/// vector shape, so the same path serves the 32pt header lockup, the 64pt
/// Now Playing mark, and the 1024px icon without raster assets.
public struct WiltedMark: View {
    @Environment(\.colorScheme) private var colorScheme
    private let size: CGFloat
    private let color: Color?
    private let lineWidth: CGFloat?

    /// - Parameters:
    ///   - size: Edge length of the square the mark is drawn into.
    ///   - color: Defaults to the `wiltedLeaf` token for the ambient scheme.
    ///   - lineWidth: Defaults to the master's proportional stroke. Pass a
    ///     value only to deliberately depart from the brand weight.
    public init(
        size: CGFloat = 28,
        color: Color? = nil,
        lineWidth: CGFloat? = nil
    ) {
        self.size = size
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        WiltedMarkShape()
            .stroke(
                color ?? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme),
                style: StrokeStyle(
                    lineWidth: lineWidth ?? size * WiltedMarkShape.strokeRatio,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("Wilted")
            .accessibilityAddTraits(.isImage)
    }

    /// Stable geometry identifier used by visual drift tests.
    /// This is presentation-independent data, so keep it available from
    /// headless render-signature code without inheriting SwiftUI's main-actor
    /// isolation.
    nonisolated public static let geometrySignature = "single-stroke-w:balanced-d6:v2"
}

/// The brand mark as an unstroked path.
///
/// Coordinates are the master SVG's own 1024-unit space, scaled to whatever
/// rect the shape is handed. Keeping the source numbers verbatim means a
/// change to the master can be diffed against this file line by line.
public struct WiltedMarkShape: Shape {
    /// Design-space edge length of the master artboard.
    public static let designSize: CGFloat = 1024

    /// Master stroke weight as a fraction of the artboard, so the mark keeps
    /// its brand weight at every size instead of thinning as it scales up.
    public static let strokeRatio: CGFloat = 108 / designSize

    public init() {}

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.designSize
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }

        var path = Path()
        path.move(to: point(258, 272))
        // Left terminal curling back on itself.
        path.addCurve(
            to: point(220, 318),
            control1: point(220, 226),
            control2: point(196, 254)
        )
        // Down the first stem.
        path.addCurve(
            to: point(356, 744),
            control1: point(274, 463),
            control2: point(313, 611)
        )
        // Rounded valley into the centre rise.
        path.addCurve(
            to: point(435, 744),
            control1: point(373, 797),
            control2: point(411, 800)
        )
        path.addLine(to: point(503, 583))
        // The centre peak.
        path.addCurve(
            to: point(565, 583),
            control1: point(520, 543),
            control2: point(548, 543)
        )
        path.addLine(to: point(635, 744))
        // Second valley.
        path.addCurve(
            to: point(714, 744),
            control1: point(659, 800),
            control2: point(697, 797)
        )
        // Up the final stem.
        path.addCurve(
            to: point(850, 318),
            control1: point(757, 611),
            control2: point(796, 463)
        )
        // Right terminal, mirroring the left.
        path.addCurve(
            to: point(812, 272),
            control1: point(874, 254),
            control2: point(850, 226)
        )
        return path
    }
}
