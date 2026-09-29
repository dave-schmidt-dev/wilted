import CloudKit
import Foundation
import SpikeCore

/// Playback-position handoff over one small non-asset record in `SpikeZone`, with a
/// `CKDatabaseSubscription` so a second device can be woken by a silent push.
///
/// The probe cannot receive pushes itself: the host app's remote-notification handler calls
/// `handlePush()`, which fetches the record and yields the observation. `fetchLatest()` is the
/// same path for foreground and after-launch checks.
public final class CloudKitHandoffProbe: HandoffProbe, @unchecked Sendable {
    public let name = "cloudkit-record-subscription"
    private let context: SpikeCloudKitContext
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<HandoffObservation>.Continuation] = [:]
    private var lastSequence = -1
    private var offsetSamples: [ClockOffsetSample] = []

    public init(context: SpikeCloudKitContext = SpikeCloudKitContext(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.context = context
        self.now = now
    }

    /// Server-modification-versus-publisher-clock samples gathered by `publish`.
    public var clockOffsetSamples: [ClockOffsetSample] { lock.withLock { offsetSamples } }

    /// Saves a silent-push database subscription (`shouldSendContentAvailable`, no alert).
    public func installSubscription() async throws {
        try await context.ensureZone()
        let subscription = CKDatabaseSubscription(subscriptionID: SpikeNames.handoffSubscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await context.database.save(subscription)
    }

    public func publish(position: Double, sequence: Int, publishedAt: Date) async throws {
        try await context.ensureZone()
        let record = CKRecord(
            recordType: SpikeNames.handoffRecordType,
            recordID: context.recordID(named: SpikeNames.handoffRecordName)
        )
        record["position"] = position as NSNumber
        record["sequence"] = sequence as NSNumber
        record["publishedAt"] = publishedAt as NSDate
        try await CloudKitOperations.save([record], in: context.database, progress: nil)
        // The operation's save block does not hand back the server copy, so read the modification date.
        if let saved = try await CloudKitOperations.fetch(
            [record.recordID], desiredKeys: ["sequence"], in: context.database, progress: nil
        ).first, let modified = saved.modificationDate {
            lock.withLock {
                offsetSamples.append(ClockOffsetSample(publisherTimestamp: publishedAt, serverModificationDate: modified))
            }
        }
    }

    public func observe() -> AsyncStream<HandoffObservation> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.continuations[id] = nil }
            }
        }
    }

    /// Call from the host's remote-notification handler.
    public func handlePush() async {
        await fetchLatest()
    }

    /// Fetches the handoff record and yields it when its sequence is newer than the last one seen.
    public func fetchLatest() async {
        guard let records = try? await CloudKitOperations.fetch(
            [context.recordID(named: SpikeNames.handoffRecordName)], desiredKeys: nil, in: context.database, progress: nil
        ), let record = records.first else { return }
        let receivedAt = now()
        guard let position = (record["position"] as? NSNumber)?.doubleValue,
              let sequence = (record["sequence"] as? NSNumber)?.intValue,
              let publishedAt = record["publishedAt"] as? Date else { return }
        let targets: [AsyncStream<HandoffObservation>.Continuation] = lock.withLock {
            guard sequence > lastSequence else { return [] }
            lastSequence = sequence
            return Array(continuations.values)
        }
        let observation = HandoffObservation(
            value: HandoffValue(position: position, sequence: sequence, publishedAt: publishedAt),
            receivedAt: receivedAt
        )
        for continuation in targets { continuation.yield(observation) }
    }

    /// Ends every active observer stream.
    public func finish() {
        let targets = lock.withLock { () -> [AsyncStream<HandoffObservation>.Continuation] in
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        for continuation in targets { continuation.finish() }
    }
}
