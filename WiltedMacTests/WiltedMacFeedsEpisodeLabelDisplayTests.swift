import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacFeedsEpisodeLabelDisplayTests: XCTestCase {
    func testEpisodeLabelRowAndOffSwitchRenderWithoutChangingFeedActions() async throws {
        let key = WiltedMacEpisodeLabelPreference.key
        let priorPreference = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let priorPreference { UserDefaults.standard.set(priorPreference, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"]
        )
        let base = try XCTUnwrap(model.episodes.first)
        var candidate = WiltedMacEpisode(
            id: "label-preview-fixture", title: "Preview: Season Two", feedTitle: base.feedTitle,
            summary: "Fixture", artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000), sourceDurationSeconds: 600,
            durationSeconds: 600, playbackSeconds: 0, downloadState: .notDownloaded
        )
        candidate.feedID = "feed-label-fixture"
        model.episodes.append(candidate)
        let candidatesBefore = model.feedsEpisodeCandidates.map(\.id)
        let skippedBefore = model.skippedFeedEpisodes.map(\.id)
        let queueBefore = model.podcastQueueIDs
        XCTAssertTrue(candidatesBefore.contains(candidate.id))

        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedsView(model: model), size: CGSize(width: 1_000, height: 2_000)
        ).joined(separator: " ")
        XCTAssertTrue(shown.contains("Show episode labels"), shown)
        XCTAssertTrue(shown.contains("Likely trailer"), shown)
        XCTAssertTrue(shown.contains("identifying a season or upcoming-show preview"), shown)
        XCTAssertTrue(shown.contains("Keep"), shown)
        XCTAssertTrue(shown.contains("Skip"), shown)
        XCTAssertEqual(model.feedsEpisodeCandidates.map(\.id), candidatesBefore)
        XCTAssertEqual(model.skippedFeedEpisodes.map(\.id), skippedBefore)
        XCTAssertEqual(model.podcastQueueIDs, queueBefore)

        UserDefaults.standard.set(false, forKey: key)
        let hidden = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedsView(model: model), size: CGSize(width: 1_000, height: 2_000)
        ).joined(separator: " ")
        XCTAssertFalse(hidden.contains("Likely trailer"), hidden)
        XCTAssertFalse(hidden.contains("identifying a season or upcoming-show preview"), hidden)
        XCTAssertTrue(hidden.contains("Keep"), hidden)
        XCTAssertTrue(hidden.contains("Skip"), hidden)
        XCTAssertEqual(model.feedsEpisodeCandidates.map(\.id), candidatesBefore)
        XCTAssertEqual(model.skippedFeedEpisodes.map(\.id), skippedBefore)
        XCTAssertEqual(model.podcastQueueIDs, queueBefore)
    }
}
