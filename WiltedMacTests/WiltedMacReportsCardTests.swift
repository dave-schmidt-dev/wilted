import Foundation
import XCTest
@testable import WiltedMac

/// The daily-report status line and Build now button in Settings > Reports.
@MainActor
final class WiltedMacReportsCardTests: XCTestCase {
    func testNotPublishedReasonAppearsInTheCaption() async throws {
        let suite = WiltedMacTestPreferences.suiteName("reports-card-tests")
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        let model = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertNil(model.morningReport.state.caption(), "nothing to say before a run")
        await model.morningReport.buildNow()

        guard case let .notPublished(reason) = model.morningReport.state else {
            return XCTFail("a build without an open library publishes nothing")
        }
        XCTAssertEqual(model.morningReport.state.caption(), "Not published: \(reason)")
    }

    func testCaptionsForEachState() {
        let at = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(WiltedMorningReportState.published(title: "Morning", at: at).caption(timeStyle: { _ in "6:30 AM" }),
                       "Last report: 6:30 AM")
        XCTAssertEqual(WiltedMorningReportState.building(fraction: 0.5, detail: "Reading headlines").caption(),
                       "Building… 50% Reading headlines")
    }

    func testBuildNowIsDisabledWhileBuildingOrWhenTheDailyReportIsOff() {
        let building = WiltedMorningReportState.building(fraction: 0.2, detail: "Starting")
        let idle = WiltedMorningReportState.idle
        XCTAssertTrue(WiltedMorningReportState.buildNowDisabled(state: building, reportEnabled: true))
        XCTAssertTrue(WiltedMorningReportState.buildNowDisabled(state: idle, reportEnabled: false))
        XCTAssertFalse(WiltedMorningReportState.buildNowDisabled(state: idle, reportEnabled: true))
        XCTAssertFalse(WiltedMorningReportState.buildNowDisabled(
            state: .notPublished(reason: "x"), reportEnabled: true))
    }
}
