import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

/// Holds a store operation open until the test lets it go.
private actor StatisticsGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private struct StatisticsFailure: Error {}

private actor AttemptCounter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

/// Task 8.2: lifetime statistics are observed state. A delayed, corrupt or
/// failing summary never changes whether the larder opens, and a store that
/// really will not open stays its own, distinct failure.
@MainActor
final class WiltedMacStatisticsStartupTests: XCTestCase {
    private func makeModel(
        in directory: URL,
        operations: WiltedMacStatisticsOperations = .live,
        storeBootstrap: WiltedMacStoreBootstrap? = nil
    ) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: storeBootstrap,
            statisticsOperations: operations,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    private func operations(
        summary: @escaping @Sendable () async throws -> LifetimeStatisticsSummary,
        rebuild: @escaping @Sendable (@Sendable (WiltedMacStatisticsProgress) -> Void) async throws
            -> LifetimeStatisticsSummary = { _ in throw StatisticsFailure() }
    ) -> WiltedMacStatisticsOperations {
        WiltedMacStatisticsOperations(summary: { _ in try await summary() }, rebuild: { _, progress in
            try await rebuild(progress)
        })
    }

    private func ready(
        legacy: LifetimeStatistics = LifetimeStatistics(),
        measured: LifetimeMeasuredTotals = LifetimeMeasuredTotals(),
        since: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> LifetimeStatisticsSummary {
        LifetimeStatisticsSummary(state: .ready, legacy: legacy, measured: measured, trackingStartedAt: since)
    }

    // MARK: Delayed and failing summaries

    /// Bootstrap finishes while the summary read is still in flight: the
    /// larder is ready and Settings says "loading", never zeros.
    func testDelayedSummaryStillOpensLarderAndShowsLoading() async throws {
        let gate = StatisticsGate()
        let expected = ready(measured: LifetimeMeasuredTotals(playedMilliseconds: 90_000))
        let model = makeModel(in: wiltedTemporaryDirectory("stats-delayed"), operations: operations(
            summary: { await gate.wait(); return expected }
        ))

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.statisticsState, .loading)
        XCTAssertNil(model.statisticsState.summary, "no totals are claimed while loading")

        await gate.open()
        await model.waitForLifetimeStatisticsForTesting()
        XCTAssertEqual(model.statisticsState, .ready(expected))
    }

    /// A summary that cannot be read is statistics-unavailable, and the larder
    /// is as ready as it would have been without it.
    func testCorruptSummaryReadIsUnavailableNotACannotOpenFailure() async throws {
        let model = makeModel(in: wiltedTemporaryDirectory("stats-corrupt"), operations: operations(
            summary: { throw StatisticsFailure() }
        ))

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForLifetimeStatisticsForTesting()

        XCTAssertEqual(model.startupState, .ready, "statistics never fail the larder")
        guard case .unavailable = model.statisticsState else {
            return XCTFail("expected unavailable, got \(model.statisticsState)")
        }
        XCTAssertNil(model.statisticsState.summary)
        XCTAssertNotNil(model.store, "the library store stays open and usable")
    }

    /// A store that really will not open keeps its own message, and the
    /// statistics are never started against it.
    func testActualStoreOpenFailureRemainsDistinctFromStatisticsFailure() async throws {
        let model = makeModel(
            in: wiltedTemporaryDirectory("stats-open-failure"),
            operations: operations(summary: { throw StatisticsFailure() }),
            storeBootstrap: { _ in throw StatisticsFailure() }
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForLifetimeStatisticsForTesting()

        guard case .failed(let failure) = model.startupState else {
            return XCTFail("expected a startup failure, got \(model.startupState)")
        }
        XCTAssertEqual(failure.message, "Wilted could not open your larder. The existing library was left in place.")
        XCTAssertEqual(model.statisticsState, .loading, "statistics never ran, so none can be unavailable")
    }

    // MARK: Rebuild

    /// After the V14 migration the summary must be rebuilt: Settings shows
    /// progress (and no totals) until the rebuilt summary is published.
    func testRebuildShowsProgressThenPublishesTotals() async throws {
        let gate = StatisticsGate()
        let rebuilt = ready(measured: LifetimeMeasuredTotals(playedMilliseconds: 600_000))
        let model = makeModel(in: wiltedTemporaryDirectory("stats-rebuild"), operations: operations(
            summary: { LifetimeStatisticsSummary(state: .rebuildRequired) },
            rebuild: { progress in
                progress(WiltedMacStatisticsProgress(processedEvents: 50, totalEvents: 200))
                await gate.wait()
                return rebuilt
            }
        ))

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready, "a rebuild never holds the larder closed")
        for _ in 0..<200 where model.statisticsState != .rebuilding(WiltedMacStatisticsProgress(processedEvents: 50, totalEvents: 200)) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.statisticsState, .rebuilding(WiltedMacStatisticsProgress(processedEvents: 50, totalEvents: 200)))
        XCTAssertEqual(WiltedMacStatisticsProgress(processedEvents: 50, totalEvents: 200).fraction, 0.25)
        XCTAssertNil(model.statisticsState.summary)

        await gate.open()
        await model.waitForLifetimeStatisticsForTesting()
        XCTAssertEqual(model.statisticsState, .ready(rebuilt))
    }

    /// A rebuild failure is unavailable state; retrying runs the whole load again.
    func testRebuildFailureIsNonFatalAndRetryRecovers() async throws {
        let attempts = AttemptCounter()
        let rebuilt = ready(legacy: LifetimeStatistics(audioProcessedSeconds: 120))
        let model = makeModel(in: wiltedTemporaryDirectory("stats-retry"), operations: operations(
            summary: { LifetimeStatisticsSummary(state: .rebuildRequired) },
            rebuild: { _ in
                if await attempts.next() == 1 { throw StatisticsFailure() }
                return rebuilt
            }
        ))

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForLifetimeStatisticsForTesting()
        XCTAssertEqual(model.startupState, .ready)
        guard case .unavailable = model.statisticsState else {
            return XCTFail("expected unavailable, got \(model.statisticsState)")
        }

        model.retryLifetimeStatistics()
        await model.waitForLifetimeStatisticsForTesting()
        XCTAssertEqual(model.statisticsState, .ready(rebuilt))
        XCTAssertEqual(model.lifetimeStatistics.audioProcessedSeconds, 120)
    }

    func testRetryDoesNothingUnlessStatisticsAreUnavailable() async throws {
        let steady = ready()
        let model = makeModel(in: wiltedTemporaryDirectory("stats-retry-noop"), operations: operations(
            summary: { steady }
        ))
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForLifetimeStatisticsForTesting()
        let before = model.statisticsState
        model.retryLifetimeStatistics()
        XCTAssertEqual(model.statisticsState, before)
    }

    // MARK: Real store

    /// The live path: the old four totals and the three measured totals come
    /// from one summary of a real store, in the stored units.
    func testRealStoreSummaryShowsOldFourAndMeasuredTotalsUnchanged() async throws {
        let model = makeModel(in: wiltedTemporaryDirectory("stats-real"), storeBootstrap: { url in
            let store = try LocalLibraryStore(url: url)
            _ = try await store.recordLifetimeStatistic(id: "audio-one", kind: .audioProcessed, seconds: 120)
            _ = try await store.recordLifetimeStatistic(id: "speech-one", kind: .speechGenerated, seconds: 45)
            _ = try await store.recordLifetimeStatistic(id: "ad-one", kind: .confirmedAdTimeRemoved, seconds: 30)
            _ = try await store.recordLifetimeStatistic(id: "speed-one", kind: .fasterPlaybackTimeSaved, seconds: 15)
            let at = Date(timeIntervalSince1970: 1_700_000_100)
            _ = try await store.recordLifetimeMeasure(
                id: "played-one", try XCTUnwrap(.time(.playedTime, seconds: 5_400)), at: at)
            _ = try await store.recordLifetimeMeasure(
                id: "bytes-one", try XCTUnwrap(.bytes(.receivedBytes, count: 1_234_567_890)), at: at)
            _ = try await store.recordLifetimeMeasure(
                id: "skip-one", try XCTUnwrap(.time(.manuallySkippedTime, seconds: 59.999)), at: at)
            return store
        })

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForLifetimeStatisticsForTesting()

        let summary = try XCTUnwrap(model.statisticsState.summary, "statistics are ready")
        XCTAssertEqual(summary.legacy, LifetimeStatistics(
            audioProcessedSeconds: 120, speechGeneratedSeconds: 45,
            confirmedAdTimeRemovedSeconds: 30, fasterPlaybackTimeSavedSeconds: 15
        ), "the old four survive unchanged")
        XCTAssertEqual(summary.measured, LifetimeMeasuredTotals(
            playedMilliseconds: 5_400_000, receivedBytes: 1_234_567_890, manuallySkippedMilliseconds: 59_999
        ))
        XCTAssertEqual(WiltedMacStatisticsCopy.minutes(milliseconds: summary.measured.playedMilliseconds, locale: Locale(identifier: "en_US")), "90 min")
        XCTAssertEqual(WiltedMacStatisticsCopy.gigabytes(bytes: summary.measured.receivedBytes, locale: Locale(identifier: "en_US")), "1.23 GB")
        XCTAssertEqual(WiltedMacStatisticsCopy.minutes(milliseconds: summary.measured.manuallySkippedMilliseconds, locale: Locale(identifier: "en_US")), "<1 min")
        let stored = try await XCTUnwrap(model.store).lifetimeStatisticsSummary()
        XCTAssertEqual(stored.state, .ready)
        XCTAssertEqual(stored.measured, summary.measured)
        XCTAssertEqual(model.lifetimeStatistics.audioProcessedSeconds, 120)
        await model.close()
    }

    // MARK: Wire projection

    /// The new totals are Mac-only: the wire value built from the same
    /// summary leaves every reserved optional nil and carries the old four exactly.
    func testWireProjectionKeepsNewTotalsNilAndOldFourUnchanged() throws {
        let summary = ready(
            legacy: LifetimeStatistics(audioProcessedSeconds: 1, speechGeneratedSeconds: 2,
                                       confirmedAdTimeRemovedSeconds: 3, fasterPlaybackTimeSavedSeconds: 4),
            measured: LifetimeMeasuredTotals(playedMilliseconds: 60_000, receivedBytes: 2_000_000_000,
                                             manuallySkippedMilliseconds: 120_000)
        )
        let wire = LibraryStats(summary.legacy)
        XCTAssertNil(wire.minutesPlayed)
        XCTAssertNil(wire.gigabytesDownloaded)
        XCTAssertNil(wire.minutesSkipped)
        XCTAssertEqual(wire, LibraryStats(
            audioProcessedSeconds: 1, speechGeneratedSeconds: 2,
            confirmedAdTimeRemovedSeconds: 3, fasterPlaybackTimeSavedSeconds: 4
        ))
        let json = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
        for key in ["minutesPlayed", "gigabytesDownloaded", "minutesSkipped"] {
            XCTAssertFalse(json.contains(key), "\(key) is not written")
        }
    }
}
