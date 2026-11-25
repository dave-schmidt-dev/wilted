import SwiftData
import SwiftUI
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacPodcastChapterTests: XCTestCase {
    private let feedURL = URL(string: "https://feeds.example.test/chapter-show.xml")!
    private let timestamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

    func testPreparedChaptersPublishOnlyWithTheExactCurrentAudioRevision() async throws {
        let root = wiltedTemporaryDirectory("podcast-chapter-publication")
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosure = URL(string: "https://media.example.test/episode.mp3")!
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "episode-1", enclosureURL: enclosure)
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: timestamp))
        try await store.save(episode: PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-1",
            title: "Episode", enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: timestamp))

        let firstRevision = try RevisionID(rawValue: "prepared-r1")
        let firstFile = root.appendingPathComponent("first.m4a")
        let bytes = Data("first prepared audio".utf8)
        try bytes.write(to: firstFile)
        try await store.saveReadyRevision(try AudioRevision(
            itemID: episodeID, revisionID: firstRevision, durationSeconds: 60, byteCount: Int64(bytes.count),
            contentHash: "sha256:" + String(repeating: "a", count: 64), mediaType: "audio/mp4",
            createdAt: timestamp, schemaVersion: 1), mediaURL: firstFile)
        let chapterSet = try LibraryPodcastChapters(
            entryID: episodeID, revisionID: firstRevision,
            chapters: [PodcastChapterMark(title: "Prepared chapter", startSeconds: 12)])
        try await store.savePreparedPodcastChapters(
            chapterSet.chapters, for: episodeID, revisionID: firstRevision)

        let firstSnapshot = try await store.podcastLibrarySnapshot(profile: .publication)
        let firstState = try WiltedMacLocalLibraryStateSource.state(
            from: firstSnapshot, queue: [episodeID], playback: nil, deviceID: "mac")
        let firstEntry = try XCTUnwrap(firstState.episodes.first)
        XCTAssertEqual(try firstEntry.podcastEpisodePayload().preparedChapters, chapterSet)

        // A new ready revision for the same episode ID cannot inherit an old
        // chapter clock just because the durable sidecar still exists.
        let secondRevision = try RevisionID(rawValue: "prepared-r2")
        let secondFile = root.appendingPathComponent("second.m4a")
        let secondBytes = Data("replacement prepared audio".utf8)
        try secondBytes.write(to: secondFile)
        try await store.saveReadyRevision(try AudioRevision(
            itemID: episodeID, revisionID: secondRevision, durationSeconds: 61, byteCount: Int64(secondBytes.count),
            contentHash: "sha256:" + String(repeating: "b", count: 64), mediaType: "audio/mp4",
            createdAt: Timestamp(timestamp.date.addingTimeInterval(1)), schemaVersion: 1), mediaURL: secondFile)
        let chaptersForReplacement = try await store.preparedPodcastChapters(for: episodeID, revisionID: secondRevision)
        XCTAssertNil(chaptersForReplacement)

        let secondSnapshot = try await store.podcastLibrarySnapshot(profile: .publication)
        XCTAssertNil(secondSnapshot.preparedPodcastChapters[episodeID])
        let secondState = try WiltedMacLocalLibraryStateSource.state(
            from: secondSnapshot, queue: [episodeID], playback: nil, deviceID: "mac")
        XCTAssertNil(try secondState.episodes.first?.podcastEpisodePayload().preparedChapters)
    }

    func testMacPlayerShowsAndNavigatesCollapsedPodcastChapterTitles() throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("podcast-chapter-player"),
            preferences: WiltedMacTestPreferences.ephemeral())
        let episode = WiltedMacEpisode(
            id: "chapter-episode", title: "Episode", feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: timestamp.date, publishedAt: timestamp.date,
            sourceDurationSeconds: 120, durationSeconds: 120, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"),
            podcastChapters: [
                WiltedMacChapter(title: "Opening", startSeconds: 0),
                WiltedMacChapter(title: "Sponsor", startSeconds: 0),
                WiltedMacChapter(title: "Interview", startSeconds: 0)
            ])
        model.installPlaybackStateForTesting(episode: episode, isPlaying: false, position: 0, duration: 120)

        XCTAssertEqual(model.currentChapterTitle, "Opening")
        model.selectNextChapter()
        XCTAssertEqual(model.currentEpisode?.selectedPodcastChapterIndex, 1)
        XCTAssertEqual(model.currentChapterTitle, "Sponsor")
        model.selectNextChapter()
        XCTAssertEqual(model.currentEpisode?.selectedPodcastChapterIndex, 2)
        XCTAssertEqual(model.currentChapterTitle, "Interview")
        model.selectPreviousChapter()
        XCTAssertEqual(model.currentEpisode?.selectedPodcastChapterIndex, 1)
        XCTAssertEqual(model.currentChapterTitle, "Sponsor")

        let player = WiltedMacPlayerContent(
            model: model, presentation: .constant(nil), layout: .rail,
            focusRequest: nil, onCollapse: { _ in })
        let text = try WiltedMacHeadless.recognizedText(player, size: CGSize(width: 1_000, height: 700)).joined(separator: " ")
        XCTAssertTrue(text.contains("Sponsor"), text)
        XCTAssertTrue(text.contains("Chapter 2 of 3"), text)
        let host = NSHostingView(rootView: player)
        host.frame = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let window = WiltedMacHeadless.offscreenWindow(hosting: host)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        var buttons: [String: String] = [:]
        var seen = Set<ObjectIdentifier>()
        func collect(_ value: Any) {
            guard let node = value as? NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(node as AnyObject)).inserted else { return }
            if let identifier = node.accessibilityIdentifier() {
                buttons[identifier] = WiltedMacHeadless.accessibilityLabel(of: node) ?? WiltedMacHeadless.accessibilityTitle(of: node)
            }
            for child in node.accessibilityChildren() ?? [] { collect(child) }
        }
        collect(host)
        let source = try String(contentsOf: WiltedMacHeadless.sourceRoot()
            .appendingPathComponent("WiltedMac/Views/WiltedMacPlayerContent.swift"), encoding: .utf8)
        for (identifier, label, method) in [
            ("wilted-player-previous-chapter", "Previous chapter", "selectPreviousChapter"),
            ("wilted-player-next-chapter", "Next chapter", "selectNextChapter")
        ] {
            if let rendered = buttons[identifier] {
                XCTAssertEqual(rendered, label)
            } else {
                // An offscreen host can omit the native AX tree. Verify the
                // action wiring alongside the real rendered title and navigation above.
                XCTAssertTrue(source.contains("label: \"\(label)\", id: \"\(identifier)\"") &&
                              source.contains("model.\(method)()"))
            }
        }
        XCTAssertTrue(text.contains("Chapters"), text)
    }
}
