import Foundation

/// A bounded, monotonic duration trace for the store reads a playback
/// handoff waits on: the ready-revision fetch, the transcript fetch and the
/// transcript decode.
///
/// It records whole durations only: no item or revision identifiers, titles,
/// URLs or file paths ever enter it, and nothing is logged. It is off by
/// default, so a disabled call pays one boolean read and no clock read; the
/// Task 1.1 measurement seams are `isEnabled` and `reset()`.
public enum LocalLibraryStoreStageTrace {
    public enum Stage: String, Sendable, CaseIterable {
        case revisionFetch
        case transcriptActorAdmission
        case transcriptFetch
        case transcriptDecode
    }

    public struct Event: Equatable, Sendable {
        public let stage: Stage
        public let nanos: UInt64
    }

    /// One measured stage, in whole microseconds, with its sample count.
    public struct Summary: Equatable, Sendable {
        public let stage: Stage
        public let sampleCount: Int
        public let medianMicros: Int
        public let p95Micros: Int
        public let maxMicros: Int
    }

    public static let capacity = 4096

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var events: [Event] = []
    }

    private static let storage = Storage()

    public static var isEnabled: Bool {
        get { storage.lock.withLock { storage.enabled } }
        set { storage.lock.withLock { storage.enabled = newValue } }
    }

    public static func reset() {
        storage.lock.withLock { storage.events.removeAll(keepingCapacity: true) }
    }

    /// The monotonic start of a traced segment, or nil while disabled.
    @inline(__always)
    public static func start() -> ContinuousClock.Instant? {
        storage.lock.withLock { storage.enabled } ? ContinuousClock.now : nil
    }

    public static func record(_ stage: Stage, since start: ContinuousClock.Instant) {
        let elapsed = start.duration(to: .now)
        let components = elapsed.components
        let nanos = UInt64(max(0, components.seconds)) * 1_000_000_000
            + UInt64(max(0, components.attoseconds)) / 1_000_000_000
        storage.lock.withLock {
            guard storage.enabled else { return }
            if storage.events.count >= capacity {
                storage.events.removeFirst(storage.events.count - capacity + 1)
            }
            storage.events.append(Event(stage: stage, nanos: nanos))
        }
    }

    public static func events() -> [Event] {
        storage.lock.withLock { storage.events }
    }

    public static func summaries() -> [Summary] {
        let events = events()
        return Stage.allCases.compactMap { stage in
            let samples = events.filter { $0.stage == stage }.map(\.nanos).sorted()
            guard !samples.isEmpty else { return nil }
            return Summary(
                stage: stage, sampleCount: samples.count,
                medianMicros: micros(percentile(samples, 0.5)),
                p95Micros: micros(percentile(samples, 0.95)),
                maxMicros: micros(samples[samples.count - 1])
            )
        }
    }

    /// The trace as bounded text; durations and counts only.
    public static func report() -> String {
        var lines = ["store-stage-trace events=\(events().count) capacity=\(capacity)"]
        for summary in summaries() {
            lines.append(
                "stage \(summary.stage.rawValue) n=\(summary.sampleCount) medianUs=\(summary.medianMicros) "
                    + "p95Us=\(summary.p95Micros) maxUs=\(summary.maxMicros)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func micros(_ nanos: UInt64) -> Int { Int(nanos / 1_000) }

    private static func percentile(_ sorted: [UInt64], _ fraction: Double) -> UInt64 {
        let rank = max(1, Int((Double(sorted.count) * fraction).rounded(.up)))
        return sorted[min(sorted.count, rank) - 1]
    }
}
