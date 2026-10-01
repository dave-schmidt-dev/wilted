import Foundation
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// The Mac's iCloud line in Settings > Sync reads like the phone's.
final class WiltedMacSyncBannerTests: XCTestCase {
    func testTheICloudBannerNeverShowsAResumeTimeThatHasPassed() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ahead = TransportGateState(kind: .rateLimited, retryAt: now.addingTimeInterval(45), consecutiveFailures: 1)
        let past = TransportGateState(kind: .rateLimited, retryAt: now.addingTimeInterval(-5), consecutiveFailures: 1)
        XCTAssertTrue(ahead.noticeWithResumeTime(now: now, retrying: false).contains("Retrying at"))
        XCTAssertEqual(past.noticeWithResumeTime(now: now, retrying: false), "iCloud is rate limiting sync. Retrying now…")
        let view = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/Views/WiltedMacSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("noticeWithResumeTime(now: context.date"), "the Mac banner uses the same line as the phone")
        XCTAssertFalse(view.contains("Resumes at"), "no stale resume time")
    }
}
