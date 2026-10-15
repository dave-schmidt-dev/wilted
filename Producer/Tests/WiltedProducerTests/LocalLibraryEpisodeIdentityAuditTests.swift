import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// The identity audit on a synthetic three-ID fixture: a duplicate source ID,
/// two distinct GUID twins whose metadata matches, and a feed-URL move
/// candidate. The test proves the audit reports without writing and redacts by
/// default.
final class LocalLibraryEpisodeIdentityAuditTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let feedURL = URL(string: "https://podcasts.example.test/audit/feed.xml")!
    private let movedFeedURL = URL(string: "https://podcasts.example.test/audit-moved/feed.xml")!
    private let sharedHash = "sha256:" + String(repeating: "a", count: 64)

    private func makeURL(_ name: String = #function) -> URL {
        OwnedTestTemp.root
            .appendingPathComponent("wilted-audit-\(name)-\(UUID().uuidString)")
            .appendingPathComponent("library.sqlite")
    }

    private func episode(
        feedURL: URL, guid: String, link: String?
    ) throws -> PodcastEpisode {
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosureURL = URL(string: "https://cdn.example.test/audit/\(guid).mp3")!
        return try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL),
            feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Shared Episode",
            publishedTime: Timestamp(origin), enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg", durationSeconds: 3_600,
            episodeLink: link.flatMap(URL.init(string:)), createdAt: Timestamp(origin)
        )
    }

    private func completedDownload(for episodeID: ItemID, path: String) throws -> PodcastDownload {
        try PodcastDownload(
            episodeID: episodeID, status: .completed, bytesReceived: 1_024, expectedByteCount: 1_024,
            localURL: URL(fileURLWithPath: path), contentHash: sharedHash, updatedAt: Timestamp(origin)
        )
    }

    private func playback(
        for episodeID: ItemID, revision: String, completed: Bool, position: Double, at second: TimeInterval
    ) throws -> PlaybackState {
        try PlaybackState(
            itemID: episodeID, revisionID: RevisionID(rawValue: revision), sessionID: "session-1",
            sequence: 1, positionSeconds: position, durationSeconds: 3_600, completed: completed,
            intent: .progress, deviceID: "device-1", updatedAt: Timestamp(origin.addingTimeInterval(second))
        )
    }

    private func episodesByID(
        _ snapshot: LocalLibraryStore.PodcastLibrarySnapshot
    ) -> [ItemID: PodcastEpisode] {
        Dictionary(uniqueKeysWithValues: snapshot.episodes.map { ($0.itemID, $0) })
    }

    func testAuditReportsProofGapsAndConflictsWithoutWritingAndRedactsByDefault() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)

        let first = try episode(feedURL: feedURL, guid: "guid-a", link: "https://show.example.test/episodes/shared")
        let twin = try episode(feedURL: feedURL, guid: "guid-b", link: nil)
        let moved = try episode(feedURL: movedFeedURL, guid: "guid-a", link: nil)
        for value in [first, twin, moved] { try await store.save(episode: value) }

        try await store.save(download: completedDownload(for: first.itemID, path: "/tmp/audit-first.mp3"))
        try await store.save(download: completedDownload(for: moved.itemID, path: "/tmp/audit-moved.mp3"))
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: first.itemID, decision: .keep, source: .manual, decidedAt: Timestamp(origin)
        ))
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: twin.itemID, decision: .skip, source: .rule, ruleID: UUID(),
            decidedAt: Timestamp(origin.addingTimeInterval(10))
        ))
        try await store.save(playback: try playback(
            for: first.itemID, revision: "rev-audit-first", completed: false, position: 60, at: 20
        ))
        // Listening says completed while the checkpoint says otherwise: the
        // conflict the audit must surface.
        try await store.save(
            playback: try playback(for: twin.itemID, revision: "rev-audit-twin", completed: false, position: 120, at: 30),
            listening: PodcastListeningState(
                episodeID: twin.itemID, completedAt: Timestamp(origin.addingTimeInterval(40)),
                lastRevisionID: nil, updatedAt: Timestamp(origin.addingTimeInterval(40))
            )
        )

        let before = try await store.podcastLibrarySnapshot()
        let report = try await store.podcastEpisodeIdentityAudit(
            targetedAt: [first.itemID, twin.itemID, moved.itemID, first.itemID]
        )
        let after = try await store.podcastLibrarySnapshot()

        // The audit writes nothing: every store dimension is unchanged.
        XCTAssertEqual(episodesByID(before), episodesByID(after))
        XCTAssertEqual(before.downloads, after.downloads)
        XCTAssertEqual(before.episodeDecisions, after.episodeDecisions)
        XCTAssertEqual(before.listeningStates, after.listeningStates)
        XCTAssertEqual(before.playbackStates, after.playbackStates)
        XCTAssertEqual(before.retiredAtByEpisode, after.retiredAtByEpisode)
        XCTAssertEqual(before.removalKindByEpisode, after.removalKindByEpisode)
        XCTAssertEqual(before.readyRevisions, after.readyRevisions)
        XCTAssertEqual(before.podcastQueue, after.podcastQueue)
        XCTAssertEqual(before.preparationRuns, after.preparationRuns)

        XCTAssertTrue(report.redactedIdentifyingValues)
        XCTAssertEqual(report.targetedEpisodeCount, 3)
        XCTAssertEqual(report.repeatedSourceIDCount, 1)
        XCTAssertEqual(report.unmatchedCount, 0)
        XCTAssertEqual(report.entries.count, 3)

        let firstEntry = report.entries[0]
        let twinEntry = report.entries[1]
        let movedEntry = report.entries[2]
        XCTAssertTrue(firstEntry.classifications.contains(.repeatedSourceID))
        XCTAssertTrue(firstEntry.classifications.contains(.feedURLMoveCandidate))
        XCTAssertTrue(twinEntry.classifications.contains(.metadataLookalikeCandidate))
        XCTAssertTrue(twinEntry.classifications.contains(.conflictingEvidence))
        XCTAssertTrue(movedEntry.classifications.contains(.feedURLMoveCandidate))

        XCTAssertEqual(twinEntry.conflicts, [.completionDisagreesWithPlayback])
        XCTAssertTrue(firstEntry.conflicts.contains(.sharedOriginalMedia))
        XCTAssertTrue(movedEntry.conflicts.contains(.sharedOriginalMedia))

        XCTAssertTrue(firstEntry.proofGaps.isEmpty)
        XCTAssertEqual(Set(twinEntry.proofGaps), [.publisherPage, .originalMedia])
        XCTAssertEqual(Set(movedEntry.proofGaps), [.publisherPage, .ownerDecision, .progress])

        XCTAssertEqual(firstEntry.chronology.map(\.kind), [.keep])
        XCTAssertEqual(twinEntry.chronology.map(\.kind), [.skip, .completed])
        XCTAssertEqual(twinEntry.chronology.first?.source, .rule)
        XCTAssertTrue(movedEntry.chronology.isEmpty)

        // The default report carries no raw identifying value anywhere,
        // including in its textual form.
        for entry in report.entries {
            XCTAssertNil(entry.episodeID)
            XCTAssertNil(entry.feedID)
            XCTAssertNil(entry.rssGUID)
            XCTAssertNil(entry.publisherPageURL)
            XCTAssertNil(entry.originalMediaContentHash)
        }
        let description = String(describing: report)
        XCTAssertFalse(description.contains("guid-a"))
        XCTAssertFalse(description.contains("Shared Episode"))
        XCTAssertFalse(description.contains("show.example.test"))

        // The pure snapshot form audits the captured clone identically.
        let fromSnapshot = LocalLibraryStore.podcastEpisodeIdentityAudit(
            targetedAt: [first.itemID, twin.itemID, moved.itemID, first.itemID], in: before
        )
        XCTAssertEqual(fromSnapshot, report)

        // Raw IDs and publisher evidence are available only when the captain
        // explicitly asks for them.
        let revealed = try await store.podcastEpisodeIdentityAudit(
            targetedAt: [first.itemID], redactingIdentifyingValues: false
        )
        XCTAssertEqual(revealed.entries.first?.episodeID, first.itemID)
        XCTAssertEqual(revealed.entries.first?.feedID, first.feedID)
        XCTAssertEqual(revealed.entries.first?.rssGUID, "guid-a")
        XCTAssertEqual(revealed.entries.first?.publisherPageURL?.absoluteString,
                       "https://show.example.test/episodes/shared")
        XCTAssertEqual(revealed.entries.first?.originalMediaContentHash, sharedHash)
    }

    func testAuditReportsUnmatchedTargets() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let unknown = try ItemID(rawValue: "item-" + String(repeating: "f", count: 64))

        let report = try await store.podcastEpisodeIdentityAudit(targetedAt: [unknown, unknown])
        XCTAssertEqual(report.targetedEpisodeCount, 1)
        XCTAssertEqual(report.repeatedSourceIDCount, 1)
        XCTAssertEqual(report.unmatchedCount, 1)
        XCTAssertEqual(report.entries.first?.matched, false)
        XCTAssertTrue(report.entries.first?.classifications.contains(.unmatchedTarget) == true)
        XCTAssertNil(report.entries.first?.episodeID, "unmatched targets redact their ID too")
    }
}
