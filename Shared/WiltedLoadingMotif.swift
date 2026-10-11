import SwiftUI

/// The accepted 100-unit W, shared by both native startup surfaces.
enum WiltedLoadingMotifGeometry {
    static let cycle: TimeInterval = 1.45
    static let strokeWidth: CGFloat = 10
    static let dashFraction: CGFloat = 0.24
    static let start = CGPoint(x: 13, y: 26)
    // Each tuple is (first control, second control, end), in SVG viewBox units.
    static let curves: [(CGPoint, CGPoint, CGPoint)] = [
        (.init(x: 13, y: 19), .init(x: 21, y: 19), .init(x: 21, y: 27)),
        (.init(x: 23, y: 40), .init(x: 28, y: 63), .init(x: 34, y: 63)),
        (.init(x: 39, y: 63), .init(x: 44, y: 34), .init(x: 50, y: 34)),
        (.init(x: 56, y: 34), .init(x: 61, y: 63), .init(x: 66, y: 63)),
        (.init(x: 72, y: 63), .init(x: 77, y: 40), .init(x: 79, y: 27)),
        (.init(x: 79, y: 19), .init(x: 87, y: 19), .init(x: 87, y: 26))
    ]
    static var path: Path {
        var path = Path(); path.move(to: start)
        for (first, second, end) in curves { path.addCurve(to: end, control1: first, control2: second) }
        return path
    }
    /// SVG pathLength=100 normalizes dash units. Approximate the cubic arc lengths
    /// once, so the native stroke uses the same 24/76 proportions at any size.
    static let length: CGFloat = {
        var length: CGFloat = 0, start = Self.start
        for (first, second, end) in curves {
            var previous = start
            for sample in 1...256 {
                let t = CGFloat(sample) / 256, u = 1 - t
                let point = CGPoint(x: u*u*u*start.x + 3*u*u*t*first.x + 3*u*t*t*second.x + t*t*t*end.x,
                                    y: u*u*u*start.y + 3*u*u*t*first.y + 3*u*t*t*second.y + t*t*t*end.y)
                length += hypot(point.x - previous.x, point.y - previous.y); previous = point
            }
            start = end
        }
        return length
    }()
    static func phase(at elapsed: TimeInterval) -> CGFloat {
        CGFloat(max(0, elapsed).truncatingRemainder(dividingBy: cycle) / cycle)
    }
    static func fraction(_ progress: Double) -> CGFloat {
        CGFloat(progress.isFinite ? min(1, max(0, progress)) : 0)
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

/// Deterministic drawing used by the live timeline and native render tests.
struct WiltedLoadingMotifMark: View {
    var progress: Double?
    var elapsed: TimeInterval
    var reduceMotion: Bool
    var scheme: ColorScheme

    var body: some View {
        let geometry = WiltedLoadingMotifGeometry.self
        ZStack {
            if progress == nil && !reduceMotion {
                geometry.path.stroke(geometry.ink(scheme).opacity(0.22),
                                     style: StrokeStyle(lineWidth: geometry.strokeWidth, lineCap: .round, lineJoin: .round))
            }
            if reduceMotion {
                geometry.path.stroke(geometry.ink(scheme),
                                     style: StrokeStyle(lineWidth: geometry.strokeWidth, lineCap: .round, lineJoin: .round))
            } else if let progress {
                geometry.path.trimmedPath(from: 0, to: geometry.fraction(progress))
                    .stroke(geometry.ink(scheme), style: StrokeStyle(lineWidth: geometry.strokeWidth, lineCap: .round, lineJoin: .round))
            } else {
                geometry.path.stroke(geometry.ink(scheme), style: StrokeStyle(
                    lineWidth: geometry.strokeWidth, lineCap: .round, lineJoin: .round,
                    dash: [geometry.length * geometry.dashFraction, geometry.length * (1 - geometry.dashFraction)],
                    dashPhase: -geometry.phase(at: elapsed) * geometry.length))
            }
        }
        .frame(width: 100, height: 100)
        .accessibilityHidden(true)
    }
}

struct WiltedLoadingMotif: View {
    /// Actual fraction of a counted operation; nil means indeterminate waiting.
    var progress: Double? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || progress != nil)) { context in
            WiltedLoadingMotifMark(progress: progress, elapsed: context.date.timeIntervalSince(started),
                                   reduceMotion: reduceMotion, scheme: scheme)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening your larder")
        .accessibilityValue(progress.map { "\(Int(WiltedLoadingMotifGeometry.fraction($0) * 100))%" } ?? "Waiting")
        .accessibilityIdentifier("wilted-loading-motif")
    }
}
