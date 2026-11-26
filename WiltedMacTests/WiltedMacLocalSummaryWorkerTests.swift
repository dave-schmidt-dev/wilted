import Foundation
import XCTest
import WiltedProducer

final class WiltedMacLocalSummaryWorkerTests: XCTestCase {
    func testConfiguredWorkerSummarizesInventedTextAndRecordsLatency() async throws {
        guard ProcessInfo.processInfo.environment["WILTED_RUN_LOCAL_SUMMARY_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set WILTED_RUN_LOCAL_SUMMARY_ACCEPTANCE=1 for the bounded local-model check.")
        }
        let modelURL = TranscriptSummaryService.Configuration.resolved().modelURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path), "the configured local model must already exist")

        let transcript = "Pinebridge Public Library opened a roof garden on Tuesday after crews reinforced the roof. "
            + "The garden contains twelve raised planters. Volunteer Mira Chen placed blue basil beside the rain gauge, "
            + "and cherry tomatoes line the west wall. Chen coordinates six volunteers who meet on Wednesday mornings. "
            + "The library expects its first harvest on May 20. The produce will go to a neighborhood cooking class "
            + "that meets each Saturday. A tank under the downspout collects rainwater for irrigation. Librarian "
            + "Niko Patel checks the gauge weekly and logs water use. At the end of May, the library will publish a "
            + "water-use total and compare it with last year's hose use.\n\n"
            + "The launch announcement restated several details: roof work came before the garden opened; there are "
            + "twelve planters; Chen's basil is next to the gauge; tomato plants are along the west wall. The same "
            + "six volunteers meet Wednesdays. The first produce is planned for May 20, for the Saturday class. "
            + "No produce is being sold, and the garden is not a year-round farm.\n\n"
            + "Chen clarified that the gauge does not measure water in the whole building, only garden irrigation. "
            + "Rainwater in the tank is the primary source. The library's monthly report will show the garden's water "
            + "total at the end of May so staff can compare that number with last year's hose use. The Saturday class "
            + "will use the harvest in a community cooking lesson."
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await TranscriptSummaryService().summarize(transcript: transcript, modelURL: modelURL)
        let elapsed = start.duration(to: clock.now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertGreaterThan(summary.count, 40)
        XCTAssertLessThan(summary.unicodeScalars.count, transcript.unicodeScalars.count * 3 / 4,
                          "a share summary should condense a repeated-context transcript")
        for fact in ["pinebridge", "may 20", "saturday", "rainwater"] {
            XCTAssertTrue(summary.localizedCaseInsensitiveContains(fact), "missing key fact \(fact): \(summary)")
        }
        XCTAssertFalse(summary.localizedCaseInsensitiveContains("I cannot"))
        let attachment = XCTAttachment(string: "elapsed_ms=\(Int(milliseconds))\nsummary=\(result.summary)")
        attachment.name = "local-summary-worker-result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
