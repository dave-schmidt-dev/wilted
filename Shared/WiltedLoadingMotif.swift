import SwiftUI

/// Each approved size uses its own stroke geometry, drawn directly at native size.
enum WiltedLoadingMotifSize: CGFloat, CaseIterable {
    case compact = 20
    case regular = 64
}

/// The owner-approved 2026-10-12 larder serpentine (SVG viewBox 0 0 64 64).
struct WiltedLoadingMotifGeometry {
    let size: WiltedLoadingMotifSize
    static let cycle: TimeInterval = 1.6
    static let dashFraction: CGFloat = 0.18
    static let shelfOpacity = 0.58
    static let traceOpacity = 0.98
    var unit: CGFloat { size.rawValue / 64 }
    var shelfStrokeWidth: CGFloat { (size == .compact ? 3 : 2.3) * unit }
    var traceStrokeWidth: CGFloat { 2.8 * unit }

    /// Construct the two native geometries directly; never shrink a rendered 64pt mark.
    var frame: Path {
        Path(roundedRect: CGRect(x: 14 * unit, y: 8 * unit, width: 36 * unit, height: 48 * unit),
             cornerSize: CGSize(width: 3 * unit, height: 3 * unit))
    }

    var shelves: Path {
        var path = Path()
        let lines: [[CGFloat]] = [
            [14,27,50,27], [14,41,50,41], [32,8,32,56], [27,17,27,22], [37,17,37,22],
            [21,33,28,33], [36,33,44,33], [21,47,28,47], [36,47,44,47]
        ]
        for line in lines {
            path.move(to: point(line[0], line[1]))
            path.addLine(to: point(line[2], line[3]))
        }
        return path
    }

    var outline: Path {
        var path = Path()
        path.move(to: point(17, 8))
        path.addLine(to: point(47, 8))
        path.addQuadCurve(to: point(50, 11), control: point(50, 8))
        path.addLine(to: point(50, 24))
        path.addQuadCurve(to: point(47, 27), control: point(50, 27))
        path.addLine(to: point(17, 27))
        path.addQuadCurve(to: point(14, 30), control: point(14, 27))
        path.addLine(to: point(14, 38))
        path.addQuadCurve(to: point(17, 41), control: point(14, 41))
        path.addLine(to: point(47, 41))
        path.addQuadCurve(to: point(50, 44), control: point(50, 41))
        path.addLine(to: point(50, 53))
        path.addQuadCurve(to: point(47, 56), control: point(50, 56))
        path.addLine(to: point(17, 56))
        path.addQuadCurve(to: point(14, 53), control: point(14, 56))
        path.addLine(to: point(14, 11))
        path.addQuadCurve(to: point(17, 8), control: point(14, 8))
        path.closeSubpath()
        return path
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }

    // Eight identical quadratic corners, plus the straight SVG segments. A fixed
    // quadrature normalizes SVG pathLength=100 into native StrokeStyle units.
    private static let viewBoxLength: CGFloat = {
        var corner: CGFloat = 0
        var previous = CGPoint.zero
        for sample in 1...256 {
            let t = CGFloat(sample) / 256
            let next = CGPoint(x: 6 * t - 3 * t * t, y: 3 * t * t)
            corner += hypot(next.x - previous.x, next.y - previous.y)
            previous = next
        }
        return 30 * 4 + 13 + 8 + 9 + 42 + corner * 8
    }()
    var length: CGFloat { Self.viewBoxLength * unit }

    static func phase(at elapsed: TimeInterval) -> CGFloat {
        guard elapsed.isFinite else { return 0 }
        return CGFloat(max(0, elapsed).truncatingRemainder(dividingBy: cycle) / cycle)
    }
    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 127/255, green: 212/255, blue: 140/255)
            : Color(red: 77/255, green: 107/255, blue: 34/255)
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 13/255, green: 17/255, blue: 15/255)
            : Color(red: 244/255, green: 247/255, blue: 243/255)
    }
}

/// Deterministic native drawing shared by the live timeline and render tests.
struct WiltedLoadingMotifMark: View {
    var size: WiltedLoadingMotifSize = .regular
    var elapsed: TimeInterval
    var reduceMotion: Bool
    var scheme: ColorScheme

    var body: some View {
        let geometry = WiltedLoadingMotifGeometry(size: size)
        let ink = WiltedLoadingMotifGeometry.ink(scheme)
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                geometry.frame.stroke(ink, style: StrokeStyle(
                    lineWidth: geometry.shelfStrokeWidth, lineCap: .round, lineJoin: .round))
                geometry.shelves.stroke(ink, style: StrokeStyle(
                    lineWidth: geometry.shelfStrokeWidth, lineCap: .round, lineJoin: .round))
            }
            .compositingGroup()
            .opacity(WiltedLoadingMotifGeometry.shelfOpacity)
            geometry.outline.stroke(ink.opacity(WiltedLoadingMotifGeometry.traceOpacity), style: StrokeStyle(
                lineWidth: geometry.traceStrokeWidth, lineCap: .round, lineJoin: .round,
                dash: [geometry.length * WiltedLoadingMotifGeometry.dashFraction,
                       geometry.length * (1 - WiltedLoadingMotifGeometry.dashFraction)],
                dashPhase: -WiltedLoadingMotifGeometry.phase(at: reduceMotion ? 0 : elapsed) * geometry.length))
        }
        .frame(width: size.rawValue, height: size.rawValue)
        .accessibilityHidden(true)
    }
}

/// Decorative indeterminate art; adjacent status text supplies the accessible wait.
struct WiltedLoadingMotif: View {
    var size: WiltedLoadingMotifSize = .regular
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            WiltedLoadingMotifMark(size: size, elapsed: context.date.timeIntervalSince(started),
                                   reduceMotion: reduceMotion, scheme: scheme)
        }
        .accessibilityHidden(true)
    }
}
