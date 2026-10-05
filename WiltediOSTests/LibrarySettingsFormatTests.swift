import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The phone's Settings sync row names this phone's last successful library fetch and never claims
/// the library matches the Mac: a fetch cannot see what the Mac published afterwards.
@MainActor
final class LibrarySettingsFormatTests: XCTestCase {
    /// 2023-11-14 22:13:20 UTC.
    private nonisolated static let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let convergenceWords = ["up to date", "latest", "in sync", "synced with", "with mac", "matches", "current"]

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func assertNoConvergenceClaim(_ texts: [String?], file: StaticString = #filePath, line: UInt = #line) {
        for text in texts.compactMap({ $0?.lowercased() }) {
            for word in Self.convergenceWords {
                XCTAssertFalse(text.contains(word), "\"\(text)\" claims convergence with \"\(word)\"", file: file, line: line)
            }
        }
    }

    func testAStaleMacAfterASuccessfulFetchNamesThePhonesFetchAndNeverClaimsConvergence() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let show = LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show")
        _ = try await mac.push(changes: [PendingLibraryChange(localSeq: 1, change: .source(show), baseVersion: 0)])
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server),
            deviceID: "phone", preferences: UserDefaults(suiteName: "library-settings-format-tests")!,
            now: { Self.fetchedAt }, timeZone: TimeZone(identifier: "UTC")!)

        await model.refresh()
        // The Mac publishes after the phone's fetch, so the phone's copy is now behind.
        let entry = try LibraryEntry(
            id: id("later"), kind: .podcastEpisode, sourceID: id("show"), title: "Published later", summary: "",
            publishedAt: Self.fetchedAt, durationSeconds: 60)
        _ = try await mac.push(changes: [PendingLibraryChange(localSeq: 2, change: .entry(entry), baseVersion: 0)])

        let summary = model.syncSummary
        let line = LibrarySettingsFormat.syncLine(summary, lastRefresh: model.lastSynchronizedAt)
        XCTAssertEqual(model.lastSynchronizedAt, Self.fetchedAt)
        XCTAssertEqual(summary.status, "Fetched")
        XCTAssertEqual(summary.tone, .positive)
        XCTAssertEqual(summary.detail, "Fetch time reports this phone’s last successful library read.")
        XCTAssertEqual(line, "Fetched · \(LibrarySettingsFormat.date(Self.fetchedAt))")
        assertNoConvergenceClaim([summary.status, summary.detail, line])
    }

    func testActiveErrorAndRateLimitStillOutrankASuccessfulFetch() {
        let fetched = Self.fetchedAt
        func summary(refreshing: Bool = false, quarantined: Bool = false, error: String? = nil,
                     throttle: String? = nil, retrying: Bool = false) -> LibrarySettingsFormat.SyncSummary {
            LibrarySettingsFormat.sync(
                isRefreshing: refreshing, quarantined: quarantined, error: error, lastRefresh: fetched,
                throttleNotice: throttle, throttleRetrying: retrying)
        }
        let cases: [(LibrarySettingsFormat.SyncSummary, String, String?, WiltedStatusTone)] = [
            (summary(refreshing: true, quarantined: true, error: "x", throttle: "t"), "Needs review",
             "The iCloud account changed.", .caution),
            (summary(refreshing: true, error: "x", throttle: "iCloud is rate limiting sync."), "Paused",
             "iCloud is rate limiting sync.", .caution),
            (summary(refreshing: true, error: "x", throttle: "Retrying now…", retrying: true), "Retrying",
             "Retrying now…", .active),
            (summary(refreshing: true, error: "x"), "Syncing", nil, .active),
            (summary(error: "The library could not be fetched."), "Problem", "The library could not be fetched.", .failure),
        ]
        for (result, status, detail, tone) in cases {
            XCTAssertEqual(result.status, status)
            XCTAssertEqual(result.detail, detail, status)
            XCTAssertEqual(result.tone, tone, status)
            // Only the idle state carries the fetch time; a busy or failing row says what is happening.
            XCTAssertEqual(LibrarySettingsFormat.syncLine(result, lastRefresh: fetched), status)
            assertNoConvergenceClaim([result.status, result.detail])
        }
    }

    func testANeverFetchedPhoneShowsNoFetchTime() {
        let never = LibrarySettingsFormat.sync(isRefreshing: false, quarantined: false, error: nil, lastRefresh: nil)
        XCTAssertEqual(never.status, "Not synced yet")
        XCTAssertNil(never.detail)
        XCTAssertEqual(never.tone, .neutral)
        XCTAssertEqual(LibrarySettingsFormat.syncLine(never, lastRefresh: nil), "Not synced yet")
        assertNoConvergenceClaim([never.status, never.detail])
    }

    func testThePhoneStatisticsGroupIsTitledThisIPhoneAndKeepsOnlyItsOwnTotals() {
        XCTAssertTrue(LibrarySettingsFormat.phoneStatisticsTitle.contains("iPhone"),
                      "the group is titled for this iPhone, not the Mac's lifetime statistics")
        XCTAssertNotEqual(LibrarySettingsFormat.phoneStatisticsTitle, WiltedScreenCopy.lifetimeStatistics)
        XCTAssertEqual(LibrarySettingsFormat.phoneStatRows(LibraryPhoneStats()).count, 3,
                       "only the phone's own three totals; the Mac's seven include Mac-only work")
    }
}
