import Foundation
import WiltedDomain
import WiltedLibrary

/// Outcome of one `sync()` pass, for status surfaces and tests.
struct LibraryPublishReport: Sendable, Equatable {
    var isEnabled = true
    var pushed = 0
    var acknowledged = 0
    var conflicts = 0
    var retryable = 0
    var terminal = 0
    var intentsDelivered = 0
    var intentFailures = 0
    var statsPublished = false
    var statsFailures = 0
    var publication: LibraryPublication?
    /// This pass sent and durably completed an author receipt, rather than hydrating history.
    var publicationCompleted = false

    static let disabled = Self(isEnabled: false)
}

/// Publishes the Mac's library state through a `LibraryTransport` and, unless the Mac's sync round
/// already reads intents (`relaysIntents` false), relays inbound intents.
///
/// A pass touches the server only when something changed: state when the diff is not empty,
/// statistics when a metric moved. An edit (a Keep, a reorder) runs a state-only pass at once; the
/// statistics ride the next sync round, so a playing Mac's listening time never wakes the publisher.
///
/// It never writes playback records: `HandoffCoordinator` (driven by `WiltedMacHandoffController`)
/// is the only writer of the Mac's NowPlaying and Progress, so an epoch is never published twice.
///
/// `WiltedMacLibraryRuntimeSelection` decides whether a publisher exists: by default in a live
/// build, on `WILTED_LIBRARY_SYNC=1` anywhere. The publisher is the library's single writer, so it seeds its per-record base versions from the server on the
/// first pass, then sends only what `LibraryStateDiffer` reports as changed.
actor WiltedMacLibraryPublisher {
    static let environmentKey = WiltedMacLibraryRuntimeSelection.environmentKey

    /// True only when the environment forces the publisher on (`WILTED_LIBRARY_SYNC` exactly `1`).
    /// Whether it runs without the flag is the runtime selection's call, not this one's.
    static func isEnabled(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        WiltedMacLibraryRuntimeSelection.override(in: environment) == .on
    }

    nonisolated let isEnabled: Bool
    private let source: any LibraryStateSource
    private let transport: any LibraryTransport
    private let sink: any LibraryIntentSink
    private var published: LibrarySnapshot?
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var nextLocalSeq: UInt64 = 1
    private var deliveredIntentIDs = Set<String>()
    private let statsProvider: (@Sendable () async -> LifetimeStatistics?)?
    private let relaysIntents: Bool
    private let clock: @Sendable () -> Date
    private var publishedStats: LibraryStats?
    private let publicationStore: WiltedMacLibraryPublicationStore?
    private let approvedOwner: (@Sendable () async -> String?)?
    private let deviceID: String
    private let operationID: @Sendable () -> String
    private var epoch: UInt64 = 0
    private var inFlight = false
    private var envelope: WiltedMacLibraryPublicationEnvelope?

    private struct Context: Sendable {
        var epoch: UInt64
        var owner: String?
        var generation: UInt64
    }

    init(
        source: any LibraryStateSource,
        transport: any LibraryTransport,
        sink: any LibraryIntentSink,
        isEnabled: Bool = true,
        statsProvider: (@Sendable () async -> LifetimeStatistics?)? = nil,
        relaysIntents: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() },
        publicationStore: WiltedMacLibraryPublicationStore? = nil,
        deviceID: String = "mac",
        approvedOwner: (@Sendable () async -> String?)? = nil,
        operationID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.relaysIntents = relaysIntents
        self.source = source
        self.transport = transport
        self.sink = sink
        self.isEnabled = isEnabled
        self.statsProvider = statsProvider
        self.clock = clock
        self.publicationStore = publicationStore
        self.deviceID = deviceID
        self.approvedOwner = approvedOwner
        self.operationID = operationID
    }

    /// One publish-then-relay pass. Returns `.disabled` without touching the source or
    /// transport when the feature flag is off.
    func sync(includesStats: Bool = true) async throws -> LibraryPublishReport {
        guard isEnabled else { return .disabled }
        guard !inFlight else { throw LibraryTransportError.superseded }
        inFlight = true
        defer { inFlight = false }
        let context = try await captureContext()
        var report = LibraryPublishReport()
        if let publicationStore, let owner = context.owner, envelope == nil {
            let loaded = try await publicationStore.load(owner: owner)
            try await verify(context)
            envelope = loaded
        }
        let state = try await source.currentState()
        try await verify(context)
        try await publishState(state, context: context, into: &report)
        if includesStats { try await publishStats(context: context, into: &report) }
        if relaysIntents { try await relayIntents(context: context, into: &report) }
        try await verify(context)
        report.publication = envelope?.fulfilled
        return report
    }

    /// Loads only the approved owner's durable evidence; it never starts a cloud operation.
    func fulfilledPublication() async throws -> LibraryPublication? {
        guard let publicationStore else { return nil }
        let context = try await captureContext()
        guard let owner = context.owner else { return nil }
        let loaded = try await publicationStore.load(owner: owner)
        try await verify(context)
        return loaded.fulfilled
    }

    private func captureContext() async throws -> Context {
        let start = epoch
        let owner = await approvedOwner?()
        guard publicationStore == nil || owner != nil else { throw WiltedMacLibraryAccountError.notApproved }
        let generation = await transport.operationGeneration()
        guard epoch == start else { throw LibraryTransportError.superseded }
        return Context(epoch: start, owner: owner, generation: generation)
    }

    private func verify(_ context: Context) async throws {
        guard epoch == context.epoch else { throw LibraryTransportError.superseded }
        let owner = await approvedOwner?()
        guard epoch == context.epoch, owner == context.owner else { throw LibraryTransportError.superseded }
        let generation = await transport.operationGeneration()
        guard epoch == context.epoch, generation == context.generation else { throw LibraryTransportError.superseded }
    }

    /// Forgets what was published, so the next pass seeds its baseline from the account it now
    /// serves (Task 5.0). A pass suspended across the reset is superseded by the account gate.
    func resetForAccount() {
        epoch &+= 1
        envelope = nil
        published = nil
        versions = [:]
        publishedStats = nil
        deliveredIntentIDs = []
    }

    // MARK: - State

    private func publishState(_ state: LibraryStateSnapshot, context: Context,
                              into report: inout LibraryPublishReport) async throws {
        let current = try state.replicatedContent()
        let baseline = try await seededBaseline(context: context)
        let changes = envelope?.pending?.remaining ?? LibraryStateDiffer.diff(from: baseline, to: current)
        if publicationStore != nil, envelope?.pending == nil, !changes.isEmpty {
            var next = envelope!
            next.pending = WiltedMacLibraryPublicationPending(
                id: operationID(), writerDeviceID: deviceID, captured: changes, remaining: changes)
            try await persist(next, context: context)
        }
        if envelope?.pending?.contentAcknowledged == true {
            report.publicationCompleted = try await completePublication(context: context)
            return
        }
        var pending: [PendingLibraryChange] = []
        for change in changes {
            pending.append(PendingLibraryChange(localSeq: nextLocalSeq, change: change,
                                                baseVersion: versions[change.key] ?? 0))
            nextLocalSeq += 1
        }
        report.pushed = pending.count
        guard !pending.isEmpty else { return }
        try await verify(context)
        let result = try await transport.push(changes: pending)
        try await verify(context)
        let changesByKey = Dictionary(pending.map { ($0.key, $0.change) }, uniquingKeysWith: { _, last in last })
        let failedKeys = Set(result.failures.map(\.key))
        let accepted = result.acknowledged.filter { changesByKey[$0.key] != nil && !failedKeys.contains($0.key) }
        var next = baseline
        for ack in accepted {
            versions[ack.key] = ack.version
            if let change = changesByKey[ack.key] { next = next.applying(change) }
        }
        published = next
        report.acknowledged = accepted.count
        for failure in result.failures {
            switch failure.disposition {
            case .conflict:
                report.conflicts += 1
                if let server = failure.server { versions[failure.key] = server.version }
            case .retryable: report.retryable += 1
            case .terminal: report.terminal += 1
            }
        }
        if var durable = envelope, var obligation = durable.pending {
            let acknowledged = Set(accepted.map(\.key))
            obligation.remaining.removeAll { acknowledged.contains($0.key) }
            if obligation.remaining.isEmpty, !result.failures.isEmpty {
                obligation.remaining = changes // An unfulfilled result cannot discard its retry obligation.
            }
            obligation.contentAcknowledged = obligation.remaining.isEmpty && result.failures.isEmpty
            obligation.sentToken = result.token
            durable.pending = obligation
            try await persist(durable, context: context)
            if obligation.contentAcknowledged {
                report.publicationCompleted = try await completePublication(context: context)
                return
            }
        }
        try await transport.commitSentState(result.token)
        try await verify(context)
    }

    /// Durable retry obligation survives baseline adoption, token failure and receipt crash windows.
    private func completePublication(context: Context) async throws -> Bool {
        guard var next = envelope, var pending = next.pending, pending.contentAcknowledged else { return false }
        if pending.publishedAt == nil {
            try await verify(context)
            try await transport.commitSentState(pending.sentToken)
            try await verify(context)
            pending.publishedAt = clock()
            next.pending = pending
            envelope = next
        }
        try await persist(next, context: context)
        guard let receipt = try pending.receipt() else { return false }
        try await verify(context)
        try await transport.publishPublication(receipt)
        try await verify(context)
        next.pending = nil
        next.fulfilled = receipt
        try await persist(next, context: context)
        return true
    }

    private func persist(_ next: WiltedMacLibraryPublicationEnvelope, context: Context) async throws {
        guard let publicationStore else { return }
        try await verify(context)
        try await publicationStore.save(next)
        try await verify(context)
        envelope = next
    }

    /// A restarted publisher seeds from the server without treating that fetch as publication.
    private func seededBaseline(context: Context) async throws -> LibrarySnapshot {
        if let published { return published }
        let batch = try await transport.fetchChanges(since: nil)
        try await verify(context)
        var snapshot = LibrarySnapshot()
        var seededVersions = versions
        for item in batch.changes.sorted(by: { $0.version < $1.version }) {
            snapshot = snapshot.applying(item.change)
            seededVersions[item.change.key] = max(seededVersions[item.change.key] ?? 0, item.version)
        }
        try await transport.commitFetchedState(batch.token)
        try await verify(context)
        versions = seededVersions
        published = snapshot
        return snapshot
    }

    // MARK: - Statistics

    /// Publishes the lifetime statistics when a metric changed since the last acknowledged publish.
    /// A failure is counted and retried on the next pass; it never blocks state or intent relay.
    private func publishStats(context: Context, into report: inout LibraryPublishReport) async throws {
        guard let statsProvider, let lifetime = await statsProvider() else { return }
        try await verify(context)
        var next = LibraryStats(lifetime, updatedAt: clock())
        next.supportedIntentActions = Self.supportedIntentActions
        if let publishedStats, publishedStats.hasSameMetrics(as: next) { return }
        do {
            try await transport.publishStats(next)
            try await verify(context)
            publishedStats = next
            report.statsPublished = true
        } catch {
            try await verify(context)
            report.statsFailures += 1
        }
    }

    /// The phone intents this Mac answers beyond the media and decision actions, so a phone sends
    /// only what it sees listed.
    static let supportedIntentActions = ["subscribe", "addArticle"]

    // MARK: - Intents

    private func relayIntents(context: Context, into report: inout LibraryPublishReport) async throws {
        let intents = try await transport.listIntents()
        try await verify(context)
        for intent in intents where !deliveredIntentIDs.contains(intent.id) {
            do {
                try await sink.receive(intent)
                try await verify(context)
                deliveredIntentIDs.insert(intent.id)
                report.intentsDelivered += 1
            } catch {
                try await verify(context)
                report.intentFailures += 1
            }
        }
    }
}
