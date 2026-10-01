import Foundation

/// The one list of playback speeds, shared by the Mac, the iPhone (settings, Now Playing, CarPlay,
/// lock screen) and Siri. 0.5 through 2.0 in 0.25 steps: the span both players accept (`AVAudioPlayer`
/// takes 0.5 through 2), so no app offers a speed another refuses.
public enum PlaybackSpeeds {
    public static let step = 0.25
    public static let range: ClosedRange<Double> = 0.5...2.0
    /// Every offered speed, slowest first: 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2.
    public static let all: [Double] = stride(from: range.lowerBound, through: range.upperBound, by: step).map { $0 }

    /// The nearest offered speed; a non-finite value becomes `fallback` first.
    public static func nearest(_ value: Double, fallback: Double = 1) -> Double {
        let base = value.isFinite ? value : fallback
        let stepped = (base / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// Whether `rate` is exactly one of the offered speeds.
    public static func contains(_ rate: Double) -> Bool { all.contains(rate) }
}
