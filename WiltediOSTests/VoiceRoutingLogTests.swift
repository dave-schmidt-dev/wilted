import Foundation
@preconcurrency import Intents
import SwiftUI
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class VoiceRoutingLogTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-routing-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - Retention and Capping

    func testKeptListCapsAt50LinesAndPreservesNewestLine() {
        let fileURL = tempDirectory.appendingPathComponent("test-cap.log")
        let log = VoiceRoutingLog(fileURL: fileURL)

        for i in 1...70 {
            log.log("line-\(i)")
        }

        let lines = log.lines()
        XCTAssertEqual(lines.count, 50, "the kept list must not grow past 50 lines")
        XCTAssertEqual(lines.first, "line-21", "the oldest 20 lines must be dropped")
        XCTAssertEqual(lines.last, "line-70", "the newest line must be preserved")

        // Also verify reloading from disk retains the exact capped list
        let reloaded = VoiceRoutingLog(fileURL: fileURL)
        XCTAssertEqual(reloaded.lines().count, 50)
        XCTAssertEqual(reloaded.lines().first, "line-21")
        XCTAssertEqual(reloaded.lines().last, "line-70")
    }

    func testLoggingPreservesNewestLineWhenCapped() {
        let fileURL = tempDirectory.appendingPathComponent("test-newest.log")
        let log = VoiceRoutingLog(fileURL: fileURL)

        for i in 1...50 {
            log.log("initial-\(i)")
        }
        XCTAssertEqual(log.lines().count, 50)
        XCTAssertEqual(log.lines().last, "initial-50")

        log.log("brand-new-51")
        XCTAssertEqual(log.lines().count, 50)
        XCTAssertEqual(log.lines().last, "brand-new-51", "newest line must never be lost when list is full")
        XCTAssertEqual(log.lines().first, "initial-2", "oldest line must be evicted")
    }

    // MARK: - Line Formatting

    func testAppIntentLineFormatting() {
        let line = VoiceRoutingLog.appIntentLine(
            path: "PlayNextEpisodeIntent.perform",
            command: "playNext(show: nil)",
            outcome: "Playing episode 1.")
        XCTAssertEqual(
            line,
            "PlayNextEpisodeIntent.perform: command=playNext(show: nil), outcome=Playing episode 1.")
    }

    func testSiriKitLineFormattingWithSearchFields() {
        let search = INMediaSearch(
            mediaType: .podcastShow,
            sortOrder: .newest,
            mediaName: "Planet Money",
            artistName: "NPR",
            albumName: "Show Album",
            genreNames: nil,
            moodNames: nil,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: nil)

        let line = VoiceRoutingLog.siriKitLine(
            path: "PlayMediaIntentHandler.resolveMediaItems",
            outcome: "unsupported",
            search: search,
            prechosen: false)

        XCTAssertTrue(line.hasPrefix("PlayMediaIntentHandler.resolveMediaItems:"))
        XCTAssertTrue(line.contains("outcome=unsupported"))
        XCTAssertTrue(line.contains("mediaType=podcastShow"))
        XCTAssertTrue(line.contains("mediaName=Planet Money"))
        XCTAssertTrue(line.contains("artistName=NPR"))
        XCTAssertTrue(line.contains("albumName=Show Album"))
        XCTAssertTrue(line.contains("sortOrder=newest"))
        XCTAssertTrue(line.contains("prechosen=false"))
    }

    func testSiriKitLineFormattingNilSearchFields() {
        let line = VoiceRoutingLog.siriKitLine(
            path: "PlayMediaIntentHandler.handle",
            outcome: "failure",
            search: nil,
            prechosen: true)

        XCTAssertTrue(line.hasPrefix("PlayMediaIntentHandler.handle:"))
        XCTAssertTrue(line.contains("outcome=failure"))
        XCTAssertTrue(line.contains("mediaType=none"))
        XCTAssertTrue(line.contains("mediaName=none"))
        XCTAssertTrue(line.contains("artistName=none"))
        XCTAssertTrue(line.contains("albumName=none"))
        XCTAssertTrue(line.contains("sortOrder=none"))
        XCTAssertTrue(line.contains("prechosen=true"))
    }

    func testExtensionLineFormattingMatchesFormat() {
        let search = INMediaSearch(
            mediaType: .podcastEpisode,
            sortOrder: .unknown,
            mediaName: "Episode Title",
            artistName: "Artist",
            albumName: nil,
            genreNames: nil,
            moodNames: nil,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: nil)

        let line = PlayMediaExtensionHandler.siriKitLine(
            path: "PlayMediaExtensionHandler.resolveMediaItems",
            outcome: "notRequired",
            search: search,
            prechosen: false)

        XCTAssertTrue(line.hasPrefix("PlayMediaExtensionHandler.resolveMediaItems:"))
        XCTAssertTrue(line.contains("outcome=notRequired"))
        XCTAssertTrue(line.contains("mediaType=podcastEpisode"))
        XCTAssertTrue(line.contains("mediaName=Episode Title"))
        XCTAssertTrue(line.contains("artistName=Artist"))
        XCTAssertTrue(line.contains("albumName=none"))
        XCTAssertTrue(line.contains("sortOrder=unknown"))
        XCTAssertTrue(line.contains("prechosen=false"))
    }

    // MARK: - Settings View Model Integration

    func testSupportRowsIncludeTheVoiceRoutingLogWithCopy() {
        let lines = ["Line 1: playNext", "Line 2: outcome=success"]
        let rows = LibrarySettingsFormat.supportRows(deviceID: "phone-test-id", voiceLines: lines, requests: nil)
        XCTAssertEqual(rows.map(\.identifier),
                       [LibrarySettingsFormat.deviceIdentifier, LibrarySettingsFormat.voiceRoutingLogIdentifier])
        let voiceRow = rows.first { $0.identifier == LibrarySettingsFormat.voiceRoutingLogIdentifier }
        XCTAssertEqual(voiceRow?.value, "Line 1: playNext\nLine 2: outcome=success")
        XCTAssertTrue(voiceRow?.isCopyable == true, "Voice routing log row must have a copy button")
        XCTAssertTrue(voiceRow?.wrapsText == true)
    }

    func testSupportRowsWithEmptyVoiceLinesShowNone() {
        let rows = LibrarySettingsFormat.supportRows(deviceID: "phone-1", voiceLines: [], requests: nil)
        let voiceRow = rows.first { $0.identifier == LibrarySettingsFormat.voiceRoutingLogIdentifier }
        XCTAssertEqual(voiceRow?.value, "None")
        XCTAssertTrue(voiceRow?.isCopyable == true)
    }
}
