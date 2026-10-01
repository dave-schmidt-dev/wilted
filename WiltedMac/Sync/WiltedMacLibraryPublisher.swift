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
/// Default OFF: nothing is contacted unless `WILTED_LIBRARY_SYNC=1`. The publisher is the
/// library's single writer, so it seeds its per-record base versions from the server on the
/// first pass, then sends only what `LibraryStateDiffer` reports as changed.
actor WiltedMacLibraryPublisher {
    static let environmentKey = "WILTED_LIBRARY_SYNC"

    /// True only when the environment sets `WILTED_LIBRARY_SYNC` to exactly `1`.
    static func isEnabled(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
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

    init(
        source: any LibraryStateSource,
        transport: any LibraryTransport,
        sink: any LibraryIntentSink,
        isEnabled: Bool = WiltedMacLibraryPublisher.isEnabled(),
        statsProvider: (@Sendable () async -> LifetimeStatistics?)? = nil,
        relaysIntents: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.relaysIntents = relaysIntents
        self.source = source
        self.transport = transport
        self.sink = sink
        self.isEnabled = isEnabled
        self.statsProvider = statsProvider
        self.clock = clock
    }

    /// One publish-then-relay pass. Returns `.disabled` without touching the source or
    /// transport when the feature flag is off.
    func sync(includesStats: Bool = true) async throws -> LibraryPublishReport {
        guard isEnabled else { return .disabled }
        var report = LibraryPublishReport()
        let state = try await source.currentState()
        try await publishState(state, into: &report)
        if includesStats { await publishStats(into: &report) }
        if relaysIntents { try await relayIntents(into: &report) }
        return report
    }

    // MARK: - State

    private func publishState(_ state: LibraryStateSnapshot, into report: inout LibraryPublishReport) async throws {
        let current = try state.replicatedContent()
        let baseline = try await seededBaseline()
        var pending: [PendingLibraryChange] = []
        for change in LibraryStateDiffer.diff(from: baseline, to: current) {
            pending.append(PendingLibraryChange(
                localSeq: nextLocalSeq, change: change, baseVersion: versions[change.key] ?? 0
            ))
            nextLocalSeq += 1
        }
        report.pushed = pending.count
        guard !pending.isEmpty else { return }

        let result = try await transport.push(changes: pending)
        let changesByKey = Dictionary(pending.map { ($0.key, $0.change) }, uniquingKeysWith: { _, last in last })
        var next = baseline
        for ack in result.acknowledged {
            versions[ack.key] = ack.version
            if let change = changesByKey[ack.key] { next = next.applying(change) }
        }
        published = next
        report.acknowledged = result.acknowledged.count
        for failure in result.failures {
            switch failure.disposition {
            case .conflict:
                report.conflicts += 1
                // The Mac is the only writer, so adopt the server's version and resend next pass.
                if let server = failure.server { versions[failure.key] = server.version }
            case .retryable: report.retryable += 1
            case .terminal: report.terminal += 1
            }
        }
        try await transport.commitSentState(result.token)
    }

    /// The server's current content, fetched once. A restarted publisher therefore resumes
    /// from what is already published instead of rewriting or conflicting with it.
    private func seededBaseline() async throws -> LibrarySnapshot {
        if let published { return published }
        let batch = try await transport.fetchChanges(since: nil)
        var snapshot = LibrarySnapshot()
        for item in batch.changes.sorted(by: { $0.version < $1.version }) {
            snapshot = snapshot.applying(item.change)
            versions[item.change.key] = max(versions[item.change.key] ?? 0, item.version)
        }
        try await transport.commitFetchedState(batch.token)
        published = snapshot
        return snapshot
    }

    // MARK: - Statistics

    /// Publishes the lifetime statistics when a metric changed since the last acknowledged publish.
    /// A failure is counted and retried on the next pass; it never blocks state or intent relay.
    private func publishStats(into report: inout LibraryPublishReport) async {
        guard let statsProvider, let lifetime = await statsProvider() else { return }
        let next = LibraryStats(lifetime, updatedAt: clock())
        if let publishedStats, publishedStats.hasSameMetrics(as: next) { return }
        do {
            try await transport.publishStats(next)
            publishedStats = next
            report.statsPublished = true
        } catch {
            report.statsFailures += 1
        }
    }

    // MARK: - Intents

    private func relayIntents(into report: inout LibraryPublishReport) async throws {
        for intent in try await transport.listIntents() where !deliveredIntentIDs.contains(intent.id) {
            do {
                try await sink.receive(intent)
                deliveredIntentIDs.insert(intent.id)
                report.intentsDelivered += 1
            } catch {
                report.intentFailures += 1
            }
        }
    }
}
