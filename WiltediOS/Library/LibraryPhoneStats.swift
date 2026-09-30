import Combine
import Foundation

/// What this phone has done, ever: time listened, audio downloaded from the Mac, and time saved by
/// listening faster than 1x. Counted on the device and never synced, so it is this phone's alone.
struct LibraryPhoneStats: Codable, Equatable, Sendable {
    var listenedSeconds: Double = 0
    var downloadedBytes: Int64 = 0
    var savedSeconds: Double = 0
}

/// Accumulates `LibraryPhoneStats` in `UserDefaults`. Listening arrives a tick at a time, so it is
/// written out every `saveInterval` seconds of new listening and whenever `flush` is called (the
/// player pausing, the app leaving the foreground).
@MainActor
final class LibraryPhoneStatsStore: ObservableObject {
    nonisolated static let key = "wilted.library.phoneStats"
    nonisolated static let saveInterval: TimeInterval = 10

    @Published private(set) var stats: LibraryPhoneStats
    private let defaults: UserDefaults
    private var unsavedSeconds: TimeInterval = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stats = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(LibraryPhoneStats.self, from: $0) }
            ?? LibraryPhoneStats()
    }

    /// `wall` seconds of real time played at `rate`: the audio advanced `wall * rate`, so the time
    /// saved against 1x is `wall * (rate - 1)`. Slower than 1x saves nothing.
    func recordListening(wall: TimeInterval, rate: Double) {
        guard wall.isFinite, wall > 0, rate.isFinite, rate > 0 else { return }
        stats.listenedSeconds += wall
        stats.savedSeconds += wall * max(0, rate - 1)
        unsavedSeconds += wall
        if unsavedSeconds >= Self.saveInterval { flush() }
    }

    /// A verified episode that came from the Mac.
    func recordDownload(bytes: Int64) {
        guard bytes > 0 else { return }
        stats.downloadedBytes += bytes
        flush()
    }

    func flush() {
        unsavedSeconds = 0
        if let data = try? JSONEncoder().encode(stats) { defaults.set(data, forKey: Self.key) }
    }
}
