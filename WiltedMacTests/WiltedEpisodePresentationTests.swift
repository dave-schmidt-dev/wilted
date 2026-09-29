import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedEpisodePresentationTests: XCTestCase {
    func testCanonicalFactsStayStableAcrossDecisionAndPreparationStates() {
        let publication = Date(timeIntervalSince1970: 1_700_000_000)
        let original = episode(publishedAt: publication, sourceDuration: 3_723)
        var kept = original
        kept.downloadState = .queued
        var downloaded = original
        downloaded.downloadState = .completed
        var prepared = downloaded
        prepared.preparationState = .prepared(summary: "Ready")
        prepared.playableDurationSeconds = 3_610

        for value in [original, kept, downloaded, prepared] {
            XCTAssertEqual(value.presentation.title, "Canonical episode")
            XCTAssertEqual(value.presentation.showTitle, "Canonical show")
            XCTAssertEqual(value.presentation.publishedAt, publication)
            XCTAssertEqual(value.presentation.sourceDurationSeconds, 3_723)
        }
        XCTAssertNil(original.presentation.playableDurationSeconds)
        XCTAssertNil(downloaded.presentation.playableDurationSeconds)
        XCTAssertEqual(prepared.presentation.playableDurationSeconds, 3_610)
        XCTAssertEqual(prepared.presentation.sourceDurationLabel, "Source duration · 1h 02m")
        XCTAssertEqual(prepared.presentation.playableDurationLabel, "Playable duration · 1h 00m")
        XCTAssertEqual(original.presentation.accessibilityFactsLabel, prepared.presentation.accessibilityFactsLabel)
    }

    func testUnknownPublicationAndMalformedDurationsRemainExplicitlyUnknown() {
        let unknown = episode(publishedAt: nil, sourceDuration: nil)
        XCTAssertEqual(unknown.presentation.showAndPublicationLabel, "Canonical show · Publication date unknown")
        XCTAssertEqual(unknown.presentation.sourceDurationLabel, "Source duration · Unknown")

        var malformed = unknown
        malformed.sourceDurationSeconds = .greatestFiniteMagnitude
        malformed.playableDurationSeconds = .greatestFiniteMagnitude
        malformed.downloadState = .completed
        malformed.preparationState = .prepared(summary: "Ready")
        XCTAssertEqual(malformed.presentation.sourceDurationLabel, "Source duration · Unknown")
        XCTAssertEqual(malformed.presentation.playableDurationLabel, "Playable duration · Unknown")
    }

    func testLegacyConstructorRetainsItsKnownFixtureFacts() {
        let releasedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = WiltedMacEpisode(
            id: "legacy", title: "Fixture", feedTitle: "Fixture show", summary: "",
            artworkURL: nil, releasedAt: releasedAt, durationSeconds: 120,
            playbackSeconds: 0, downloadState: .notDownloaded
        )
        XCTAssertEqual(legacy.publishedAt, releasedAt)
        XCTAssertEqual(legacy.sourceDurationSeconds, 120)
        XCTAssertNil(legacy.presentation.playableDurationSeconds)
    }

    func testMissingReadyMediaNeverPresentsAPlayableDuration() {
        var prepared = episode(publishedAt: Date(timeIntervalSince1970: 1_700_000_000), sourceDuration: 90)
        prepared.downloadState = .completed
        prepared.preparationState = .prepared(summary: "Ready")
        prepared.playableDurationSeconds = 75
        prepared.isReadyMediaAvailable = false

        XCTAssertEqual(prepared.presentation.sourceDurationSeconds, 90)
        XCTAssertNil(prepared.presentation.playableDurationSeconds)
        XCTAssertNil(prepared.presentation.playableDurationLabel)
    }

    func testDismissedProjectionJoinsFactualEpisodeMetadataAndKeepsTombstoneUnknown() async throws {
        let directory = wiltedTemporaryDirectory("episode-presentation")
        let modelDirectory = wiltedTemporaryDirectory("episode-presentation-model")
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: modelDirectory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }

        let created = Timestamp(Date(timeIntervalSince1970: 1_699_000_000))
        let published = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/canonical.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/canonical.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "canonical", enclosureURL: enclosureURL
        )
        try await store.save(feed: PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Canonical show", createdAt: created
        ))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
        try await store.save(episode: PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "canonical",
            title: "Canonical episode", publishedTime: published, enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg", durationSeconds: 600, createdAt: created
        ))
        let unknownEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/unknown.mp3"))
        let unknownID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "unknown", enclosureURL: unknownEnclosure
        )
        try await store.save(episode: PodcastEpisode(
            itemID: unknownID, feedID: feedID, feedURL: feedURL, rssGUID: "unknown",
            title: "Unknown source episode", enclosureURL: unknownEnclosure,
            enclosureMediaType: "audio/mpeg", createdAt: created
        ))
        let liveRows = try await model.loadLibrary(from: store)
        let live = try XCTUnwrap(liveRows.episodes.first { $0.id == episodeID.rawValue })
        XCTAssertEqual(live.publishedAt, published.date)
        XCTAssertEqual(live.sourceDurationSeconds, 600)
        XCTAssertNil(live.presentation.playableDurationSeconds)
        let unknownLive = try XCTUnwrap(liveRows.episodes.first { $0.id == unknownID.rawValue })
        XCTAssertNil(unknownLive.publishedAt)
        XCTAssertNil(unknownLive.sourceDurationSeconds)
        XCTAssertEqual(unknownLive.presentation.showAndPublicationLabel,
                       "Canonical show · Publication date unknown")
        try await store.dismissPodcastEpisode(episodeID, at: Timestamp(Date(timeIntervalSince1970: 1_701_000_000)))
        try await store.dismissPodcastEpisode(unknownID, at: Timestamp(Date(timeIntervalSince1970: 1_701_500_000)))

        let tombstoneID = try ItemID.derive(from: URL(string: "https://example.test/dismissed-tombstone")!)
        try await store.dismissPodcastEpisode(tombstoneID, at: Timestamp(Date(timeIntervalSince1970: 1_702_000_000)))

        let rows = try await model.loadDismissedEpisodes(from: store)
        let factual = try XCTUnwrap(rows.first { $0.id == episodeID.rawValue })
        XCTAssertEqual(factual.presentation.showTitle, "Canonical show")
        XCTAssertEqual(factual.presentation.publishedAt, published.date)
        XCTAssertEqual(factual.presentation.sourceDurationSeconds, 600)
        XCTAssertNil(factual.presentation.playableDurationSeconds)

        let knownFeedUnknownFacts = try XCTUnwrap(rows.first { $0.id == unknownID.rawValue })
        XCTAssertEqual(knownFeedUnknownFacts.presentation.showTitle, "Canonical show")
        XCTAssertNil(knownFeedUnknownFacts.presentation.publishedAt)
        XCTAssertNil(knownFeedUnknownFacts.presentation.sourceDurationSeconds)

        let tombstone = try XCTUnwrap(rows.first { $0.id == tombstoneID.rawValue })
        XCTAssertNil(tombstone.presentation.publishedAt)
        XCTAssertNil(tombstone.presentation.sourceDurationSeconds)
        XCTAssertEqual(tombstone.presentation.showAndPublicationLabel, "Show unknown · Publication date unknown")
        XCTAssertEqual(tombstone.presentation.sourceDurationLabel, "Source duration · Unknown")

    }

    func testSharedMetadataAndPresentationOnlyOrderingHaveNativeContracts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let views = try WiltedMacSource.views(root: root)
        let metadata = try String(contentsOf: root.appendingPathComponent(
            "WiltedMac/Views/WiltedMacEpisodeMetadata.swift"), encoding: .utf8
        )
        let sections = try String(contentsOf: root.appendingPathComponent(
            "WiltedMac/Views/WiltedMacMenuView+Sections.swift"), encoding: .utf8
        )
        let feeds = try String(contentsOf: root.appendingPathComponent(
            "WiltedMac/Views/WiltedMacFeedsView.swift"), encoding: .utf8
        )
        let libraryLoading = try String(contentsOf: root.appendingPathComponent(
            "WiltedMac/ViewModel/WiltedMacModel+LibraryLoading.swift"), encoding: .utf8
        )
        XCTAssertTrue(metadata.contains("struct WiltedMacEpisodePresentation"))
        XCTAssertTrue(metadata.contains("Publication date unknown"))
        XCTAssertTrue(metadata.contains("accessibilityFactsLabel"))
        XCTAssertTrue(metadata.contains("duration < Double(Int.max)"))
        XCTAssertTrue(views.contains("wilted-feeds-metadata-\\(episode.id)"))
        XCTAssertTrue(views.contains("wilted-menu-metadata-\\(episode.id)"))
        XCTAssertTrue(views.contains("identifier.replacingOccurrences(of: \"restore\", with: \"metadata\")"))
        XCTAssertTrue(views.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(views.contains(".buttonStyle(.bordered)"))
        XCTAssertTrue(sections.contains("WiltedMacEpisodePresentationSections.displaySections"))
        XCTAssertTrue(sections.contains("Unknown publication date"))
        XCTAssertTrue(sections.contains("automatic download setting"))
        XCTAssertTrue(sections.contains("emptyDownloadedCopy"))
        XCTAssertTrue(sections.contains("downloadEverythingOnMenu"))
        XCTAssertTrue(libraryLoading.contains("feedTitle: dismissal.feedID.flatMap { feeds[$0]?.title }"))
        let feedsManagement = try XCTUnwrap(feeds.range(of: "feedManagement")?.lowerBound)
        let offList = try XCTUnwrap(feeds.range(of: "restorableEpisodes", range: feedsManagement..<feeds.endIndex)?.lowerBound)
        XCTAssertLessThan(feedsManagement, offList)
    }

    func testPresentationSectionsLiftOnlyActiveRowsAndLeaveDeferredRowsInPlace() {
        var downloading = episode(id: "downloading", publishedAt: nil, sourceDuration: 60)
        downloading.downloadState = .downloading(received: 30, expected: 60)
        var deferred = episode(id: "deferred", publishedAt: nil, sourceDuration: 60)
        deferred.downloadState = .completed
        deferred.preparationState = .preparing(stage: "Queued")
        let idle = episode(id: "idle", publishedAt: nil, sourceDuration: 60)
        let source = [WiltedMacMenuSection(
            id: "status-available", title: "Not downloaded", detail: nil, statusGroup: .available,
            episodes: [idle, downloading, deferred]
        )]

        let result = WiltedMacEpisodePresentationSections.displaySections(
            source, grouping: .status, isDeferredForOffPeak: { $0 == "deferred" }
        )
        XCTAssertEqual(result.first?.id, "active-work")
        XCTAssertEqual(result.first?.episodes.map(\.id), ["downloading"])
        XCTAssertEqual(result.dropFirst().flatMap(\.episodes).map(\.id), ["idle", "deferred"])
        XCTAssertEqual(source.flatMap(\.episodes).map(\.id), ["idle", "downloading", "deferred"],
                       "presentation grouping cannot rewrite the durable source order")
    }

    func testDatePresentationUsesFactualDatesAndPlacesUnknownRowsLast() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        let known = episode(id: "known", publishedAt: published, sourceDuration: 60)
        let unknown = episode(id: "unknown", publishedAt: nil, sourceDuration: 60)
        let result = WiltedMacEpisodePresentationSections.displaySections(
            [WiltedMacMenuSection(
                id: "legacy-fallback", title: "Today", detail: nil, statusGroup: nil,
                episodes: [unknown, known]
            )],
            grouping: .date, calendar: calendar, now: now
        )

        XCTAssertEqual(result.last?.id, "publication-date-unknown")
        XCTAssertEqual(result.last?.title, "Unknown publication date")
        XCTAssertEqual(result.last?.episodes.map(\.id), ["unknown"])
        XCTAssertEqual(result.dropLast().flatMap(\.episodes).map(\.id), ["known"])
    }

    func testNewestPresentationPlacesUnknownFactsLastWithoutChangingCustomOrder() {
        let known = episode(id: "known", publishedAt: Date(timeIntervalSince1970: 1_700_000_000), sourceDuration: 60)
        let unknown = episode(id: "unknown", publishedAt: nil, sourceDuration: 60)
        let source = [WiltedMacMenuSection(
            id: "status-available", title: "Not downloaded", detail: nil, statusGroup: .available,
            episodes: [unknown, known]
        )]

        let custom = WiltedMacEpisodePresentationSections.displaySections(
            source, grouping: .status, sort: .custom
        )
        let newest = WiltedMacEpisodePresentationSections.displaySections(
            source, grouping: .status, sort: .newest
        )

        XCTAssertEqual(custom.first?.episodes.map(\.id), ["unknown", "known"])
        XCTAssertEqual(newest.first?.episodes.map(\.id), ["known", "unknown"])
        XCTAssertEqual(source.first?.episodes.map(\.id), ["unknown", "known"])
    }

    func testNewestPresentationKeepsMultipleKnownDatesAheadOfUnknownFacts() {
        let oldest = episode(id: "oldest", publishedAt: Date(timeIntervalSince1970: 1_700_000_000), sourceDuration: 60)
        let middle = episode(id: "middle", publishedAt: Date(timeIntervalSince1970: 1_700_010_000), sourceDuration: 60)
        let newest = episode(id: "newest", publishedAt: Date(timeIntervalSince1970: 1_700_020_000), sourceDuration: 60)
        let unknown = episode(id: "unknown", publishedAt: nil, sourceDuration: 60)
        let source = [WiltedMacMenuSection(
            id: "status-available", title: "Not downloaded", detail: nil, statusGroup: .available,
            episodes: [newest, unknown, middle, oldest]
        )]

        XCTAssertEqual(
            WiltedMacEpisodePresentationSections.displaySections(source, grouping: .status, sort: .newest)
                .flatMap(\.episodes)
                .map(\.id),
            [newest.id, middle.id, oldest.id, unknown.id]
        )
    }

    private func episode(
        id: String = "canonical", publishedAt: Date?, sourceDuration: TimeInterval?
    ) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: "Canonical episode", feedTitle: "Canonical show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_699_000_000),
            publishedAt: publishedAt, sourceDurationSeconds: sourceDuration, durationSeconds: sourceDuration,
            playbackSeconds: 0, downloadState: .notDownloaded
        )
    }
}
