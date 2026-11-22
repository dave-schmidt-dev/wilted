import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// A Skip that offers Undo keeps the audio until the window closes, and Undo gives back exactly what
/// was there without ever overriding something newer.
final class LocalLibrarySoftSkipTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private let skippedAt = Timestamp(Date(timeIntervalSince1970: 1_760_000_100))

    // MARK: - Skip and Undo

    func testSoftSkipKeepsAudioAndPositionAndUndoGivesBackTheEpisodeWhole() async throws {
        let fixture = try await makeFixture(count: 1)
        let id = fixture.ids[0]
        try insertPlayback(fixture, id, positionSeconds: 42)

        let result = try await fixture.store.retireEpisodes([id], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)

        XCTAssertEqual(result.committed, [id])
        let removal = try await fixture.store.removalKind(for: id)
        XCTAssertEqual(removal, .retired)
        let download = try await fixture.store.download(for: id)
        XCTAssertNotNil(download, "the audio's record waits for the window to close")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.media[id]!.path))

        let record = SoftSkipRecord(retiredAt: skippedAt, committed: result.committed,
                                    alreadyAtTarget: result.alreadyAtTarget, prior: result.priorDecisions)
        let restored = try await fixture.store.undoSoftSkip(record)

        XCTAssertEqual(restored, [id])
        let afterRemoval = try await fixture.store.removalKind(for: id)
        XCTAssertNil(afterRemoval)
        let afterDecision = try await fixture.store.episodeDecision(for: id)
        XCTAssertNil(afterDecision, "an episode with no decision before the Skip has none after Undo, not a new Keep")
        let afterDownload = try await fixture.store.download(for: id)
        XCTAssertNotNil(afterDownload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.media[id]!.path), "the audio is still there")
        let context = ModelContext(fixture.store.container)
        let positions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV21Models.PlaybackRecord>())
            .filter { $0.itemID == id.rawValue }.map(\.positionSeconds)
        XCTAssertEqual(positions, [42], "the playback position was never touched")
    }

    func testUndoRestoresTheExactPriorDecisionAndItsSource() async throws {
        let fixture = try await makeFixture(count: 1)
        let id = fixture.ids[0]
        let ruleID = UUID()
        let prior = EpisodeDecisionRecord(episodeID: id, decision: .keep, source: .rule, ruleID: ruleID,
                                          decidedAt: Timestamp(Date(timeIntervalSince1970: 1_750_000_000)))
        try await fixture.store.save(episodeDecision: prior)

        let result = try await fixture.store.retireEpisodes([id], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)
        let afterSkip = try await fixture.store.episodeDecision(for: id)
        XCTAssertEqual(afterSkip?.source, .manual)
        let record = SoftSkipRecord(retiredAt: skippedAt, committed: result.committed,
                                    alreadyAtTarget: result.alreadyAtTarget, prior: result.priorDecisions)
        try await fixture.store.undoSoftSkip(record)

        let restored = try await fixture.store.episodeDecision(for: id)
        XCTAssertEqual(restored, prior, "same decision, source, rule and time")
    }

    func testAStaleUndoAfterANewerSkipDoesNothing() async throws {
        let fixture = try await makeFixture(count: 1)
        let id = fixture.ids[0]
        let first = try await fixture.store.retireEpisodes([id], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)
        let older = SoftSkipRecord(retiredAt: skippedAt, committed: first.committed,
                                   alreadyAtTarget: first.alreadyAtTarget, prior: first.priorDecisions)
        let laterAt = Timestamp(Date(timeIntervalSince1970: 1_760_000_200))
        _ = try await fixture.store.retireEpisodes([id], at: laterAt, asOwnerChoice: true, deferringMediaDeletion: true)

        let restored = try await fixture.store.undoSoftSkip(older)

        XCTAssertEqual(restored, [])
        let removal = try await fixture.store.removalKind(for: id)
        XCTAssertEqual(removal, .retired, "the newer Skip stands")
        let decision = try await fixture.store.episodeDecision(for: id)
        XCTAssertEqual(decision?.decidedAt, laterAt)
    }

    func testAStaleUndoAfterTheOwnerKeptTheEpisodeDoesNothing() async throws {
        let fixture = try await makeFixture(count: 1)
        let id = fixture.ids[0]
        let result = try await fixture.store.retireEpisodes([id], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)
        let record = SoftSkipRecord(retiredAt: skippedAt, committed: result.committed,
                                    alreadyAtTarget: result.alreadyAtTarget, prior: result.priorDecisions)
        _ = try await fixture.store.restoreEpisodes([id], at: Date(timeIntervalSince1970: 1_760_000_200))
        let kept = try await fixture.store.episodeDecision(for: id)

        let restored = try await fixture.store.undoSoftSkip(record)

        XCTAssertEqual(restored, [])
        let after = try await fixture.store.episodeDecision(for: id)
        XCTAssertEqual(after, kept, "the owner's newer Keep is not overwritten")
        XCTAssertEqual(after?.decision, .keep)
    }

    func testUndoOfAGroupWithOneChangedMemberRestoresTheRest() async throws {
        let fixture = try await makeFixture(count: 3)
        let (a, b, c) = (fixture.ids[0], fixture.ids[1], fixture.ids[2])
        let result = try await fixture.store.retireEpisodes([a, b, c], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)
        let record = SoftSkipRecord(retiredAt: skippedAt, committed: result.committed,
                                    alreadyAtTarget: result.alreadyAtTarget, prior: result.priorDecisions)
        _ = try await fixture.store.restoreEpisodes([b], at: Date(timeIntervalSince1970: 1_760_000_200))

        let restored = try await fixture.store.undoSoftSkip(record)

        XCTAssertEqual(Set(restored), [a, c], "one member changed since; the others still come back")
        let removalA = try await fixture.store.removalKind(for: a)
        let removalC = try await fixture.store.removalKind(for: c)
        XCTAssertNil(removalA)
        XCTAssertNil(removalC)
    }

    func testAnAssociatedPairAndAPlainEpisodeUndoTogether() async throws {
        let fixture = try await makeFixture(count: 3)
        let (a, b, c) = (fixture.ids[0], fixture.ids[1], fixture.ids[2])
        let episodes = try await [fixture.store.podcastEpisode(for: a), fixture.store.podcastEpisode(for: b)].compactMap { $0 }
        let preview = try await fixture.store.previewEpisodeAssociation(
            confirming: PodcastEpisodePairConfirmation(confirmationID: UUID(), feedID: episodes[0].feedID,
                first: a, second: b, confirmedAt: episodes[0].createdAt), representativeID: a)
        _ = try await fixture.store.applyEpisodeAssociation(preview)

        let result = try await fixture.store.retireEpisodes([a, c], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)
        XCTAssertEqual(Set(result.committed), [a, b, c], "the linked twin retires with its pair")
        let record = SoftSkipRecord(retiredAt: skippedAt, committed: result.committed,
                                    alreadyAtTarget: result.alreadyAtTarget, prior: result.priorDecisions)

        let restored = try await fixture.store.undoSoftSkip(record)

        XCTAssertEqual(Set(restored), [a, b, c], "mixed linked and plain rows undo in one step")
    }

    // MARK: - Closing the Skip

    func testClosingTheSkipDeletesTheAudioOnlyOfMembersStillRetired() async throws {
        let fixture = try await makeFixture(count: 2)
        let (a, b) = (fixture.ids[0], fixture.ids[1])
        let result = try await fixture.store.retireEpisodes([a, b], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)
        _ = try await fixture.store.restoreEpisodes([b], at: Date(timeIntervalSince1970: 1_760_000_200))

        let remaining = try await fixture.store.finalizeSoftSkip(result.committed, at: skippedAt).finished

        XCTAssertEqual(remaining, [a])
        let downloadA = try await fixture.store.download(for: a)
        let downloadB = try await fixture.store.download(for: b)
        XCTAssertNil(downloadA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.media[a]!.path))
        XCTAssertNotNil(downloadB, "the restored episode keeps its audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.media[b]!.path))
        let again = try await fixture.store.finalizeSoftSkip(result.committed, at: skippedAt).finished
        XCTAssertEqual(again, [a], "closing twice is harmless")
    }

    func testClosingAfterUndoLeavesTheAudioAlone() async throws {
        let fixture = try await makeFixture(count: 1)
        let id = fixture.ids[0]
        let result = try await fixture.store.retireEpisodes([id], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)
        let record = SoftSkipRecord(retiredAt: skippedAt, committed: result.committed,
                                    alreadyAtTarget: result.alreadyAtTarget, prior: result.priorDecisions)
        try await fixture.store.undoSoftSkip(record)

        let remaining = try await fixture.store.finalizeSoftSkip(record.retiredIDs, at: skippedAt).finished

        XCTAssertEqual(remaining, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.media[id]!.path))
    }

    func testClosingKeepsTheAudioOfAMemberThePlayerHasLoadedAndReportsItHeld() async throws {
        let fixture = try await makeFixture(count: 2)
        let (a, b) = (fixture.ids[0], fixture.ids[1])
        let result = try await fixture.store.retireEpisodes([a, b], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)

        let close = try await fixture.store.finalizeSoftSkip(result.committed, at: skippedAt, protecting: [b])

        XCTAssertEqual(close.finished, [a])
        XCTAssertEqual(close.held, [b])
        let downloadB = try await fixture.store.download(for: b)
        XCTAssertNotNil(downloadB, "the playing episode keeps its audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.media[b]!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.media[a]!.path))

        let later = try await fixture.store.finalizeSoftSkip([b], at: skippedAt)
        XCTAssertEqual(later.finished, [b], "once the player lets go, the next close reclaims it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.media[b]!.path))
    }

    func testARecordCanBeNarrowedToTheMembersThatRemain() async throws {
        let fixture = try await makeFixture(count: 2)
        let (a, b) = (fixture.ids[0], fixture.ids[1])
        let result = try await fixture.store.retireEpisodes([a, b], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)
        let record = SoftSkipRecord(retiredAt: skippedAt, committed: result.committed,
                                    alreadyAtTarget: result.alreadyAtTarget, prior: result.priorDecisions)

        let narrowed = try XCTUnwrap(record.removing([a]))
        XCTAssertEqual(narrowed.retiredIDs, [b])
        XCTAssertEqual(narrowed.entryIDs, [b])
        XCTAssertNil(narrowed.removing([b]), "nothing left to offer or clean up")
        XCTAssertEqual(record.keeping([a])?.retiredIDs, [a])
    }

    func testTheRecordSurvivesBeingSavedAndReadBack() async throws {
        let fixture = try await makeFixture(count: 1)
        let id = fixture.ids[0]
        let prior = EpisodeDecisionRecord(episodeID: id, decision: .keep, source: .policy,
                                          decidedAt: Timestamp(Date(timeIntervalSince1970: 1_750_000_000)))
        try await fixture.store.save(episodeDecision: prior)
        let result = try await fixture.store.retireEpisodes([id], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)
        let record = SoftSkipRecord(retiredAt: skippedAt, committed: result.committed,
                                    alreadyAtTarget: result.alreadyAtTarget, prior: result.priorDecisions)

        let decoded = try JSONDecoder().decode(SoftSkipRecord.self, from: JSONEncoder().encode(record))

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.priorDecisions[id] ?? nil, prior)
    }

    func testAPlainSkipStillDeletesTheAudioAtOnce() async throws {
        let fixture = try await makeFixture(count: 1)
        let id = fixture.ids[0]
        _ = try await fixture.store.retireEpisodes([id], at: skippedAt, asOwnerChoice: true)
        let download = try await fixture.store.download(for: id)
        XCTAssertNil(download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.media[id]!.path))
    }

    // MARK: - Playlist

    func testPlaylistUndoPutsTheEntryBackAtItsExactPlaceInOneSave() async throws {
        let fixture = try await makeFixture(count: 4)
        let playlist = try await fixture.store.createPlaylist(name: "Mix", kind: .manual)
        for id in fixture.ids { try await fixture.store.addPlaylistEntry(playlistID: playlist.id, entryID: id.rawValue) }
        let order = fixture.ids.map(\.rawValue)

        let place = try await fixture.store.removePlaylistEntryRememberingPlace(playlistID: playlist.id, entryID: order[1])
        let restored = try await fixture.store.restorePlaylistEntry(
            playlistID: playlist.id, entryID: order[1], place: try XCTUnwrap(place))

        XCTAssertEqual(restored, order)
        let stored = try await fixture.store.playlistEntryIDs(playlistID: playlist.id)
        XCTAssertEqual(stored, order)
    }

    func testPlaylistUndoFollowsItsNeighboursWhenOthersMoved() async throws {
        let fixture = try await makeFixture(count: 4)
        let playlist = try await fixture.store.createPlaylist(name: "Mix", kind: .manual)
        for id in fixture.ids { try await fixture.store.addPlaylistEntry(playlistID: playlist.id, entryID: id.rawValue) }
        let o = fixture.ids.map(\.rawValue)
        let place = try await fixture.store.removePlaylistEntryRememberingPlace(playlistID: playlist.id, entryID: o[1])
        // Something else moved the entry that used to follow it to the front, and removed the one that preceded it.
        try await fixture.store.movePlaylistEntry(playlistID: playlist.id, entryID: o[2], to: 0)
        try await fixture.store.removePlaylistEntry(playlistID: playlist.id, entryID: o[0])

        let restored = try await fixture.store.restorePlaylistEntry(
            playlistID: playlist.id, entryID: o[1], place: try XCTUnwrap(place))

        XCTAssertEqual(restored, [o[1], o[2], o[3]], "it goes before the entry that used to follow it, since its predecessor is gone")
    }

    func testPlaylistUndoDoesNotBringBackADismissedEpisode() async throws {
        let fixture = try await makeFixture(count: 3)
        let playlist = try await fixture.store.createPlaylist(name: "Mix", kind: .manual)
        for id in fixture.ids { try await fixture.store.addPlaylistEntry(playlistID: playlist.id, entryID: id.rawValue) }
        let o = fixture.ids.map(\.rawValue)
        let place = try await fixture.store.removePlaylistEntryRememberingPlace(playlistID: playlist.id, entryID: o[1])
        try await fixture.store.dismissPodcastEpisode(fixture.ids[1])

        do {
            _ = try await fixture.store.restorePlaylistEntry(
                playlistID: playlist.id, entryID: o[1], place: try XCTUnwrap(place))
            XCTFail("a dismissed episode must not return to a playlist")
        } catch {}

        let stored = try await fixture.store.playlistEntryIDs(playlistID: playlist.id)
        XCTAssertEqual(stored, [o[0], o[2]])
    }

    // MARK: - Open window: admission and late downloads

    /// Skips the first (kept) episode softly and returns what Undo would need.
    private func skipKeptEpisode(_ fixture: Fixture) async throws -> SoftSkipRecord {
        try await fixture.store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: fixture.ids[0], decision: .keep, source: .manual, decidedAt: Timestamp(Date(timeIntervalSince1970: 1_760_000_000))))
        let result = try await fixture.store.retireEpisodes(
            [fixture.ids[0]], at: skippedAt, asOwnerChoice: true, deferringMediaDeletion: true)
        return SoftSkipRecord(retiredAt: skippedAt, committed: result.committed,
                              alreadyAtTarget: result.alreadyAtTarget, prior: result.priorDecisions)
    }

    private func admitAutomatically(_ fixture: Fixture, _ id: ItemID, limit: Int) async throws {
        try await fixture.store.admitEpisode(
            EpisodeDecisionRecord(episodeID: id, decision: .keep, source: .policy, decidedAt: Timestamp(Date())),
            automaticKeptLimit: limit)
    }

    func testAKeptSlotStaysTakenWhileTheUndoWindowIsOpenAndFreesWhenItCloses() async throws {
        let fixture = try await makeFixture(count: 2)
        let record = try await skipKeptEpisode(fixture)
        let feedID = try ItemID.derivePodcastFeed(from: URL(string: "https://podcasts.example.test/soft-skip.xml")!)

        let reserved = try await fixture.store.manualCompletionCapacityReservations()
        XCTAssertEqual(reserved[feedID], 1)
        do {
            try await admitAutomatically(fixture, fixture.ids[1], limit: 1)
            XCTFail("a refresh must not fill the slot Undo would take back")
        } catch { XCTAssertEqual(error as? AutomaticEpisodeAdmissionError, .capacityUnavailable) }

        try await fixture.store.finalizeSoftSkip(record.retiredIDs, at: skippedAt)
        let freed = try await fixture.store.manualCompletionCapacityReservations()
        XCTAssertNil(freed[feedID])
        try await admitAutomatically(fixture, fixture.ids[1], limit: 1)
    }

    func testUndoReleasesTheHoldAndTheEpisodeKeepsItsOwnSlot() async throws {
        let fixture = try await makeFixture(count: 2)
        let record = try await skipKeptEpisode(fixture)

        try await fixture.store.undoSoftSkip(record)

        let feedID = try ItemID.derivePodcastFeed(from: URL(string: "https://podcasts.example.test/soft-skip.xml")!)
        let reserved = try await fixture.store.manualCompletionCapacityReservations()
        XCTAssertNil(reserved[feedID], "the restored episode counts as kept itself, so nothing is reserved twice")
        do {
            try await admitAutomatically(fixture, fixture.ids[1], limit: 1)
            XCTFail("the restored Keep still fills the only slot")
        } catch { XCTAssertEqual(error as? AutomaticEpisodeAdmissionError, .capacityUnavailable) }
    }

    func testALateDownloadFinishesInsideTheWindowButNotAfterTheCleanup() async throws {
        let fixture = try await makeFixture(count: 1)
        let id = fixture.ids[0]
        let record = try await skipKeptEpisode(fixture)
        let late = fixture.media[id]!.deletingLastPathComponent().appendingPathComponent("late.mp3")
        try Data(repeating: 7, count: 64).write(to: late)
        let revision = try AudioRevision(
            itemID: id, revisionID: RevisionID(rawValue: "rev-late"), durationSeconds: 60, byteCount: 64,
            contentHash: "sha256:" + String(repeating: "c", count: 64), mediaType: "audio/mpeg",
            createdAt: Timestamp(Date()), schemaVersion: 3)
        let download = try PodcastDownload(
            episodeID: id, status: .completed, bytesReceived: 64, localURL: late,
            contentHash: revision.contentHash, updatedAt: Timestamp(Date()))

        try await fixture.store.finalizePodcastDownload(revision: revision, mediaURL: late, download: download)
        try await fixture.store.finalizeSoftSkip(record.retiredIDs, at: skippedAt)

        let again = try AudioRevision(
            itemID: id, revisionID: RevisionID(rawValue: "rev-later"), durationSeconds: 60, byteCount: 64,
            contentHash: revision.contentHash, mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 3)
        do {
            try await fixture.store.finalizePodcastDownload(revision: again, mediaURL: late, download: download)
            XCTFail("a download finishing after the cleanup must not bring the media back")
        } catch {}
        let stored = try await fixture.store.download(for: id)
        XCTAssertNil(stored)
    }

    // MARK: - Fixture

    private struct Fixture {
        let store: LocalLibraryStore
        let ids: [ItemID]
        let media: [ItemID: URL]
    }

    private func insertPlayback(_ fixture: Fixture, _ id: ItemID, positionSeconds: Double) throws {
        let context = ModelContext(fixture.store.container)
        context.insert(LocalLibrarySchemaV21Models.PlaybackRecord(try PlaybackState(
            itemID: id, revisionID: try RevisionID(rawValue: "r1"), sessionID: "session", sequence: 1,
            positionSeconds: positionSeconds, durationSeconds: 100, completed: false, intent: .progress,
            deviceID: "synthetic", updatedAt: Timestamp(Date())
        )))
        try context.save()
    }

    /// One subscribed feed whose live episodes each have a completed download with its file on disk.
    private func makeFixture(count: Int) async throws -> Fixture {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-soft-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let feedURL = URL(string: "https://podcasts.example.test/soft-skip.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let now = Timestamp(Date())
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Soft Skip", createdAt: now))
        var ids: [ItemID] = []
        var media: [ItemID: URL] = [:]
        for index in 0..<count {
            let enclosureURL = URL(string: "https://cdn.example.test/episode-\(index).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "guid-\(index)", enclosureURL: enclosureURL)
            try await store.savePodcastEpisodes([try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: "guid-\(index)", title: "Episode \(index)",
                publishedTime: now, enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", createdAt: now
            )], admission: .backfill)
            let mediaURL = directory.appendingPathComponent("episode-\(index).mp3")
            try Data("audio\(index)".utf8).write(to: mediaURL)
            try await store.save(download: PodcastDownload(
                episodeID: id, status: .completed, bytesReceived: 6, localURL: mediaURL,
                contentHash: "sha256:" + String(repeating: "a", count: 64), updatedAt: now
            ))
            ids.append(id); media[id] = mediaURL
        }
        return Fixture(store: store, ids: ids, media: media)
    }
}
