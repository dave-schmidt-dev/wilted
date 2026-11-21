import SwiftUI
import Vision
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacShowSettingsTests: XCTestCase {
    func testPodcastSettingsShowEveryPodcastControlAndItsDefaultOnce() async throws {
        let fixture = try makeFixture(isArticle: false)
        let text = try rendered(fixture)

        for label in [
            "New episodes", "Ads", "Type", "Details", "Auto keep", "Auto download",
            "Auto prepare", "Kept limit", "Remove ads", "Remove the show's own promotion",
            "Send this show for ad finding", "Default:", "Same as default",
        ] {
            XCTAssertTrue(text.contains(label), "Expected \(label) in \(text)")
        }
        for label in ["Auto keep", "Auto download", "Auto prepare", "Kept limit", "Remove ads"] {
            XCTAssertEqual(WiltedMacHeadless.occurrences(of: label, in: text), 1, "\(label) in \(text)")
        }
        XCTAssertFalse(text.contains("This show has no ads"), text)
        XCTAssertFalse(text.contains("Use global"), text)
    }

    func testRenderedSectionsHaveRowsInDefaultOrderForBothFeedKinds() throws {
        let headings = ["New episodes", "Playback", "Ads", "Type", "Details"]
        for isArticle in [false, true] {
            let fixture = try makeFixture(isArticle: isArticle)
            let lines = try renderedLines(fixture)
            let sections = lines.indices.filter { headings.contains(lines[$0]) }
            let expected = isArticle ? ["New episodes", "Type", "Details"] : ["New episodes", "Ads", "Type", "Details"]
            XCTAssertEqual(sections.map { lines[$0] }, expected)
            let rows = ["New episodes": "Auto keep", "Ads": "Remove ads",
                        "Type": isArticle ? "Articles" : "Podcast", "Details": "Source URL"]
            for (start, end) in zip(sections, sections.dropFirst() + [lines.endIndex]) {
                let row = try XCTUnwrap(rows[lines[start]])
                XCTAssertTrue(lines[(start + 1)..<end].contains { $0.contains(row) }, "Missing \(row) under \(lines[start])")
            }
        }
    }

    func testArticleSettingsShowNewsWithoutPodcastOnlyControls() async throws {
        let fixture = try makeFixture(isArticle: true)
        let text = try rendered(fixture)

        XCTAssertTrue(text.contains("News"), text)
        XCTAssertTrue(text.contains("Auto keep"), text)
        XCTAssertTrue(text.contains("Auto prepare"), text)
        XCTAssertTrue(text.contains("Kept limit"), text)
        for label in ["Auto download", "Remove ads", "Remove the show's own promotion", "Send this show for ad finding"] {
            XCTAssertFalse(text.contains(label), "\(label) in \(text)")
        }
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "News", in: text), 1, text)
    }

    func testExplicitChoiceEqualToGlobalDefaultStillCountsAndResetRestoresInheritance() throws {
        let fixture = try makeFixture(isArticle: false)
        let defaultAutoPrepare = fixture.board.model.automationSettings.feedAutomationDefaults.autoPrepare
        XCTAssertTrue(defaultAutoPrepare)
        XCTAssertEqual(fixture.board.explicitOverrideCount(for: fixture.feedID), 0)

        XCTAssertTrue(fixture.board.update(fixture.feedID, autoPrepare: .on))
        XCTAssertEqual(fixture.board.resolved(for: fixture.feedID).autoPrepare, defaultAutoPrepare)
        XCTAssertEqual(fixture.board.explicitOverrideCount(for: fixture.feedID), 1)

        fixture.board.reset(.autoPrepare, for: fixture.feedID)
        XCTAssertEqual(fixture.board.policy(for: fixture.feedID).autoPrepare, .useGlobal)
        XCTAssertEqual(fixture.board.explicitOverrideCount(for: fixture.feedID), 0)
    }

    func testResetAllReturnsShowSettingsToDefaultsAndRemovesAdFreeCustomValue() throws {
        let fixture = try makeFixture(isArticle: false)
        XCTAssertTrue(fixture.board.update(
            fixture.feedID, autoKeep: .on, autoDownload: .on, autoPrepare: .off, keptLimit: .explicit(3)
        ))
        XCTAssertTrue(fixture.board.setAdFree(true, for: fixture.feedID))
        XCTAssertTrue(fixture.board.setRemoveSelfPromotion(true, for: fixture.feedID))
        XCTAssertGreaterThan(fixture.board.explicitOverrideCount(for: fixture.feedID), 0)

        fixture.board.resetAllOverrides(for: fixture.feedID)

        XCTAssertEqual(fixture.board.policy(for: fixture.feedID), FeedAutomationPolicy())
        XCTAssertFalse(fixture.board.isAdFree(fixture.feedID))
        XCTAssertFalse(fixture.board.removesSelfPromotion(fixture.feedID))
        XCTAssertEqual(fixture.board.explicitOverrideCount(for: fixture.feedID), 0)
        let text = try rendered(fixture)
        XCTAssertFalse(text.contains("Off (Custom)"), text)
    }

    func testResettingRemoveAdsRevokesConsentBeforeRemovingAnAdFreeProtection() throws {
        let fixture = try makeFixture(isArticle: false, hasProviderKey: true)
        let labeller = AdLabellerPreferences(preferences: fixture.model.preferences)
        labeller.isEnabled = true
        XCTAssertTrue(fixture.board.setAdFree(true, for: fixture.feedID))
        XCTAssertTrue(fixture.board.setSendForAdFinding(true, for: fixture.feedID))
        XCTAssertEqual(fixture.model.automationSettings.removeAds, true)

        fixture.board.reset(.removeAds, for: fixture.feedID)

        XCTAssertFalse(fixture.board.isAdFree(fixture.feedID))
        XCTAssertFalse(fixture.board.sendsForAdFinding(fixture.feedID))
        XCTAssertEqual(fixture.board.adRoute(for: fixture.feedID), .notSent(.notConfirmed))
    }

    func testResettingRemoveAdsWithGlobalRemovalOffPreservesSeparateConsent() throws {
        let fixture = try makeFixture(isArticle: false, hasProviderKey: true)
        fixture.model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: settings.processingPolicy, transcriptPolicy: settings.transcriptPolicy,
                removeAds: false, autoAddPreparedToLarder: settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: settings.downloadEverythingOnLarder,
                prepareEverythingDownloaded: settings.prepareEverythingDownloaded,
                initialEpisodeMetadataCount: settings.initialEpisodeMetadataCount,
                autoKeepNewEpisodes: settings.autoKeepNewEpisodes, keptLimitPerFeed: settings.keptLimitPerFeed
            )
        }
        let labeller = AdLabellerPreferences(preferences: fixture.model.preferences)
        labeller.isEnabled = true
        XCTAssertTrue(fixture.board.setAdFree(true, for: fixture.feedID))
        XCTAssertTrue(fixture.board.setSendForAdFinding(true, for: fixture.feedID))

        fixture.board.reset(.removeAds, for: fixture.feedID)

        XCTAssertFalse(fixture.board.isAdFree(fixture.feedID))
        XCTAssertTrue(fixture.board.sendsForAdFinding(fixture.feedID))
        XCTAssertEqual(fixture.board.adRoute(for: fixture.feedID), .notSent(.adRemovalOff))
    }

    func testChoosingSameAsDefaultForRemoveAdsUsesTheSafeResetPath() throws {
        let fixture = try makeFixture(isArticle: false, hasProviderKey: true)
        let labeller = AdLabellerPreferences(preferences: fixture.model.preferences)
        labeller.isEnabled = true
        XCTAssertTrue(fixture.board.setAdFree(true, for: fixture.feedID))
        XCTAssertTrue(fixture.board.setSendForAdFinding(true, for: fixture.feedID))

        fixture.board.setRemoveAdsOverride(false, for: fixture.feedID)

        XCTAssertFalse(fixture.board.isAdFree(fixture.feedID))
        XCTAssertFalse(fixture.board.sendsForAdFinding(fixture.feedID))
        XCTAssertEqual(fixture.board.adRoute(for: fixture.feedID), .notSent(.notConfirmed))
    }

    private struct Fixture {
        let model: WiltedMacModel
        let board: WiltedMacFeedPolicyBoard
        let subscription: WiltedMacSubscription
        var feedID: String { subscription.id }
    }

    private func makeFixture(isArticle: Bool, hasProviderKey: Bool = false) throws -> Fixture {
        let feedURL = URL(string: isArticle ? "https://feeds.example.test/articles.xml" : "https://feeds.example.test/show.xml")!
        let feedID = try (isArticle
            ? ItemID.articleFeed(canonicalFeedURL: feedURL)
            : ItemID.derivePodcastFeed(from: feedURL)).rawValue
        let subscription = WiltedMacSubscription(
            id: feedID, title: isArticle ? "Article Feed" : "Settings Show", feedURL: feedURL,
            episodeCount: 0, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("show-settings"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.subscriptions = [subscription]
        let board = WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { hasProviderKey })
        board.loadForPreview(feedID: feedID, isArticleFeed: isArticle, isNews: false)
        return Fixture(model: model, board: board, subscription: subscription)
    }

    private func rendered(_ fixture: Fixture) throws -> String {
        try renderedLines(fixture).joined(separator: " ")
    }

    private func renderedLines(_ fixture: Fixture) throws -> [String] {
        let view = WiltedMacShowSettingsView(
            model: fixture.model, board: fixture.board, subscription: fixture.subscription
        )
        let bitmap = try WiltedMacHeadless.render(
            view.padding(24).background(Color.white), size: CGSize(width: 900, height: 2_200), scale: 2
        )
        let image = try XCTUnwrap(bitmap.cgImage)
        var lines: [(top: CGFloat, text: String)] = []
        // Overlap the crops so a heading crossing a boundary is still read in full.
        // Keep each line only in the band containing its midpoint.
        for start in stride(from: 0, to: image.height, by: 400) {
            let top = max(0, start - 60)
            let end = min(image.height, start + 460)
            let crop = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: end - top)))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.004
            request.customWords = ["Type"]
            try VNImageRequestHandler(cgImage: crop).perform([request])
            for observation in request.results ?? [] {
                let midpoint = CGFloat(top) + (1 - observation.boundingBox.midY) * CGFloat(crop.height)
                guard midpoint >= CGFloat(start), midpoint < CGFloat(start + 400),
                      let best = observation.topCandidates(3).first else { continue }
                let text = observation.topCandidates(3).contains {
                    $0.string.caseInsensitiveCompare("Type") == .orderedSame
                } ? "Type" : best.string
                lines.append((midpoint, text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return lines.sorted { $0.top < $1.top }.map { $0.text }
    }
}
