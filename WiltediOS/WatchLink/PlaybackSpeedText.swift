import Foundation

/// Shared playback speed labels used by the phone and Watch.
enum PlaybackSpeedText {
    static func rate(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))x" : String(format: "%gx", value)
    }
}
