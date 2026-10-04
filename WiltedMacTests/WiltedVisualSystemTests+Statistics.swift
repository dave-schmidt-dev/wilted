import Foundation
import XCTest
import WiltedDomain
@testable import WiltedMac

/// Task 8.2 presentation: units, tracking start and the states Settings can be in.
extension WiltedVisualSystemTests {
    private var posix: Locale { Locale(identifier: "en_US") }

    func testMinutesAreWholeAndNeverOverstated() {
        XCTAssertEqual(WiltedMacStatisticsCopy.minutes(milliseconds: 0, locale: posix), "0 min")
        XCTAssertEqual(WiltedMacStatisticsCopy.minutes(milliseconds: 1, locale: posix), "<1 min")
        XCTAssertEqual(WiltedMacStatisticsCopy.minutes(milliseconds: 59_999, locale: posix), "<1 min")
        XCTAssertEqual(WiltedMacStatisticsCopy.minutes(milliseconds: 60_000, locale: posix), "1 min")
        XCTAssertEqual(WiltedMacStatisticsCopy.minutes(milliseconds: 119_999, locale: posix), "1 min")
        XCTAssertEqual(WiltedMacStatisticsCopy.minutes(milliseconds: 72_000_000, locale: posix), "1,200 min")
    }

    func testGigabytesAreDecimalAndNeverOverstated() {
        XCTAssertEqual(WiltedMacStatisticsCopy.gigabytes(bytes: 0, locale: posix), "0 GB")
        XCTAssertEqual(WiltedMacStatisticsCopy.gigabytes(bytes: 9_999_999, locale: posix), "<0.01 GB")
        XCTAssertEqual(WiltedMacStatisticsCopy.gigabytes(bytes: 10_000_000, locale: posix), "0.01 GB")
        XCTAssertEqual(WiltedMacStatisticsCopy.gigabytes(bytes: 1_000_000_000, locale: posix), "1.00 GB")
        XCTAssertEqual(WiltedMacStatisticsCopy.gigabytes(bytes: 1_239_999_999, locale: posix), "1.23 GB")
        XCTAssertEqual(WiltedMacStatisticsCopy.gigabytes(bytes: 1_073_741_824, locale: posix), "1.07 GB",
                       "decimal gigabytes, not GiB")
    }

    func testTrackingStartIsStatedHonestlyOrAbsent() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let started = Date(timeIntervalSince1970: 1_791_000_000)  // 2026-10-03 UTC
        let text = WiltedMacStatisticsCopy.trackingStart(started, locale: posix, timeZone: utc)
        XCTAssertTrue(text.contains("Oct 3, 2026"), text)
        XCTAssertTrue(text.contains("Earlier listening was not measured."), text)
        XCTAssertEqual(WiltedMacStatisticsCopy.trackingStart(nil), WiltedMacStatisticsCopy.trackingNotStarted)
    }

    func testEmptySummaryIsRecognisedOnlyWhenEverySevenTotalsIsZero() {
        XCTAssertTrue(WiltedMacStatisticsCopy.isEmpty(LifetimeStatisticsSummary(state: .ready)))
        XCTAssertFalse(WiltedMacStatisticsCopy.isEmpty(LifetimeStatisticsSummary(
            state: .ready, legacy: LifetimeStatistics(speechGeneratedSeconds: 1))))
        XCTAssertFalse(WiltedMacStatisticsCopy.isEmpty(LifetimeStatisticsSummary(
            state: .ready, measured: LifetimeMeasuredTotals(receivedBytes: 1))))
    }

    func testStatisticsStateShowsTotalsOnlyWhenReady() {
        let summary = LifetimeStatisticsSummary(state: .ready)
        XCTAssertEqual(WiltedMacStatisticsState.ready(summary).summary, summary)
        XCTAssertNil(WiltedMacStatisticsState.loading.summary)
        XCTAssertNil(WiltedMacStatisticsState.rebuilding(nil).summary)
        XCTAssertNil(WiltedMacStatisticsState.unavailable(detail: "x").summary)
        XCTAssertNil(WiltedMacStatisticsProgress(processedEvents: 3, totalEvents: 0).fraction)
        XCTAssertEqual(WiltedMacStatisticsProgress(processedEvents: 9, totalEvents: 3).fraction, 1)
    }

    func testMacSettingsPresentSevenTotalsAndEveryStatisticsStateWithStableIdentifiers() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: sourceRoot)
        for name in [
            "WiltedMacStatisticsCopy.playedTimeIdentifier", "WiltedMacStatisticsCopy.downloadedIdentifier",
            "WiltedMacStatisticsCopy.manuallySkippedIdentifier", "WiltedMacStatisticsCopy.trackingStartIdentifier",
            "WiltedMacStatisticsCopy.retryIdentifier", "WiltedMacStatisticsCopy.statusIdentifier",
            "case .loading", "case .rebuilding", "case .unavailable", "case .ready",
        ] {
            XCTAssertTrue(source.contains(name), "\(name) is presented in Settings")
        }
        XCTAssertEqual(
            Set([WiltedMacStatisticsCopy.playedTimeIdentifier, WiltedMacStatisticsCopy.downloadedIdentifier,
                 WiltedMacStatisticsCopy.manuallySkippedIdentifier, WiltedMacStatisticsCopy.trackingStartIdentifier,
                 WiltedMacStatisticsCopy.statusIdentifier, WiltedMacStatisticsCopy.retryIdentifier]).count, 6)
    }
}
