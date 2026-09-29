import Foundation

/// Which direction a transfer measurement covers.
public enum TransferDirection: String, Codable, Sendable {
    case upload
    case download
}

/// One timed transfer attempt.
public struct Measurement: Codable, Sendable, Equatable {
    public let strategy: String
    public let direction: TransferDirection
    public let bytes: Int64
    public let wallSeconds: Double
    /// How many times the progress callback fired during the transfer.
    public let progressCallbackCount: Int
    /// Non-nil when the transfer failed; the other fields describe what happened before the failure.
    public let errorText: String?

    public init(
        strategy: String,
        direction: TransferDirection,
        bytes: Int64,
        wallSeconds: Double,
        progressCallbackCount: Int,
        errorText: String? = nil
    ) {
        self.strategy = strategy
        self.direction = direction
        self.bytes = bytes
        self.wallSeconds = wallSeconds
        self.progressCallbackCount = progressCallbackCount
        self.errorText = errorText
    }

    public var succeeded: Bool { errorText == nil }

    /// Throughput in bytes per second, or nil when the transfer failed or took no measurable time.
    public var bytesPerSecond: Double? {
        guard succeeded, wallSeconds > 0 else { return nil }
        return Double(bytes) / wallSeconds
    }
}

/// Thread-safe progress-callback counter shared between a strategy and its timing wrapper.
public final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var latestBytes: Int64 = 0

    public init() {}

    /// Records one progress callback carrying the cumulative byte count.
    public func record(bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        latestBytes = bytes
    }

    public var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    public var bytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return latestBytes
    }
}

/// Runs `body`, timing it with a monotonic clock, and converts a thrown error into `errorText`.
public func measure(
    strategy: String,
    direction: TransferDirection,
    bytes: Int64,
    counter: ProgressCounter,
    _ body: () async throws -> Void
) async -> Measurement {
    let clock = ContinuousClock()
    let start = clock.now
    var errorText: String?
    do {
        try await body()
    } catch {
        errorText = String(describing: error)
    }
    let elapsed = start.duration(to: clock.now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return Measurement(
        strategy: strategy,
        direction: direction,
        bytes: bytes,
        wallSeconds: seconds,
        progressCallbackCount: counter.callCount,
        errorText: errorText
    )
}
