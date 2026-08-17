import SwiftUI

/// The restrained local identity: two leaf curves around a three-step sound
/// notch. It is a vector shape so the same geometry works at icon, header, and
/// progress-indicator sizes without raster assets or decorative animation.
public struct WiltedMark: View {
    private let size: CGFloat
    private let color: Color
    private let lineWidth: CGFloat

    public init(
        size: CGFloat = 28,
        color: Color? = nil,
        lineWidth: CGFloat = 2
    ) {
        self.size = size
        self.color = color ?? WiltedTheme.color(.wiltedLeaf, scheme: .dark)
        self.lineWidth = lineWidth
    }

    public var body: some View {
        WiltedMarkShape()
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("Wilted")
            .accessibilityAddTraits(.isImage)
    }

    /// Stable geometry identifier used by visual drift tests.
    /// This is presentation-independent data, so keep it available from
    /// headless render-signature code without inheriting SwiftUI's main-actor
    /// isolation.
    nonisolated public static let geometrySignature = "leaf-curves:sound-notch:v1"
}

public struct WiltedMarkShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let x = rect.minX
        let y = rect.minY
        let w = rect.width
        let h = rect.height
        let midX = x + w * 0.5
        let baseY = y + h * 0.82

        var path = Path()
        path.move(to: CGPoint(x: midX, y: baseY))
        path.addCurve(
            to: CGPoint(x: x + w * 0.12, y: y + h * 0.28),
            control1: CGPoint(x: x + w * 0.19, y: y + h * 0.74),
            control2: CGPoint(x: x + w * 0.08, y: y + h * 0.51)
        )
        path.addCurve(
            to: CGPoint(x: midX, y: y + h * 0.12),
            control1: CGPoint(x: x + w * 0.23, y: y + h * 0.12),
            control2: CGPoint(x: x + w * 0.42, y: y + h * 0.11)
        )
        path.move(to: CGPoint(x: midX, y: baseY))
        path.addCurve(
            to: CGPoint(x: x + w * 0.88, y: y + h * 0.28),
            control1: CGPoint(x: x + w * 0.81, y: y + h * 0.74),
            control2: CGPoint(x: x + w * 0.92, y: y + h * 0.51)
        )
        path.addCurve(
            to: CGPoint(x: midX, y: y + h * 0.12),
            control1: CGPoint(x: x + w * 0.77, y: y + h * 0.12),
            control2: CGPoint(x: x + w * 0.58, y: y + h * 0.11)
        )

        // A sound-wave notch remains legible at small sizes and is not a
        // filled illustration: three short strokes interrupt the leaves.
        for (index, height) in [0.24, 0.38, 0.52].enumerated() {
            let offset = CGFloat(index) * w * 0.1 - w * 0.1
            let center = CGPoint(x: midX + offset, y: y + h * 0.47)
            path.move(to: CGPoint(x: center.x, y: center.y - h * height * 0.22))
            path.addLine(to: CGPoint(x: center.x, y: center.y + h * height * 0.22))
        }
        return path
    }
}
