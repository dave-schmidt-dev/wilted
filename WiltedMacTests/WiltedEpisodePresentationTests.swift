import AppKit
import SwiftUI
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedEpisodePresentationTests: XCTestCase {
    func testAllShippingEpisodeSurfacesUseOneNumericPublicationAndDash() throws {
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        let value = episode(publishedAt: published, sourceDuration: 3723)
        let date = published.formatted(date: .numeric, time: .omitted)
        XCTAssertEqual(value.presentation.showAndPublicationLabel, "Canonical show - \(date)")
        XCTAssertEqual(value.presentation.playerSubtitleLabel, "Canonical show - \(date)")
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        model.installPlaybackStateForTesting(episode: value, isPlaying: false, position: 0, duration: 3723)
        let views: [(String, AnyView, CGSize)] = [
            ("feeds", AnyView(WiltedMacEpisodeMetadata(episode: value, identifier: "feeds")), CGSize(width: 600, height: 180)),
            ("off-list", AnyView(WiltedMacEpisodeMetadata(episode: value, lifecycleLabel: "Skipped", identifier: "off-list")), CGSize(width: 600, height: 180)),
            ("larder", AnyView(WiltedMacEpisodeMetadata(episode: value, identifier: "larder", isLarder: true)), CGSize(width: 600, height: 180)),
            ("notes", AnyView(WiltedMacEpisodeNotes(episode: value, prefix: "fixture") { EmptyView() }), CGSize(width: 460, height: 400)),
            ("side", AnyView(WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))), CGSize(width: 600, height: 800)),
            ("compact", AnyView(WiltedMacCompactPlayer(model: model)), CGSize(width: 800, height: 300)),
            ("full-player", AnyView(WiltedMacFullWindowPlayer(model: model, presentation: .constant(.transcript), onSelect: { _ in }, onCollapse: { _ in })), CGSize(width: 1100, height: 700)),
        ]
        for (name, view, size) in views {
            let text = try WiltedMacHeadless.recognizedText(view, size: size).joined(separator: " ")
            XCTAssertTrue(text.contains(date), "\(name): \(text)")
            for dark in [false, true] {
                let bitmap = try WiltedMacHeadless.render(view.environment(\.colorScheme, dark ? .dark : .light), size: size)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "formats-date-\(name)-\(dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        let unknown = episode(publishedAt: nil, sourceDuration: nil)
        XCTAssertEqual(unknown.presentation.playerSubtitleLabel, unknown.presentation.showAndPublicationLabel)
        XCTAssertTrue(unknown.presentation.playerSubtitleLabel.contains("Publication date unknown"))
    }

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
        let expectedLarder = "Canonical show - 1h 02m - \(publication.formatted(date: .numeric, time: .omitted))"
        XCTAssertEqual(original.presentation.larderRowLabel, expectedLarder)
        XCTAssertEqual(prepared.presentation.larderRowLabel, expectedLarder,
                       "Larder presentation retains total source duration (1h 02m), not playable duration (1h 00m)")
        XCTAssertEqual(original.presentation.larderPresentationLabel, expectedLarder)
    }

    func testUnknownPublicationAndMalformedDurationsRemainExplicitlyUnknown() {
        let unknown = episode(publishedAt: nil, sourceDuration: nil)
        XCTAssertEqual(unknown.presentation.showAndPublicationLabel, "Canonical show - Publication date unknown")
        XCTAssertEqual(unknown.presentation.sourceDurationLabel, "Source duration · Unknown")
        XCTAssertEqual(unknown.presentation.larderRowLabel, "Canonical show - Unknown - Publication date unknown")

        var malformed = unknown
        malformed.sourceDurationSeconds = .greatestFiniteMagnitude
        malformed.playableDurationSeconds = .greatestFiniteMagnitude
        malformed.downloadState = .completed
        malformed.preparationState = .prepared(summary: "Ready")
        XCTAssertEqual(malformed.presentation.sourceDurationLabel, "Source duration · Unknown")
        XCTAssertEqual(malformed.presentation.playableDurationLabel, "Playable duration · Unknown")
        XCTAssertEqual(malformed.presentation.larderRowLabel, "Canonical show - Unknown - Publication date unknown")
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
                       "Canonical show - Publication date unknown")
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
        XCTAssertEqual(tombstone.presentation.showAndPublicationLabel, "Show unknown - Publication date unknown")
        XCTAssertEqual(tombstone.presentation.sourceDurationLabel, "Source duration · Unknown")
        XCTAssertEqual(tombstone.presentation.larderRowLabel, "Show unknown - Unknown - Publication date unknown")

    }

    func testSharedMetadataAndPresentationOnlyOrderingHaveNativeContracts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let views = try WiltedMacSource.views(root: root)
        let metadata = try String(contentsOf: root.appendingPathComponent(
            "WiltedMac/Views/WiltedMacEpisodeMetadata.swift"), encoding: .utf8
        )
        let sections = try String(contentsOf: root.appendingPathComponent(
            "WiltedMac/Views/WiltedMacLarderView+Sections.swift"), encoding: .utf8
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
        XCTAssertTrue(metadata.contains("larderRowLabel"))
        XCTAssertTrue(metadata.contains("duration < Double(Int.max)"))
        XCTAssertTrue(views.contains("wilted-feeds-metadata-\\(episode.id)"))
        XCTAssertTrue(views.contains("wilted-larder-metadata-\\(episode.id)"))
        XCTAssertTrue(views.contains("identifier.replacingOccurrences(of: \"restore\", with: \"metadata\")"))
        XCTAssertTrue(views.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(views.contains(".buttonStyle(.bordered)"))
        XCTAssertTrue(sections.contains("WiltedMacEpisodePresentationSections.displaySections"))
        XCTAssertTrue(sections.contains("Unknown publication date"))
        XCTAssertTrue(sections.contains("automatic download setting"))
        XCTAssertTrue(sections.contains("emptyDownloadedCopy"))
        XCTAssertTrue(sections.contains("downloadEverythingOnLarder"))
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
        let source = [WiltedMacLarderSection(
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
            [WiltedMacLarderSection(
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
        let source = [WiltedMacLarderSection(
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
        let source = [WiltedMacLarderSection(
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

    func testLarderPresentationRowFieldsOrderUnknownsAndSourceDuration() {
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        let publishedDateString = published.formatted(date: .numeric, time: .omitted)

        // Fields in order: Feed - duration - date, separated by literal " - "
        var ep = episode(publishedAt: published, sourceDuration: 3_723)
        ep.playableDurationSeconds = 1_800
        XCTAssertEqual(
            ep.presentation.larderRowLabel,
            "Canonical show - 1h 02m - \(publishedDateString)",
            "Larder row must present feed, total source duration, and date in that order, ignoring playable duration"
        )

        // Explicit unknowns for missing show, duration, and publication date
        let emptyShow = WiltedMacEpisode(
            id: "no-show", title: "No Show", feedTitle: "   ", summary: "",
            artworkURL: nil, releasedAt: published, publishedAt: nil,
            sourceDurationSeconds: nil, durationSeconds: nil,
            playbackSeconds: 0, downloadState: .notDownloaded
        )
        XCTAssertEqual(
            emptyShow.presentation.larderRowLabel,
            "Show unknown - Unknown - Publication date unknown"
        )
    }

    func testVisibleNumberingRestartsAfterRemovingTheFirstSevenRows() {
        let queue = (1...10).map { episode(id: "episode-\($0)", publishedAt: nil, sourceDuration: 60) }
        func sections(_ rows: [WiltedMacEpisode]) -> [WiltedMacLarderSection] {
            [WiltedMacLarderSection(id: "visible", title: "Larder", detail: nil, statusGroup: nil, episodes: rows)]
        }
        let initial = WiltedMacEpisodePresentationSections.visibleNumbering(sections(queue))
        XCTAssertEqual(initial.count, 10)
        XCTAssertEqual(queue.map { initial.positions[$0.id] }, (1...10).map(Optional.some))

        let remaining = Array(queue.dropFirst(7))
        let numbered = WiltedMacEpisodePresentationSections.visibleNumbering(sections(remaining))
        XCTAssertEqual(numbered.count, 3)
        XCTAssertEqual(numbered.positions, ["episode-8": 1, "episode-9": 2, "episode-10": 3])
        XCTAssertEqual(queue.map(\.id), (1...10).map { "episode-\($0)" }, "numbering must not rewrite the queue")
    }

    func testVisibleNumberingUsesTheFilteredSubsetAndItsVisibleCount() {
        let queue = (1...10).map { episode(id: "episode-\($0)", publishedAt: nil, sourceDuration: 60) }
        let filtered = [queue[7], queue[9]]
        let section = WiltedMacLarderSection(id: "filtered", title: "Matches", detail: nil, statusGroup: nil, episodes: filtered)
        let numbered = WiltedMacEpisodePresentationSections.visibleNumbering([section])
        XCTAssertEqual(numbered.positions, ["episode-8": 1, "episode-10": 2])
        XCTAssertEqual(numbered.count, 2, "VoiceOver's X of Y must count only rendered rows")
        XCTAssertEqual(section.episodes.map(\.id), ["episode-8", "episode-10"])
        XCTAssertEqual(WiltedMacEpisodePresentationSections.visibleNumbering([]).count, 0)
    }

    func testVisibleNumberingContinuesAcrossSectionsAfterActiveWorkMovesFirst() {
        let first = episode(id: "first", publishedAt: nil, sourceDuration: 60)
        let last = episode(id: "last", publishedAt: nil, sourceDuration: 60)
        var active = episode(id: "active", publishedAt: nil, sourceDuration: 60)
        active.downloadState = .downloading(received: 30, expected: 60)
        let source = [
            WiltedMacLarderSection(id: "feed-a", title: "A", detail: nil, statusGroup: nil, episodes: [first]),
            WiltedMacLarderSection(id: "feed-b", title: "B", detail: nil, statusGroup: nil, episodes: [last, active]),
        ]
        let displayed = WiltedMacEpisodePresentationSections.displaySections(source, grouping: .feed)
        XCTAssertEqual(displayed.map(\.id), ["active-work", "feed-a", "feed-b"])
        let numbered = WiltedMacEpisodePresentationSections.visibleNumbering(displayed)
        XCTAssertEqual(numbered.positions, ["active": 1, "first": 2, "last": 3])
        XCTAssertEqual(numbered.count, 3)
        XCTAssertEqual(displayed.flatMap(\.episodes).map(\.id), ["active", "first", "last"])
        XCTAssertEqual(source.flatMap(\.episodes).map(\.id), ["first", "last", "active"])
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
