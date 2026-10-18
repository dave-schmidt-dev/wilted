import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// A transport Pause refreshes the lifetime statistics card. That refresh
/// used to ride the retired article publication path, and the pause site is
/// where it must remain wired now that publication is gone.
@MainActor
final class WiltedMacPlaybackStatisticsTests: XCTestCase {
    func testTransportPauseRefreshesLifetimeStatistics() async throws {
        let counter = StatisticsSummaryCalls()
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("playback-statistics"),
            statisticsOperations: WiltedMacStatisticsOperations(
                summary: { _ in await counter.next() },
                rebuild: { _, _ in throw StatisticsSummaryCallsFailure() }
            ),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let backend = WiltedMacScriptedBackend()
        model.installPlaybackBackendForTesting(backend)
        await model.waitForLifetimeStatisticsForTesting()
        XCTAssertEqual(model.statisticsState.summary?.measured.playedMilliseconds, 1_000)

        let article = try XCTUnwrap(model.articles.first(where: \.isReady))
        model.openNowPlaying(for: article, autoplay: true)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.isPlaying, "the article must be playing before the pause")

        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        await model.waitForLifetimeStatisticsRefreshForTesting()

        let calls = await counter.calls
        XCTAssertEqual(calls, 2, "the transport pause refreshes the lifetime statistics exactly once")
        XCTAssertEqual(model.statisticsState.summary?.measured.playedMilliseconds, 2_000)
        await model.close()
    }
}

/// Counts lifetime summary reads and answers a newer summary on each one, so
/// a refresh is visible as both a call and a changed total.
private actor StatisticsSummaryCalls {
    private(set) var calls = 0

    func next() -> LifetimeStatisticsSummary {
        calls += 1
        return LifetimeStatisticsSummary(
            state: .ready,
            measured: LifetimeMeasuredTotals(playedMilliseconds: Int64(calls) * 1_000)
        )
    }
}

private struct StatisticsSummaryCallsFailure: Error {}
