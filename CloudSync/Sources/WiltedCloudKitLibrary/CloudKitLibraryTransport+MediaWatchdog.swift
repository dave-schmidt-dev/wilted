import Foundation
import WiltedLibrary

/// Elapsed time since a transfer last reported progress.
private final class MediaProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = DispatchTime.now().uptimeNanoseconds
    func touch() { lock.withLock { last = DispatchTime.now().uptimeNanoseconds } }
    var secondsSinceProgress: Double {
        Double(DispatchTime.now().uptimeNanoseconds - lock.withLock { last }) / 1_000_000_000
    }
}

extension CloudKitLibraryTransport {
    /// Runs `body` and abandons it when it reports no progress for `mediaWatchdogInterval`.
    func withMediaWatchdog<T: Sendable>(
        _ body: @escaping @Sendable (@escaping @Sendable () -> Void) async throws -> T
    ) async throws -> T {
        let clock = MediaProgressClock()
        let interval = mediaWatchdogInterval
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body { clock.touch() } }
            group.addTask {
                let tick = UInt64(min(max(interval / 10, 0.005), 5) * 1_000_000_000)
                while true {
                    try await Task.sleep(nanoseconds: tick)
                    if clock.secondsSinceProgress > interval {
                        throw LibraryTransportError.transport("media transfer stalled: no progress for \(Int(interval)) s")
                    }
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw LibraryTransportError.transport("media transfer ended without a result")
            }
            return value
        }
    }
}
