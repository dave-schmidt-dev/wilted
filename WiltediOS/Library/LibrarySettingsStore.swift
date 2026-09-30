import Combine
import Foundation

/// What the player needs from Settings: the speed a new item starts at and both skip lengths.
struct LibraryPlaybackPreferences: Equatable, Sendable {
    var defaultSpeed: Double
    var skipBackSeconds: Int
    var skipForwardSeconds: Int
}

/// The phone's own preferences, backed by `UserDefaults` and clamped on every read and write so a
/// stale or hand-edited value can never reach the player. These are per-device choices; nothing
/// here syncs, and none of it is library state (W-INV-005 is about the Mac's records).
@MainActor
final class LibrarySettingsStore: ObservableObject {
    /// Speeds the setting offers; the player applies what its engine can do (`LibraryPlayer.rates`).
    nonisolated static let speedRange: ClosedRange<Double> = 0.75...2.0
    nonisolated static let speedStep = 0.05
    nonisolated static let defaultSpeed = 1.25
    /// Whole-second lengths that have a matching `gobackward.N` / `goforward.N` SF Symbol.
    nonisolated static let skipOptions = [5, 10, 15, 30, 45, 60, 75, 90]
    /// The player's own defaults, so an untouched Settings changes nothing.
    nonisolated static let defaultSkipBack = 15
    nonisolated static let defaultSkipForward = 30

    nonisolated static let textScaleKey = "wilted.appearance.textScale"
    nonisolated static let speedKey = "wilted.library.defaultSpeed"
    nonisolated static let skipBackKey = "wilted.library.skipBackSeconds"
    nonisolated static let skipForwardKey = "wilted.library.skipForwardSeconds"

    @Published var textScale: WiltedTheme.TextScale {
        didSet { if textScale != oldValue { defaults.set(textScale.rawValue, forKey: Self.textScaleKey) } }
    }
    @Published var defaultSpeed: Double {
        didSet {
            let clamped = Self.clampSpeed(defaultSpeed)
            if clamped != defaultSpeed { defaultSpeed = clamped; return }
            if clamped != oldValue { defaults.set(clamped, forKey: Self.speedKey) }
        }
    }
    @Published var skipBackSeconds: Int {
        didSet {
            let snapped = Self.snapSkip(skipBackSeconds, fallback: Self.defaultSkipBack)
            if snapped != skipBackSeconds { skipBackSeconds = snapped; return }
            if snapped != oldValue { defaults.set(snapped, forKey: Self.skipBackKey) }
        }
    }
    @Published var skipForwardSeconds: Int {
        didSet {
            let snapped = Self.snapSkip(skipForwardSeconds, fallback: Self.defaultSkipForward)
            if snapped != skipForwardSeconds { skipForwardSeconds = snapped; return }
            if snapped != oldValue { defaults.set(snapped, forKey: Self.skipForwardKey) }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        textScale = Self.loadTextScale(from: defaults)
        defaultSpeed = defaults.object(forKey: Self.speedKey) is NSNumber
            ? Self.clampSpeed(defaults.double(forKey: Self.speedKey)) : Self.defaultSpeed
        skipBackSeconds = Self.snapSkip(defaults.object(forKey: Self.skipBackKey) as? Int, fallback: Self.defaultSkipBack)
        skipForwardSeconds = Self.snapSkip(defaults.object(forKey: Self.skipForwardKey) as? Int, fallback: Self.defaultSkipForward)
    }

    var playback: LibraryPlaybackPreferences {
        LibraryPlaybackPreferences(
            defaultSpeed: defaultSpeed, skipBackSeconds: skipBackSeconds, skipForwardSeconds: skipForwardSeconds)
    }

    /// Nearest 0.05 step inside `speedRange`; a non-finite value falls back to the default.
    nonisolated static func clampSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSpeed }
        let stepped = (value / speedStep).rounded() * speedStep
        let clamped = min(max(stepped, speedRange.lowerBound), speedRange.upperBound)
        return (clamped * 100).rounded() / 100
    }

    /// `value` when it is an offered length, otherwise the nearest offered one; `fallback` when unset.
    nonisolated static func snapSkip(_ value: Int?, fallback: Int) -> Int {
        guard let value else { return fallback }
        return skipOptions.min { abs($0 - value) < abs($1 - value) } ?? fallback
    }

    /// The Mac defaults to a larger scale because it has no Dynamic Type; the phone keeps the
    /// system's own sizing until asked, and an unreadable stored value falls back to that.
    nonisolated static func loadTextScale(from defaults: UserDefaults) -> WiltedTheme.TextScale {
        defaults.string(forKey: textScaleKey).flatMap(WiltedTheme.TextScale.init(rawValue:)) ?? .standard
    }
}
