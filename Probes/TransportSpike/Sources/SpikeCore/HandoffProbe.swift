import Foundation

/// A playback checkpoint published by one device for another to observe.
public struct HandoffValue: Codable, Sendable, Equatable {
    public let position: Double
    public let sequence: Int
    /// Publisher's local clock when the value was sent.
    public let publishedAt: Date

    public init(position: Double, sequence: Int, publishedAt: Date) {
        self.position = position
        self.sequence = sequence
        self.publishedAt = publishedAt
    }
}

/// A value as seen by the observer, stamped with the observer's local receive time.
public struct HandoffObservation: Codable, Sendable, Equatable {
    public let value: HandoffValue
    public let receivedAt: Date

    public init(value: HandoffValue, receivedAt: Date) {
        self.value = value
        self.receivedAt = receivedAt
    }

    /// Raw publish-to-receive latency in seconds. Includes any clock skew between the two devices.
    public var rawLatencySeconds: Double {
        receivedAt.timeIntervalSince(value.publishedAt)
    }
}

/// A transport for low-latency position handoff (CloudKit record, key-value store, push, ...).
public protocol HandoffProbe: Sendable {
    var name: String { get }
    /// Publishes a checkpoint stamped with the publisher's clock.
    func publish(position: Double, sequence: Int, publishedAt: Date) async throws
    /// A stream of received values, each stamped with the local receive time. Ends when the probe stops.
    func observe() -> AsyncStream<HandoffObservation>
}

/// In-memory loopback probe: every published value is delivered to every active observer.
public final class InMemoryHandoffProbe: HandoffProbe, @unchecked Sendable {
    public let name: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<HandoffObservation>.Continuation] = [:]

    public init(name: String = "in-memory", now: @escaping @Sendable () -> Date = { Date() }) {
        self.name = name
        self.now = now
    }

    public func publish(position: Double, sequence: Int, publishedAt: Date) async throws {
        let value = HandoffValue(position: position, sequence: sequence, publishedAt: publishedAt)
        let observation = HandoffObservation(value: value, receivedAt: now())
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(observation) }
    }

    public func observe() -> AsyncStream<HandoffObservation> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    /// Ends every active observer stream.
    public func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }
}
