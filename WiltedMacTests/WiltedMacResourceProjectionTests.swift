import Foundation
import CryptoKit
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer
@testable import WiltedMac

private actor ResourceSnapshotReadGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ResourceSnapshotReadCounter {
    private var reads = 0

    func record() { reads += 1 }
    func value() -> Int { reads }
}

@MainActor
final class WiltedMacResourceProjectionTests: XCTestCase {
    func testStoredPositionsUsesOnePublicationProfileSnapshot() async throws {
        let directory = wiltedTemporaryDirectory("resource-stored-position-snapshot")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        let store = try XCTUnwrap(model.store)

        let feedURL = URL(string: "https://feeds.example.test/stored-position.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosure = URL(string: "https://media.example.test/stored-position.mp3")!
        let itemID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "stored-position", enclosureURL: enclosure)
        let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Stored", createdAt: now))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: now))
        try await store.save(episode: PodcastEpisode(
            itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: "stored-position",
            title: "Stored", publishedTime: now, enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", durationSeconds: 600, createdAt: now))
        let revisionID = try RevisionID(rawValue: "stored-position-revision")
        let mediaURL = directory.appendingPathComponent("stored-position.m4a")
        let bytes = Data([0x41, 0x42, 0x43])
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(
            itemID: itemID, revisionID: revisionID, durationSeconds: 600,
            byteCount: Int64(bytes.count), contentHash: hash,
            mediaType: "audio/mp4", createdAt: now, schemaVersion: 1)
        try await store.saveReadyRevision(revision, mediaURL: mediaURL)
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [itemID], currentEpisodeID: itemID))
        try await store.save(playback: PlaybackState(
            itemID: itemID, revisionID: revisionID, sessionID: "stored-position-session", sequence: 1,
            positionSeconds: 45, durationSeconds: 600, completed: false, intent: .progress,
            deviceID: "mac-resource-test", updatedAt: now))

        let beforeProfile = await store.podcastLibrarySnapshotFetchCount
        _ = try await store.podcastLibrarySnapshot(profile: .publication)
        let publicationCost = await store.podcastLibrarySnapshotFetchCount - beforeProfile
        let transcriptDecodes = await store.transcriptDecodeAttemptCount
        let journalDecodes = await store.preparationJournalDecodeAttemptCount
        let beforePlayer = await store.podcastLibrarySnapshotFetchCount
        let player = WiltedMacModelHandoffPlayer(model: model, audio: WiltedMacLocalReadyAudioSource(store: store))
        let positions = await player.storedPositions()
        let playerCost = await store.podcastLibrarySnapshotFetchCount - beforePlayer
        let transcriptDecodesAfter = await store.transcriptDecodeAttemptCount
        let journalDecodesAfter = await store.preparationJournalDecodeAttemptCount

        XCTAssertEqual(playerCost, publicationCost, "Handoff reads its queue and checkpoint from one narrow snapshot")
        XCTAssertEqual(transcriptDecodesAfter, transcriptDecodes)
        XCTAssertEqual(journalDecodesAfter, journalDecodes)
        XCTAssertEqual(positions.map(\.entryID), [itemID])
        XCTAssertEqual(positions.first?.positionSeconds, 45)
    }

    func testImportedPositionRepairsOverlappingAndPostReadSnapshots() async throws {
        let directory = wiltedTemporaryDirectory("resource-projection-position-fence")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        let store = try XCTUnwrap(model.store)

        let feedURL = URL(string: "https://feeds.example.test/resource-projection.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosure = URL(string: "https://media.example.test/resource-projection.mp3")!
        let itemID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "resource-projection", enclosureURL: enclosure)
        let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Resource", createdAt: now))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: now))
        try await store.save(episode: PodcastEpisode(
            itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: "resource-projection",
            title: "Projection", publishedTime: now, enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", durationSeconds: 600, createdAt: now))
        let revisionID = try RevisionID(rawValue: "resource-revision")
        let mediaURL = directory.appendingPathComponent("resource-projection.m4a")
        let bytes = Data([0x41, 0x42, 0x43])
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try await store.saveReadyRevision(try AudioRevision(
            itemID: itemID, revisionID: revisionID, durationSeconds: 600,
            byteCount: Int64(bytes.count), contentHash: hash, mediaType: "audio/mp4",
            createdAt: now, schemaVersion: 1), mediaURL: mediaURL)
        try await store.save(playback: PlaybackState(
            itemID: itemID, revisionID: revisionID, sessionID: "resource-session", sequence: 1,
            positionSeconds: 0, durationSeconds: 600, completed: false, intent: .progress,
            deviceID: "mac-resource-test", updatedAt: now))
        await model.reloadLibraryRows()
        XCTAssertEqual(model.episodes.first(where: { $0.id == itemID.rawValue })?.playbackSeconds, 0)

        let ordinaryAt = Timestamp(now.date.addingTimeInterval(2))
        try await store.save(playback: PlaybackState(
            itemID: itemID, revisionID: revisionID, sessionID: "resource-session", sequence: 2,
            positionSeconds: 31, durationSeconds: 600, completed: false, intent: .progress,
            deviceID: "mac-resource-test", updatedAt: ordinaryAt))
        let snapshotsBeforeOrdinaryImport = await store.podcastLibrarySnapshotFetchCount
        model.applyImportedPlaybackPosition(RemotePositionRequest(
            itemID: itemID, revisionID: revisionID, positionSeconds: 31, durationSeconds: 600,
            observedAt: ordinaryAt.date))
        let snapshotsAfterOrdinaryImport = await store.podcastLibrarySnapshotFetchCount
        XCTAssertEqual(snapshotsAfterOrdinaryImport, snapshotsBeforeOrdinaryImport,
            "An imported position with no stale library read must not reload the library")

        let gate = ResourceSnapshotReadGate()
        model.librarySnapshotReadBarrierForTesting = { await gate.hold() }
        let oldRead = Task { await model.reloadLibraryRows() }
        await gate.waitUntilHeld()
        model.librarySnapshotReadBarrierForTesting = nil

        let unrelatedURL = URL(string: "https://media.example.test/resource-projection-unrelated.mp3")!
        let unrelatedID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "resource-projection-unrelated", enclosureURL: unrelatedURL)
        try await store.save(episode: PodcastEpisode(
            itemID: unrelatedID, feedID: feedID, feedURL: feedURL, rssGUID: "resource-projection-unrelated",
            title: "Arrived during read", publishedTime: now, enclosureURL: unrelatedURL,
            enclosureMediaType: "audio/mpeg", durationSeconds: 420, createdAt: now))
        let updatedAt = Timestamp(now.date.addingTimeInterval(5))
        try await store.save(playback: PlaybackState(
            itemID: itemID, revisionID: revisionID, sessionID: "resource-session", sequence: 3,
            positionSeconds: 77, durationSeconds: 600, completed: false, intent: .progress,
            deviceID: "mac-resource-test", updatedAt: updatedAt))
        let writesBefore = model.playbackProjectionWriteCountForTesting
        model.applyImportedPlaybackPosition(RemotePositionRequest(
            itemID: itemID, revisionID: revisionID, positionSeconds: 77, durationSeconds: 600,
            observedAt: updatedAt.date))
        await gate.release()
        await oldRead.value

        XCTAssertEqual(model.episodes.first(where: { $0.id == itemID.rawValue })?.playbackSeconds, 77,
            "The pre-update snapshot must not replace the position already applied to the visible row")
        XCTAssertTrue(model.episodes.contains(where: { $0.id == unrelatedID.rawValue }),
            "The retry must retain the unrelated row added while the older snapshot was held")
        XCTAssertEqual(model.playbackProjectionWriteCountForTesting - writesBefore, 1)

        // Model a caller that awaits after loading and before applying. The
        // common stale-row owner must schedule the fresh projection itself.
        let delayedValues = try await model.loadLibrary(from: store)
        let delayedURL = URL(string: "https://media.example.test/resource-projection-delayed.mp3")!
        let delayedID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "resource-projection-delayed", enclosureURL: delayedURL)
        try await store.save(episode: PodcastEpisode(
            itemID: delayedID, feedID: feedID, feedURL: feedURL, rssGUID: "resource-projection-delayed",
            title: "Arrived after read", publishedTime: now, enclosureURL: delayedURL,
            enclosureMediaType: "audio/mpeg", durationSeconds: 300, createdAt: now))
        let newestAt = Timestamp(now.date.addingTimeInterval(10))
        try await store.save(playback: PlaybackState(
            itemID: itemID, revisionID: revisionID, sessionID: "resource-session", sequence: 4,
            positionSeconds: 123, durationSeconds: 600, completed: false, intent: .progress,
            deviceID: "mac-resource-test", updatedAt: newestAt))
        model.applyImportedPlaybackPosition(RemotePositionRequest(
            itemID: itemID, revisionID: revisionID, positionSeconds: 123, durationSeconds: 600,
            observedAt: newestAt.date))
        await Task.yield()
        let snapshotReads = ResourceSnapshotReadCounter()
        model.librarySnapshotReadBarrierForTesting = { await snapshotReads.record() }
        let snapshotsBeforeRepair = await snapshotReads.value()
        XCTAssertFalse(model.applyEpisodes(delayedValues.episodes),
            "An intervening await makes the pre-import rows stale")
        XCTAssertFalse(model.applyEpisodes(delayedValues.episodes),
            "A second stale apply must join the same bounded repair")
        let followUp = try XCTUnwrap(model.importedPositionLibraryReloadTask)
        await followUp.value
        let snapshotsAfterRepair = await snapshotReads.value()
        XCTAssertEqual(snapshotsAfterRepair - snapshotsBeforeRepair, 1,
            "Coalesced stale applies share one fresh snapshot")
        model.librarySnapshotReadBarrierForTesting = nil
        XCTAssertEqual(model.episodes.first(where: { $0.id == itemID.rawValue })?.playbackSeconds, 123)
        XCTAssertTrue(model.episodes.contains(where: { $0.id == delayedID.rawValue }),
            "A rejected operation-local snapshot must schedule a fresh library projection")
    }
}
