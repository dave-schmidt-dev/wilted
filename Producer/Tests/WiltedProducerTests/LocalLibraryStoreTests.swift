import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

final class LocalLibraryStoreTests: XCTestCase {
    func testPodcastQueueMutationsNormalizeAndRestoreOrderAndCurrentIdentity() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try ItemID(rawValue: "item-" + String(repeating: "1", count: 64))
        let second = try ItemID(rawValue: "item-" + String(repeating: "2", count: 64))
        let third = try ItemID(rawValue: "item-" + String(repeating: "3", count: 64))
        var store = try LocalLibraryStore(url: url)
        try await store.addPodcastQueueEpisode(first)
        try await store.addPodcastQueueEpisode(second)
        try await store.addPodcastQueueEpisode(third)
        try await store.setCurrentPodcastQueueEpisode(second)
        try await store.movePodcastQueueEpisode(from: 2, to: 0)
        let firstEntries = try await store.queue()
        let firstState = try await store.podcastQueueState()
        XCTAssertEqual(firstEntries.map(\.position), [0, 1, 2])
        XCTAssertEqual(firstState, try PodcastQueueState(
            episodeIDs: [third, first, second], currentEpisodeID: second
        ))

        store = try LocalLibraryStore(url: url)
        let reopened = try await store.podcastQueueState()
        XCTAssertEqual(reopened.episodeIDs, [third, first, second])
        XCTAssertEqual(reopened.currentEpisodeID, second)
        try await store.removePodcastQueueEpisode(first)
        let removedEntries = try await store.queue()
        let removedState = try await store.podcastQueueState()
        XCTAssertEqual(removedEntries.map(\.position), [0, 1])
        XCTAssertEqual(removedState.episodeIDs, [third, second])
    }

    private struct ForcedMigrationFailure: Error {}

    private func makeURL(_ name: String = #function) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wilted-store-\(name)-\(UUID().uuidString)").appendingPathComponent("library.sqlite")
    }

    private func article() throws -> Article {
        let url = URL(string: "https://example.test/library/article")!
        return try Article(itemID: ItemID.derive(from: url), canonicalURL: url, title: "A durable article", source: "example.test", createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func revision(for article: Article, id: String, at time: TimeInterval = 1_700_000_001) throws -> AudioRevision {
        try AudioRevision(itemID: article.itemID, revisionID: RevisionID(rawValue: id), durationSeconds: 42, byteCount: 128,
                          contentHash: "sha256\(String(repeating: ":", count: 0)):\(String(repeating: "a", count: 64))",
                          mediaType: "audio/mp4", createdAt: Timestamp(Date(timeIntervalSince1970: time)), schemaVersion: 1)
    }

    private func playback(for article: Article, revision: AudioRevision, position: Double) throws -> PlaybackState {
        try PlaybackState(itemID: article.itemID, revisionID: revision.revisionID, sessionID: "session-1", sequence: 1,
                          positionSeconds: position, durationSeconds: revision.durationSeconds, completed: false, intent: .progress,
                          deviceID: "device-mac", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_010)))
    }

    private func podcastValues() throws -> (PodcastFeed, PodcastEpisode) {
        let feedURL = URL(string: "https://podcasts.example.test/feed.xml")!
        let enclosureURL = URL(string: "https://podcasts.example.test/audio/episode-1.mp3")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "The Wilted Show",
                                   author: "Wilted", artworkURL: URL(string: "https://podcasts.example.test/art.jpg"),
                                   createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)))
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "episode-1", enclosureURL: enclosureURL)
        let episode = try PodcastEpisode(itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-1",
                                         title: "Episode One", author: "Wilted", publishedTime: feed.createdAt,
                                         enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", enclosureByteCount: 1000,
                                         durationSeconds: 120, artworkURL: feed.artworkURL, createdAt: feed.createdAt)
        return (feed, episode)
    }

    /// Marking an article deleted has to survive a round trip. Nothing covered
    /// this, and the producer's Remove action depends on it entirely.
    func testDeletingAnArticleSurvivesAReadBack() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article()
        let store = try LocalLibraryStore(url: url)
        try await store.save(article: article)
        var flags = try await store.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [false])

        let deleted = try Article(
            itemID: article.itemID, canonicalURL: article.canonicalURL, title: article.title,
            source: article.source, author: article.author, publishedTime: article.publishedTime,
            createdAt: article.createdAt, isDeleted: true
        )
        try await store.save(article: deleted)
        flags = try await store.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [true], "in-process read back")
        let single = try await store.article(for: article.itemID)?.isDeleted
        XCTAssertEqual(single, true, "single-item read back")

        let reopened = try LocalLibraryStore(url: url)
        flags = try await reopened.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [true], "read back after reopen")
    }

    func testInterruptedStoreReopensWithArticleRevisionPreparationAndPlayback() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article()
        let revision = try revision(for: article, id: "rev-v1")
        let status = try PreparationStatus(stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                                            terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                                            emittedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_002)))
        do {
            let store = try LocalLibraryStore(url: url)
            try await store.save(article: article)
            try await store.saveReadyRevision(revision, mediaURL: URL(fileURLWithPath: "/tmp/rev-v1.m4a"))
            try await store.record(preparation: PreparationJournalEntry(id: "prep-1", itemID: article.itemID, requestID: "request-1", status: status))
            try await store.save(playback: playback(for: article, revision: revision, position: 12))
        }
        let reopened = try LocalLibraryStore(url: url)
        let reopenedArticle = try await reopened.article(for: article.itemID)
        let reopenedRevision = try await reopened.readyRevision(for: article.itemID)
        let reopenedJournal = try await reopened.preparationJournal(for: "request-1")
        let reopenedPlayback = try await reopened.playbackState(for: article.itemID, revisionID: revision.revisionID)
        XCTAssertEqual(reopenedArticle, article)
        XCTAssertEqual(reopenedRevision?.revisionID, revision.revisionID)
        XCTAssertEqual(reopenedJournal.count, 1)
        XCTAssertEqual(reopenedPlayback?.positionSeconds, 12)
    }

    func testV2StoreMigratesArticlePlaybackAndSafeNewDefaults() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let rev = try revision(for: item, id: "rev-migration")
        let state = try playback(for: item, revision: rev, position: 17)
        try LocalLibraryStore.createV2MigrationFixture(at: url, article: item, playback: state)

        let migrated = try LocalLibraryStore(url: url)
        let migratedArticle = try await migrated.article(for: item.itemID)
        let migratedPlayback = try await migrated.playbackState(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(migratedArticle, item)
        XCTAssertEqual(migratedPlayback?.positionSeconds, 17)
        let migratedStatus = try await migrated.syncStatus(for: item.itemID)
        let migratedSidecar = try await migrated.playbackSidecar(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(migratedStatus, .localOnly)
        XCTAssertNil(migratedSidecar?.changeTag)
        let migratedTranscript = try await migrated.transcript(for: item.itemID, revisionID: rev.revisionID)
        let migratedInspection = try await migrated.inspect()
        XCTAssertNil(migratedTranscript)
        XCTAssertEqual(migratedInspection.schemaVersion, .v9)
    }

    /// The V4 -> V5 stage renames the deletion column. A read-back inside one
    /// schema version cannot catch a rename that drops its values, so this
    /// walks a deleted article from a frozen V2 store all the way to V5.
    func testDeletionFlagSurvivesMigrationFromV2() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let live = try article()
        let removed = try Article(
            itemID: live.itemID, canonicalURL: live.canonicalURL, title: live.title,
            source: live.source, author: live.author, publishedTime: live.publishedTime,
            createdAt: live.createdAt, isDeleted: true
        )
        let rev = try revision(for: removed, id: "rev-deleted-migration")
        try LocalLibraryStore.createV2MigrationFixture(
            at: url, article: removed, playback: try playback(for: removed, revision: rev, position: 3)
        )

        let migrated = try LocalLibraryStore(url: url)
        let flags = try await migrated.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [true], "the deletion flag must survive the column rename")
        let single = try await migrated.article(for: removed.itemID)?.isDeleted
        XCTAssertEqual(single, true)
    }

    func testPriorRevisionIsPreservedAndImmutableWhenNewRevisionIsSaved() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article(); let old = try revision(for: article, id: "rev-old", at: 1_700_000_001); let new = try revision(for: article, id: "rev-new", at: 1_700_000_002)
        let store = try LocalLibraryStore(url: url)
        try await store.saveReadyRevision(old, mediaURL: URL(fileURLWithPath: "/tmp/old.m4a"))
        try await store.saveReadyRevision(new, mediaURL: URL(fileURLWithPath: "/tmp/new.m4a"))
        let revisions = try await store.revisions(for: article.itemID)
        XCTAssertEqual(Set(revisions.map(\.revisionID)), [old.revisionID, new.revisionID])
        do {
            try await store.saveReadyRevision(old, mediaURL: URL(fileURLWithPath: "/tmp/changed.m4a"))
            XCTFail("Expected immutable revision error")
        } catch {
            XCTAssertEqual(error as? LocalLibraryStoreError, .immutableRevision(old.revisionID))
        }
    }

    func testTranscriptPersistsWithRevisionAndSurvivesRelaunch() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let rev = try revision(for: item, id: "rev-transcript")
        let transcript = try Transcript(itemID: item.itemID, revisionID: rev.revisionID,
                                        availability: .available, text: "Persisted article text.",
                                        languageCode: "en", updatedAt: rev.createdAt)
        do {
            let store = try LocalLibraryStore(url: url)
            try await store.saveReadyRevision(rev, mediaURL: URL(fileURLWithPath: "/tmp/transcript.m4a"),
                                              transcript: transcript)
            let inspection = try await store.inspect()
            XCTAssertEqual(inspection.transcriptCount, 1)
        }
        let reopened = try LocalLibraryStore(url: url)
        let reopenedTranscript = try await reopened.transcript(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(reopenedTranscript, transcript)
    }

    /// The pipeline reads the published transcript URL off the stored episode
    /// when it prepares one, so a source that survives the feed parser but not
    /// the store is the same as no source at all.
    func testPublishedTranscriptSourcesSurviveTheStoreAndAnUpdate() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (feed, plain) = try podcastValues()
        let sources = [try PodcastTranscriptSource(url: XCTUnwrap(URL(string: "https://cdn.example.test/one.html")),
                                                   mediaType: "text/html"),
                       try PodcastTranscriptSource(url: XCTUnwrap(URL(string: "https://cdn.example.test/one.vtt")),
                                                   mediaType: "text/vtt", languageCode: "en", isCaptions: true)]
        let episode = try PodcastEpisode(itemID: plain.itemID, feedID: plain.feedID, feedURL: plain.feedURL,
                                         rssGUID: plain.rssGUID, title: plain.title, author: plain.author,
                                         publishedTime: plain.publishedTime, enclosureURL: plain.enclosureURL,
                                         enclosureMediaType: plain.enclosureMediaType,
                                         enclosureByteCount: plain.enclosureByteCount,
                                         durationSeconds: plain.durationSeconds, artworkURL: plain.artworkURL,
                                         transcriptSources: sources, createdAt: plain.createdAt)
        do {
            let store = try LocalLibraryStore(url: url)
            try await store.save(feed: feed)
            try await store.save(episode: episode)
        }
        let reopened = try LocalLibraryStore(url: url)
        let loaded = try await reopened.podcastEpisode(for: episode.itemID)
        XCTAssertEqual(loaded, episode)
        XCTAssertEqual(loaded?.timedTranscriptSource?.mediaType, "text/vtt")
        let listed = try await reopened.podcastEpisodes(for: feed.itemID)
        XCTAssertEqual(listed, [episode])

        // A publisher who withdraws a transcript must clear the column, not
        // leave the old URL behind for the pipeline to keep fetching.
        try await reopened.save(episode: plain)
        let cleared = try await reopened.podcastEpisode(for: episode.itemID)
        XCTAssertEqual(cleared?.transcriptSources, [])
        XCTAssertNil(cleared?.timedTranscriptSource)
    }

    /// Show notes ride on the episode row: preparation reads them as the
    /// glossary for correcting the transcript and the Larder shows them.
    func testShowNotesSurviveTheStoreAndAreClearedWhenTheFeedDropsThem() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (feed, plain) = try podcastValues()
        let notes = "Host: Leo Laporte\n\nGuests: Molly White (https://www.mollywhite.net/)"
        let noted = try PodcastEpisode(itemID: plain.itemID, feedID: plain.feedID, feedURL: plain.feedURL,
                                       rssGUID: plain.rssGUID, title: plain.title, author: plain.author,
                                       publishedTime: plain.publishedTime, enclosureURL: plain.enclosureURL,
                                       enclosureMediaType: plain.enclosureMediaType,
                                       enclosureByteCount: plain.enclosureByteCount,
                                       durationSeconds: plain.durationSeconds, artworkURL: plain.artworkURL,
                                       notes: notes, createdAt: plain.createdAt)
        do {
            let store = try LocalLibraryStore(url: url)
            try await store.save(feed: feed)
            try await store.save(episode: noted)
        }
        let reopened = try LocalLibraryStore(url: url)
        let loaded = try await reopened.podcastEpisode(for: noted.itemID)
        XCTAssertEqual(loaded?.notes, notes)
        let listed = try await reopened.podcastEpisodes(for: feed.itemID)
        XCTAssertEqual(listed.first?.notes, notes)
        try await reopened.save(episode: plain)
        let cleared = try await reopened.podcastEpisode(for: noted.itemID)
        XCTAssertNil(cleared?.notes)
    }

    /// A prepared revision replaces the one it was cut from, and the store
    /// refuses any replacement that would leave the library incoherent.
    func testPreparedRevisionSupersedesTheOneItWasCutFrom() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/superseded.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://cdn.example.test/superseded.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "s1", enclosureURL: enclosureURL)
        let originalID = try RevisionID(rawValue: "rev-" + String(repeating: "a", count: 64))
        let preparedID = try RevisionID(rawValue: "rev-" + String(repeating: "b", count: 64))
        let originalURL = URL(fileURLWithPath: "/tmp/superseded/original.mp3")
        let preparedURL = URL(fileURLWithPath: "/tmp/superseded/prepared.mp3")
        let originalHash = "sha256:" + String(repeating: "a", count: 64)
        let preparedHash = "sha256:" + String(repeating: "b", count: 64)
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        func revision(_ id: RevisionID, _ hash: String, bytes: Int64, seconds: Double) throws -> AudioRevision {
            try AudioRevision(itemID: episodeID, revisionID: id, durationSeconds: seconds, byteCount: bytes,
                              contentHash: hash, mediaType: "audio/mpeg", createdAt: when, schemaVersion: 3)
        }
        func download(_ hash: String, _ location: URL, bytes: Int64) throws -> PodcastDownload {
            try PodcastDownload(episodeID: episodeID, status: .completed, bytesReceived: bytes,
                                expectedByteCount: bytes, localURL: location, contentHash: hash, updatedAt: when)
        }

        try await store.finalizePodcastDownload(revision: try revision(originalID, originalHash, bytes: 100, seconds: 60),
                                                mediaURL: originalURL,
                                                download: try download(originalHash, originalURL, bytes: 100))
        try await store.save(transcript: try Transcript(itemID: episodeID, revisionID: originalID,
                                                        availability: .available, text: "Before the cut.", updatedAt: when))
        try await store.save(playback: try PlaybackState(itemID: episodeID, revisionID: originalID, sessionID: "s",
                                                         sequence: 1, positionSeconds: 30, durationSeconds: 60,
                                                         completed: false, intent: .progress, deviceID: "mac", updatedAt: when))

        let prepared = try revision(preparedID, preparedHash, bytes: 80, seconds: 48)
        let preparedTranscript = try Transcript(itemID: episodeID, revisionID: preparedID, availability: .available,
                                                text: "After the cut.", timing: .aligned,
                                                cues: [try TranscriptCue(startSeconds: 0, endSeconds: 2, text: "After the cut.")],
                                                updatedAt: when)

        // A replacement whose download disagrees with the revision is refused
        // before anything is written.
        do {
            try await store.replaceReadyRevision(prepared, mediaURL: preparedURL, transcript: preparedTranscript,
                                                 download: try download(originalHash, preparedURL, bytes: 80),
                                                 superseding: originalID)
            XCTFail("expected the store to refuse a mismatched download")
        } catch LocalLibraryStoreError.invalidPodcastState { }
        let untouched = try await store.revisions(for: episodeID)
        XCTAssertEqual(untouched.map(\.revision.revisionID), [originalID])

        try await store.replaceReadyRevision(prepared, mediaURL: preparedURL, transcript: preparedTranscript,
                                             download: try download(preparedHash, preparedURL, bytes: 80),
                                             superseding: originalID,
                                             carrying: try PlaybackState(itemID: episodeID, revisionID: preparedID,
                                                                         sessionID: "s", sequence: 2, positionSeconds: 24,
                                                                         durationSeconds: 48, completed: false,
                                                                         intent: .progress, deviceID: "mac", updatedAt: when))

        let reopened = try LocalLibraryStore(url: url)
        let survivors = try await reopened.revisions(for: episodeID)
        XCTAssertEqual(survivors.map(\.revision.revisionID), [preparedID])
        let newestMedia = try await reopened.readyRevision(for: episodeID)?.mediaURL
        XCTAssertEqual(newestMedia, preparedURL)
        let oldTranscript = try await reopened.transcript(for: episodeID, revisionID: originalID)
        let newTranscript = try await reopened.transcript(for: episodeID, revisionID: preparedID)
        let oldPlayback = try await reopened.playbackState(for: episodeID, revisionID: originalID)
        let newPlayback = try await reopened.playbackState(for: episodeID, revisionID: preparedID)
        let finalDownload = try await reopened.download(for: episodeID)
        XCTAssertNil(oldTranscript)
        XCTAssertEqual(newTranscript?.cues?.count, 1)
        XCTAssertNil(oldPlayback)
        XCTAssertEqual(newPlayback?.positionSeconds, 24)
        XCTAssertEqual(finalDownload?.localURL, preparedURL)
    }

    func testTimedTranscriptPersistsCuesAndProvenanceAcrossRelaunch() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let rev = try revision(for: item, id: "rev-timed")
        let cues = [try TranscriptCue(startSeconds: 0, endSeconds: 4.5, text: "First spoken line."),
                    try TranscriptCue(startSeconds: 4.5, endSeconds: 9.25, text: "Second spoken line.")]
        let transcript = try Transcript(itemID: item.itemID, revisionID: rev.revisionID,
                                        availability: .available, text: "First spoken line. Second spoken line.",
                                        languageCode: "en", timing: .aligned, cues: cues, updatedAt: rev.createdAt)
        do {
            let store = try LocalLibraryStore(url: url)
            try await store.saveReadyRevision(rev, mediaURL: URL(fileURLWithPath: "/tmp/timed.m4a"),
                                              transcript: transcript)
        }
        let reopened = try LocalLibraryStore(url: url)
        let loaded = try await reopened.transcript(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(loaded, transcript)
        XCTAssertEqual(loaded?.timing, .aligned)
        XCTAssertEqual(loaded?.cue(at: 5)?.text, "Second spoken line.")
    }

    /// Re-preparing an episode replaces its transcript. Timing has to be part of
    /// that replacement: leaving stale cues behind would point the reading
    /// position at audio that no longer exists.
    func testUpsertReplacesTimingAndCuesRatherThanLeavingThemBehind() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let rev = try revision(for: item, id: "rev-replace")
        let store = try LocalLibraryStore(url: url)
        let timed = try Transcript(itemID: item.itemID, revisionID: rev.revisionID, availability: .available,
                                   text: "Timed body",
                                   timing: .published,
                                   cues: [try TranscriptCue(startSeconds: 0, endSeconds: 3, text: "Timed body")],
                                   updatedAt: rev.createdAt)
        try await store.saveReadyRevision(rev, mediaURL: URL(fileURLWithPath: "/tmp/replace.m4a"), transcript: timed)
        let untimed = try Transcript(itemID: item.itemID, revisionID: rev.revisionID, availability: .available,
                                     text: "Untimed body", updatedAt: rev.createdAt)
        try await store.save(transcript: untimed)
        let loaded = try await store.transcript(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(loaded, untimed)
        XCTAssertNil(loaded?.cues, "the replacement carries no timing, so no cues may survive it")
        XCTAssertEqual(loaded?.timing, TranscriptTiming.none)
    }

    func testTranscriptAndRevisionIdentityMustMatchBeforeAtomicSave() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let rev = try revision(for: item, id: "rev-a")
        let transcript = try Transcript(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-b"),
                                        availability: .available, text: "Text", updatedAt: rev.createdAt)
        let store = try LocalLibraryStore(url: url)
        do {
            try await store.saveReadyRevision(rev, mediaURL: URL(fileURLWithPath: "/tmp/rev-a.m4a"),
                                              transcript: transcript)
            XCTFail("Expected identity mismatch")
        } catch {
            XCTAssertEqual(error as? LocalLibraryStoreError, .revisionBelongsToDifferentItem)
        }
        let savedRevision = try await store.readyRevision(for: item.itemID)
        XCTAssertNil(savedRevision)
    }

    func testPlaybackRequiresMatchingStableItemAndRevision() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article(); let first = try revision(for: article, id: "rev-first"); let second = try revision(for: article, id: "rev-second")
        let store = try LocalLibraryStore(url: url)
        try await store.save(playback: playback(for: article, revision: first, position: 30))
        let mismatchedRevision = try await store.playbackState(for: article.itemID, revisionID: second.revisionID)
        XCTAssertNil(mismatchedRevision)
        let otherItem = try ItemID(rawValue: "item-other")
        let mismatchedItem = try await store.playbackState(for: otherItem, revisionID: first.revisionID)
        XCTAssertNil(mismatchedItem)
    }

    func testSyncStateTombstoneAndPlaybackSidecarsReopen() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "rev-sidecar")
        let store = try LocalLibraryStore(url: url)
        try await store.save(article: item)
        try await store.save(playback: playback(for: item, revision: rev, position: 8))
        let fetched = Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
        let sent = Timestamp(Date(timeIntervalSince1970: 1_700_000_101))
        try await store.save(syncState: LocalLibrarySyncState(key: "private-zone", engineState: Data([1, 2, 3]), lastFetchAt: fetched, lastSendAt: sent))
        try await store.save(playbackSidecar: PlaybackSystemFieldsSidecar(encodedSystemFields: Data([4, 5]), changeTag: "change-tag-1"), for: item.itemID, revisionID: rev.revisionID)
        try await store.record(tombstone: LocalLibraryTombstone(id: "delete-1", itemID: item.itemID, requestedAt: fetched))
        let firstAcknowledgement = try await store.acknowledgeTombstone(id: "delete-1")
        let secondAcknowledgement = try await store.acknowledgeTombstone(id: "delete-1")
        XCTAssertTrue(firstAcknowledgement)
        XCTAssertFalse(secondAcknowledgement)

        let reopened = try LocalLibraryStore(url: url)
        let reopenedSync = try await reopened.syncState(for: "private-zone")
        let reopenedSidecar = try await reopened.playbackSidecar(for: item.itemID, revisionID: rev.revisionID)
        let reopenedTombstone = try await reopened.tombstone(for: "delete-1")
        XCTAssertEqual(reopenedSync?.engineState, Data([1, 2, 3]))
        XCTAssertEqual(reopenedSync?.lastFetchAt, fetched)
        XCTAssertEqual(reopenedSidecar, PlaybackSystemFieldsSidecar(encodedSystemFields: Data([4, 5]), changeTag: "change-tag-1"))
        XCTAssertEqual(reopenedTombstone?.remoteAcknowledged, true)
    }

    func testCorruptRepositoryStateDoesNotSilentlyReset() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try LocalLibraryStore.corruptRepositoryStateFixture(at: url, data: Data("corrupt-state".utf8))
        let store = try LocalLibraryStore(url: url)
        do {
            _ = try await store.syncRepositoryState()
            XCTFail("Expected corrupt repository state to throw")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testPartialSnapshotRetainsEveryLocalState() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let statuses: [LocalLibrarySyncStatus] = [.remoteAcknowledged, .localOnly, .pendingUpload, .conflicted, .failedUpload]
        var items: [ItemID] = []
        for (index, status) in statuses.enumerated() {
            let value = try Article(itemID: ItemID.derive(from: URL(string: "https://example.test/article-\(index)")!), canonicalURL: URL(string: "https://example.test/article-\(index)")!, title: "Article \(index)", source: "example.test", createdAt: Timestamp(Date(timeIntervalSince1970: Double(index))))
            items.append(value.itemID); try await store.save(article: value); try await store.setSyncStatus(status, for: value.itemID)
        }
        let result = try await store.finalizeSnapshot(generationID: "generation-partial", fetchComplete: false, seenRemoteItemIDs: [items[0]])
        XCTAssertFalse(result.mutated)
        let articleCount = try await store.articles().count
        XCTAssertEqual(articleCount, statuses.count)
    }

    func testCompleteSnapshotDeletesOnlyUnseenRemoteAcknowledgedItems() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let remote = try article()
        let localURL = URL(string: "https://example.test/local")!
        let local = try Article(itemID: ItemID.derive(from: localURL), canonicalURL: localURL, title: "Local", source: "example.test", createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_004)))
        try await store.save(article: remote); try await store.save(article: local)
        try await store.setSyncStatus(.remoteAcknowledged, for: remote.itemID)
        try await store.setSyncStatus(.localOnly, for: local.itemID)
        let result = try await store.finalizeSnapshot(generationID: "generation-complete", fetchComplete: true, seenRemoteItemIDs: Set<ItemID>())
        XCTAssertEqual(result.deletedItemIDs, [remote.itemID])
        let deletedArticle = try await store.article(for: remote.itemID)
        let retainedArticle = try await store.article(for: local.itemID)
        XCTAssertNil(deletedArticle)
        XCTAssertNotNil(retainedArticle)
    }

    func testV6PodcastStateRoundTripsWithoutTouchingArticleState() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article(); let revision = try revision(for: article, id: "v6-revision")
        let store = try LocalLibraryStore(url: url)
        try await store.save(article: article)
        try await store.saveReadyRevision(revision, mediaURL: URL(fileURLWithPath: "/tmp/v6.m4a"))
        try await store.save(playback: playback(for: article, revision: revision, position: 9))
        let (feed, episode) = try podcastValues()
        try await store.save(feed: feed); try await store.save(episode: episode)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: feed.createdAt))
        try await store.save(download: try PodcastDownload(episodeID: episode.itemID, status: .completed,
                                                            bytesReceived: 1000, expectedByteCount: 1000,
                                                            localURL: URL(fileURLWithPath: "/tmp/episode.mp3"),
                                                            contentHash: "sha256:" + String(repeating: "a", count: 64), updatedAt: feed.createdAt))
        try await store.save(artwork: try PodcastArtwork(id: "art-1", ownerID: feed.itemID,
                                                          remoteURL: feed.artworkURL, localURL: URL(fileURLWithPath: "/tmp/art.jpg"),
                                                          byteCount: 10, updatedAt: feed.createdAt))
        try await store.save(queueEntry: try PodcastQueueEntry(episodeID: episode.itemID, position: 0, addedAt: feed.createdAt))
        try await store.save(playbackSpeed: try PodcastPlaybackSpeed(itemID: episode.itemID, speed: 1.5, updatedAt: feed.createdAt))
        let reopened = try LocalLibraryStore(url: url)
        let reopenedFeed = try await reopened.podcastFeed(for: feed.itemID)
        let reopenedEpisode = try await reopened.podcastEpisode(for: episode.itemID)
        let reopenedSubscription = try await reopened.subscription(for: feed.itemID)
        let reopenedDownload = try await reopened.download(for: episode.itemID)
        let reopenedArtwork = try await reopened.artwork(for: "art-1")
        let reopenedQueue = try await reopened.upNext()
        let reopenedSpeed = try await reopened.playbackSpeed(for: episode.itemID)
        let reopenedArticle = try await reopened.article(for: article.itemID)
        let reopenedRevision = try await reopened.readyRevision(for: article.itemID)
        let reopenedPlayback = try await reopened.playbackState(for: article.itemID, revisionID: revision.revisionID)
        XCTAssertEqual(reopenedFeed, feed)
        XCTAssertEqual(reopenedEpisode, episode)
        XCTAssertEqual(reopenedSubscription?.enabled, true)
        XCTAssertEqual(reopenedDownload?.status, .completed)
        XCTAssertEqual(reopenedArtwork?.ownerID, feed.itemID)
        XCTAssertEqual(reopenedQueue.map(\.episodeID), [episode.itemID])
        XCTAssertEqual(reopenedSpeed?.speed, 1.5)
        XCTAssertEqual(reopenedArticle, article)
        XCTAssertEqual(reopenedRevision?.revision.itemID, revision.itemID)
        XCTAssertEqual(reopenedRevision?.revision.revisionID, revision.revisionID)
        XCTAssertEqual(reopenedRevision?.revision.contentHash, revision.contentHash)
        XCTAssertEqual(reopenedPlayback?.positionSeconds, 9)
    }

    func testPodcastRecordsUpsertAndQueriesReflectLatestState() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (feed, episode) = try podcastValues()
        let secondEpisodeURL = URL(string: "https://podcasts.example.test/audio/episode-2.mp3")!
        let secondEpisodeID = try ItemID.derivePodcastEpisode(feedURL: feed.canonicalURL, rssGUID: "episode-2", enclosureURL: secondEpisodeURL)
        let secondEpisode = try PodcastEpisode(itemID: secondEpisodeID, feedID: feed.itemID, feedURL: feed.canonicalURL,
                                                rssGUID: "episode-2", title: "Episode Two", publishedTime: feed.createdAt,
                                                enclosureURL: secondEpisodeURL, enclosureMediaType: "audio/mpeg", durationSeconds: 90,
                                                createdAt: feed.createdAt)
        let otherFeedURL = URL(string: "https://other.example.test/feed.xml")!
        let otherFeedID = try ItemID.derivePodcastFeed(from: otherFeedURL)
        let otherFeed = try PodcastFeed(itemID: otherFeedID, canonicalURL: otherFeedURL, title: "Other Show",
                                        createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_200)))
        let otherEpisodeURL = URL(string: "https://other.example.test/audio/episode.mp3")!
        let otherEpisodeID = try ItemID.derivePodcastEpisode(feedURL: otherFeedURL, rssGUID: "other-episode", enclosureURL: otherEpisodeURL)
        let otherEpisode = try PodcastEpisode(itemID: otherEpisodeID, feedID: otherFeedID, feedURL: otherFeedURL,
                                              rssGUID: "other-episode", title: "Other Episode", publishedTime: otherFeed.createdAt,
                                              enclosureURL: otherEpisodeURL, enclosureMediaType: "audio/mpeg", durationSeconds: 60,
                                              createdAt: otherFeed.createdAt)

        try await store.save(feed: feed); try await store.save(feed: otherFeed)
        try await store.save(episode: episode); try await store.save(episode: secondEpisode); try await store.save(episode: otherEpisode)

        let updatedFeed = try PodcastFeed(itemID: feed.itemID, canonicalURL: feed.canonicalURL, title: "Updated Wilted Show",
                                          author: "Updated Author", createdAt: feed.createdAt)
        let updatedEpisodeURL = URL(string: "https://podcasts.example.test/audio/episode-1-remastered.mp3")!
        let updatedEpisode = try PodcastEpisode(itemID: episode.itemID, feedID: feed.itemID, feedURL: feed.canonicalURL,
                                                rssGUID: episode.rssGUID, title: "Episode One Remastered",
                                                publishedTime: Timestamp(Date(timeIntervalSince1970: 1_700_000_101)),
                                                enclosureURL: updatedEpisodeURL, enclosureMediaType: "audio/mpeg",
                                                durationSeconds: 121, createdAt: episode.createdAt)
        try await store.save(feed: updatedFeed); try await store.save(episode: updatedEpisode)

        let loadedFeed = try await store.podcastFeed(for: feed.itemID)
        let loadedFeeds = try await store.podcastFeeds()
        let loadedEpisode = try await store.podcastEpisode(for: episode.itemID)
        let feedEpisodes = try await store.podcastEpisodes(for: feed.itemID)
        let allEpisodes = try await store.podcastEpisodes()
        XCTAssertEqual(loadedFeed, updatedFeed)
        XCTAssertEqual(loadedFeeds.map(\.itemID), [otherFeed.itemID, feed.itemID])
        XCTAssertEqual(loadedEpisode, updatedEpisode)
        XCTAssertEqual(feedEpisodes.map(\.itemID), [episode.itemID, secondEpisode.itemID])
        XCTAssertEqual(allEpisodes.count, 3)

        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: feed.createdAt))
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: feed.createdAt, enabled: false))
        let loadedSubscription = try await store.subscription(for: feed.itemID)
        let subscriptions = try await store.subscriptions()
        XCTAssertEqual(loadedSubscription?.enabled, false)
        XCTAssertEqual(subscriptions.count, 1)

        let queued = try PodcastDownload(episodeID: episode.itemID, updatedAt: feed.createdAt)
        let completed = try PodcastDownload(episodeID: episode.itemID, status: .completed, bytesReceived: 100,
                                             expectedByteCount: 100, localURL: URL(fileURLWithPath: "/tmp/episode.mp3"),
                                             contentHash: "sha256:" + String(repeating: "b", count: 64), updatedAt: feed.createdAt)
        try await store.save(download: queued); try await store.save(download: completed)
        let loadedDownload = try await store.download(for: episode.itemID)
        let downloads = try await store.downloads()
        XCTAssertEqual(loadedDownload, completed)
        XCTAssertEqual(downloads.count, 1)

        let artwork = try PodcastArtwork(id: "art-upsert", ownerID: feed.itemID, byteCount: 10, updatedAt: feed.createdAt)
        let updatedArtwork = try PodcastArtwork(id: artwork.id, ownerID: feed.itemID,
                                                localURL: URL(fileURLWithPath: "/tmp/art-updated.jpg"), byteCount: 20,
                                                updatedAt: feed.createdAt)
        try await store.save(artwork: artwork); try await store.save(artwork: updatedArtwork)
        let loadedArtwork = try await store.artwork(for: artwork.id)
        XCTAssertEqual(loadedArtwork, updatedArtwork)

        try await store.save(queueEntry: try PodcastQueueEntry(episodeID: episode.itemID, position: 1, addedAt: feed.createdAt))
        try await store.save(queueEntry: try PodcastQueueEntry(episodeID: secondEpisode.itemID, position: 0, addedAt: feed.createdAt))
        try await store.save(queueEntry: try PodcastQueueEntry(episodeID: episode.itemID, position: 2, addedAt: feed.createdAt))
        let queue = try await store.queue()
        XCTAssertEqual(queue.map(\.episodeID), [secondEpisode.itemID, episode.itemID])
        XCTAssertEqual(queue.map(\.position), [0, 1])

        try await store.save(playbackSpeed: try PodcastPlaybackSpeed(itemID: episode.itemID, speed: 1, updatedAt: feed.createdAt))
        let updatedSpeed = try PodcastPlaybackSpeed(itemID: episode.itemID, speed: 1.75, updatedAt: feed.createdAt)
        try await store.save(playbackSpeed: updatedSpeed)
        let loadedSpeed = try await store.playbackSpeed(for: episode.itemID)
        XCTAssertEqual(loadedSpeed, updatedSpeed)
    }

    func testPodcastRevisionResolutionPrefersNamespacedRowsPreservesLegacyAndAvoidsDuplicates() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (feed, firstEpisode) = try podcastValues()
        let secondEnclosureURL = URL(string: "https://podcasts.example.test/audio/episode-2.mp3")!
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feed.canonicalURL,
            rssGUID: "episode-2",
            enclosureURL: secondEnclosureURL
        )
        let secondEpisode = try PodcastEpisode(
            itemID: secondID, feedID: feed.itemID, feedURL: feed.canonicalURL, rssGUID: "episode-2",
            title: "Episode Two", enclosureURL: secondEnclosureURL, enclosureMediaType: "audio/mpeg",
            createdAt: firstEpisode.createdAt
        )
        try await store.save(feed: feed)
        try await store.save(episode: firstEpisode)
        try await store.save(episode: secondEpisode)

        let hash = "sha256:" + String(repeating: "c", count: 64)
        let legacyID = try RevisionID.derive(downloadedAudioContentHash: hash)
        let firstNamespacedID = try RevisionID.derive(
            podcastDownloadedAudioItemID: firstEpisode.itemID,
            contentHash: hash
        )
        let secondNamespacedID = try RevisionID.derive(
            podcastDownloadedAudioItemID: secondEpisode.itemID,
            contentHash: hash
        )
        XCTAssertNotEqual(firstNamespacedID, secondNamespacedID)

        func revision(_ itemID: ItemID, _ revisionID: RevisionID) throws -> AudioRevision {
            try AudioRevision(
                itemID: itemID, revisionID: revisionID, durationSeconds: 60, byteCount: 100,
                contentHash: hash, mediaType: "audio/mpeg", createdAt: firstEpisode.createdAt, schemaVersion: 3
            )
        }

        try await store.saveReadyRevision(
            revision(firstEpisode.itemID, legacyID),
            mediaURL: URL(fileURLWithPath: "/tmp/legacy-podcast.mp3")
        )
        let resolvedLegacy = try await store.resolvePodcastRevision(
            itemID: firstEpisode.itemID,
            contentHash: hash
        )
        XCTAssertEqual(resolvedLegacy, legacyID)

        try await store.saveReadyRevision(
            revision(firstEpisode.itemID, firstNamespacedID),
            mediaURL: URL(fileURLWithPath: "/tmp/namespaced-podcast.mp3")
        )
        let resolvedNamespaced = try await store.resolvePodcastRevision(
            itemID: firstEpisode.itemID,
            contentHash: hash
        )
        XCTAssertEqual(resolvedNamespaced, firstNamespacedID)

        let secondRevision = try revision(secondEpisode.itemID, secondNamespacedID)
        let secondURL = URL(fileURLWithPath: "/tmp/second-podcast.mp3")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await store.saveReadyRevision(secondRevision, mediaURL: secondURL) }
            }
            try await group.waitForAll()
        }
        let resolvedSecond = try await store.resolvePodcastRevision(
            itemID: secondEpisode.itemID,
            contentHash: hash
        )
        let secondRevisions = try await store.revisions(for: secondEpisode.itemID)
        let inspection = try await store.inspect()
        XCTAssertEqual(resolvedSecond, secondNamespacedID)
        XCTAssertEqual(secondRevisions.count, 1)
        XCTAssertEqual(inspection.revisionCount, 3)
    }

    func testPodcastDownloadValidationRequiresCompleteLocalMediaOnlyForCompleted() throws {
        let item = try ItemID(rawValue: "item-download-validation")
        let timestamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let hash = "sha256:" + String(repeating: "c", count: 64)
        XCTAssertThrowsError(try PodcastDownload(episodeID: item, status: .completed, bytesReceived: 10,
                                                 expectedByteCount: 10, updatedAt: timestamp))
        XCTAssertThrowsError(try PodcastDownload(episodeID: item, status: .completed, bytesReceived: 10,
                                                 expectedByteCount: 10, localURL: URL(fileURLWithPath: "/tmp/audio.mp3"),
                                                 updatedAt: timestamp))
        XCTAssertThrowsError(try PodcastDownload(episodeID: item, status: .completed, bytesReceived: 11,
                                                 expectedByteCount: 10, localURL: URL(fileURLWithPath: "/tmp/audio.mp3"),
                                                 contentHash: hash, updatedAt: timestamp))
        XCTAssertNoThrow(try PodcastDownload(episodeID: item, status: .queued, updatedAt: timestamp))
        XCTAssertNoThrow(try PodcastDownload(episodeID: item, status: .downloading, bytesReceived: 10,
                                             expectedByteCount: 100, updatedAt: timestamp))
        XCTAssertNoThrow(try PodcastDownload(episodeID: item, status: .failed, bytesReceived: 10,
                                             expectedByteCount: 10, updatedAt: timestamp))
        XCTAssertThrowsError(try PodcastArtwork(id: "art-invalid-hash", ownerID: item,
                                                 contentHash: "sha256:" + String(repeating: "A", count: 64), updatedAt: timestamp))
        XCTAssertNoThrow(try PodcastArtwork(id: "art-valid-hash", ownerID: item,
                                            contentHash: hash, updatedAt: timestamp))
    }

    func testWALCheckpointOutputRejectsBusyIncompleteOrUntruncatedResults() throws {
        XCTAssertNoThrow(try LocalLibraryStore.validateWALCheckpointOutputForTesting("0|0|0\n"))
        XCTAssertNoThrow(try LocalLibraryStore.validateWALCheckpointOutputForTesting("0|3|3\n", walByteCount: 0))
        XCTAssertThrowsError(try LocalLibraryStore.validateWALCheckpointOutputForTesting("1|3|3\n", walByteCount: 0))
        XCTAssertThrowsError(try LocalLibraryStore.validateWALCheckpointOutputForTesting("0|3|2\n", walByteCount: 0))
        XCTAssertThrowsError(try LocalLibraryStore.validateWALCheckpointOutputForTesting("0|3|3\n", walByteCount: 512))
        XCTAssertThrowsError(try LocalLibraryStore.validateWALCheckpointOutputForTesting("0|3\n", walByteCount: 0))
    }

    func testMigrationPreflightRetainsUsableV5FilesBeforeV6Migration() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "v5-forward")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item, playback: try playback(for: item, revision: rev, position: 21))
        let preflight = try LocalLibraryStore.migrationPreflight(at: url)
        XCTAssertTrue(preflight.retainedFiles.contains(where: { $0.lastPathComponent == url.lastPathComponent }))
        let retained = try LocalLibraryStore(url: preflight.retainedURL, migrate: false)
        let retainedArticle = try await retained.article(for: item.itemID)
        XCTAssertEqual(retainedArticle, item)
        let migrated = try LocalLibraryStore(url: url)
        let migratedArticle = try await migrated.article(for: item.itemID)
        let migratedPlayback = try await migrated.playbackState(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(migratedArticle, item)
        XCTAssertEqual(migratedPlayback?.positionSeconds, 21)
    }

    func testMigrationPreflightRenamesRetainedSidecarsAndRejectsSourceDirectoryDestination() throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "v5-custom-retention")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 4))
        let customURL = url.deletingLastPathComponent().appendingPathComponent("retained/backup.sqlite")
        let preflight = try LocalLibraryStore.migrationPreflight(at: url, retainingAt: customURL)
        XCTAssertEqual(preflight.retainedURL, customURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: customURL.path))
        XCTAssertTrue(preflight.retainedFiles.allSatisfy { $0.lastPathComponent == "backup.sqlite" || $0.lastPathComponent.hasPrefix("backup.sqlite-") })

        let unsafeURL = url.deletingLastPathComponent().appendingPathComponent("unsafe.sqlite")
        XCTAssertThrowsError(try LocalLibraryStore.migrationPreflight(at: url, retainingAt: unsafeURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafeURL.path))
    }

    func testV5RowsRemainReadableAfterAdditiveV6Migration() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "v5-all-rows")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 23))
        let migrated = try LocalLibraryStore(url: url)
        let inspection = try await migrated.inspect()
        XCTAssertEqual(inspection.schemaVersion, .v9)
        XCTAssertEqual(inspection.articleCount, 1)
        XCTAssertEqual(inspection.revisionCount, 1)
        XCTAssertEqual(inspection.transcriptCount, 1)
        XCTAssertEqual(inspection.preparationCount, 1)
        XCTAssertEqual(inspection.playbackCount, 1)
        let syncState = try await migrated.syncState(for: "private-zone")
        let tombstone = try await migrated.tombstone(for: "v5-tombstone")
        let transcript = try await migrated.transcript(for: item.itemID, revisionID: rev.revisionID)
        let journal = try await migrated.preparationJournal(for: "v5-request")
        let loadedPlayback = try await migrated.playbackState(for: item.itemID, revisionID: rev.revisionID)
        let repositoryState = try await migrated.syncRepositoryState()
        let expectedUpdatedAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_010))
        let expectedRevision = try AudioRevision(itemID: item.itemID, revisionID: rev.revisionID, durationSeconds: 42,
                                                  byteCount: 1, contentHash: "sha256:" + String(repeating: "5", count: 64),
                                                  mediaType: "audio/mp4", createdAt: expectedUpdatedAt, schemaVersion: 3)
        let expectedPlayback = try playback(for: item, revision: rev, position: 23)
        // Still schema version one and still untimed after the version-seven
        // migration: adding columns must not restate what an older row claimed.
        let expectedTranscript = try Transcript(itemID: item.itemID, revisionID: rev.revisionID,
                                                 availability: .available, text: "V5 transcript",
                                                 updatedAt: expectedUpdatedAt, schemaVersion: 1)
        let expectedStatus = try PreparationStatus(stage: .completed, detail: "V5 ready", fraction: 1,
                                                    cancellable: false,
                                                    terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: rev.revisionID),
                                                    emittedAt: expectedUpdatedAt)
        let expectedJournal = PreparationJournalEntry(id: "v5-prep", itemID: item.itemID, requestID: "v5-request", status: expectedStatus)
        let expectedTombstone = LocalLibraryTombstone(id: "v5-tombstone", itemID: item.itemID,
                                                      generationID: "v5-generation", requestedAt: expectedUpdatedAt)
        let migratedArticle = try await migrated.article(for: item.itemID)
        let migratedRevision = try await migrated.readyRevision(for: item.itemID)
        XCTAssertEqual(migratedArticle, item)
        XCTAssertEqual(migratedRevision?.revision, expectedRevision)
        XCTAssertEqual(migratedRevision?.mediaURL, URL(fileURLWithPath: "/tmp/v5.m4a"))
        XCTAssertEqual(loadedPlayback, expectedPlayback)
        XCTAssertEqual(transcript, expectedTranscript)
        XCTAssertEqual(journal, [expectedJournal])
        XCTAssertEqual(tombstone, expectedTombstone)
        XCTAssertEqual(syncState, LocalLibrarySyncState(key: "private-zone", engineState: Data([5]),
                                                         lastFetchAt: expectedUpdatedAt, lastSendAt: expectedUpdatedAt))
        XCTAssertEqual(repositoryState, SyncRepositoryState(engineState: Data([5])))
    }

    // MARK: - Podcast subscription admission

    /// Builds one feed's worth of episodes at fixed offsets from `origin`, so a
    /// test can say "published 40 days ago" without arithmetic at every call.
    private func episodes(
        feedURL: URL, origin: Date, daysAgo: [Int], undated: Int = 0
    ) throws -> (feed: PodcastFeed, episodes: [PodcastEpisode]) {
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show",
                                   author: nil, artworkURL: nil, createdAt: Timestamp(origin))
        func episode(_ guid: String, published: Date?) throws -> PodcastEpisode {
            let enclosureURL = URL(string: "\(feedURL.absoluteString.replacingOccurrences(of: "/feed.xml", with: ""))/\(guid).mp3")!
            return try PodcastEpisode(
                itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL),
                feedID: feedID, feedURL: feedURL, rssGUID: guid, title: guid,
                publishedTime: published.map(Timestamp.init), enclosureURL: enclosureURL,
                enclosureMediaType: "audio/mpeg", createdAt: Timestamp(origin)
            )
        }
        var built = try daysAgo.map { days in
            try episode("day-\(days)", published: origin.addingTimeInterval(-Double(days) * 86_400))
        }
        built.append(contentsOf: try (0..<undated).map { try episode("undated-\($0)", published: nil) })
        return (feed, built)
    }

    /// Subscribing must not empty a decade of back catalogue into the Larder,
    /// and must not present an empty feed either. The backfill window admits the
    /// recent episodes; a later refresh admits only what published after the
    /// subscription.
    func testSubscriptionBackfillAdmitsRecentEpisodesAndRefreshAdmitsOnlyNewerOnes() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/backfill/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 10, 29, 31, 400, 4_000])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let backfill = try await store.savePodcastEpisodes(all, admission: .backfill)
        XCTAssertEqual(Set(backfill.saved.map(\.rawValue)).count, 5,
                       "backfill admits the 30-day window plus the minimum-backfill floor")
        XCTAssertEqual(backfill.skipped, 1)
        var stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()

        XCTAssertEqual(stored, ["day-1", "day-10", "day-29", "day-31", "day-400"],
                       "the oldest episode is beyond both the window and the floor")

        // A refresh three days later: one genuinely new episode, everything else
        // already seen or older than the subscription.
        let later = origin.addingTimeInterval(3 * 86_400)
        let (_, refreshed) = try episodes(feedURL: feedURL, origin: later, daysAgo: [0])
        let increment = try await store.savePodcastEpisodes(all + refreshed, admission: .incremental)
        XCTAssertEqual(increment.skipped, 1, "only the episode outside the store and older than the horizon is refused")
        stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(stored, ["day-0", "day-1", "day-10", "day-29", "day-31", "day-400"])
    }

    /// An undated episode has no evidence it is new. Admitting it on every
    /// refresh would leak an undated back catalogue in one refresh at a time.
    func testUndatedEpisodesReachTheLarderOnlyThroughTheBackfillFloor() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/undated/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1], undated: 2)
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        // Subscribed before the dated episode published, so only the undated
        // ones are in question on the refresh.
        try await store.save(subscription: PodcastSubscription(
            feedID: feed.itemID, subscribedAt: Timestamp(origin.addingTimeInterval(-10 * 86_400))
        ))

        let refresh = try await store.savePodcastEpisodes(all, admission: .incremental)
        let afterRefresh = try await store.podcastEpisodes(for: feed.itemID).count
        XCTAssertEqual(refresh.skipped, 2)
        XCTAssertEqual(afterRefresh, 1)

        let backfill = try await store.savePodcastEpisodes(all, admission: .backfill)
        let afterBackfill = try await store.podcastEpisodes(for: feed.itemID).count
        XCTAssertEqual(backfill.skipped, 0)
        XCTAssertEqual(afterBackfill, 3)
    }

    /// The undated path is bounded, not open. A feed that dates nothing gets the
    /// backfill floor and no more, in the order the feed listed -- so the cap
    /// admits the newest items a dateless feed offers rather than an arbitrary
    /// five, and a later refresh adds none of the remainder.
    func testAnAllUndatedFeedIsCappedAtTheBackfillFloor() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/dateless/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [], undated: 8)
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let backfill = try await store.savePodcastEpisodes(all, admission: .backfill)
        let stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(backfill.saved.count, LocalLibraryStore.podcastSubscriptionMinimumBackfill)
        XCTAssertEqual(backfill.skipped, 3)
        XCTAssertEqual(stored, ["undated-0", "undated-1", "undated-2", "undated-3", "undated-4"])

        let refresh = try await store.savePodcastEpisodes(all, admission: .incremental)
        let afterRefresh = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(refresh.skipped, 3, "the remainder stays out on every later refresh")
        XCTAssertEqual(afterRefresh, stored)
    }

    /// Nothing already in the Larder may be evicted by the horizon rule -- a
    /// seeded episode older than the subscription has to survive every refresh.
    func testAnEpisodeAlreadyInTheStoreSurvivesEveryRefresh() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/seeded/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [500])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(episode: all[0])
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let result = try await store.savePodcastEpisodes(all, admission: .incremental)
        let stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(stored, ["day-500"])
    }

    /// A feed Wilted does not follow has no horizon to judge against, so the
    /// rule must not silently swallow it.
    func testEpisodesFromAnUnsubscribedFeedAreSavedUnconditionally() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/unfollowed/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 5_000])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)

        let result = try await store.savePodcastEpisodes(all, admission: .incremental)
        let stored = try await store.podcastEpisodes(for: feed.itemID).count
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(stored, 2)
    }

    /// Automation may only act on what one refresh actually brought in. `saved`
    /// includes every row the admission wrote, refreshed-in-place rows among
    /// them, so a download policy reading it would re-download the whole feed on
    /// every refresh. `newlyAdmitted` is the narrower answer.
    func testNewlyAdmittedNamesOnlyTheRowsOneAdmissionInserted() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/newly/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let first = try await store.savePodcastEpisodes(all, admission: .backfill)
        XCTAssertEqual(Set(first.newlyAdmitted), Set(first.saved), "a first admission inserts everything it saves")

        // The same feed, loaded again: every row is refreshed in place.
        let again = try await store.savePodcastEpisodes(all, admission: .incremental)
        XCTAssertEqual(again.saved.count, 2, "the rows are still written")
        XCTAssertEqual(again.newlyAdmitted, [], "but none of them is new")

        let later = origin.addingTimeInterval(86_400)
        let (_, refreshed) = try episodes(feedURL: feedURL, origin: later, daysAgo: [0])
        let increment = try await store.savePodcastEpisodes(all + refreshed, admission: .incremental)
        XCTAssertEqual(increment.newlyAdmitted, [refreshed[0].itemID],
                       "exactly the episode this refresh brought in")
    }

    /// Subscribing twice must not move the horizon. The backfill window is
    /// measured from `subscribedAt`, so re-subscribing through an equivalent URL
    /// -- a capitalised host, a fragment, an explicit :443 -- would otherwise
    /// silently re-admit a back catalogue the listener already dismissed.
    func testSubscribingAgainThroughAnEquivalentURLKeepsTheOriginalHorizon() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/idempotent/feed.xml")!
        let equivalentURL = URL(string: "https://Podcasts.Example.test:443/idempotent/feed.xml#latest")!
        let (feed, _) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)

        let inserted = try await store.subscribeIfNeeded(
            PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin))
        )
        XCTAssertTrue(inserted)

        let equivalentID = try ItemID.derivePodcastFeed(from: equivalentURL)
        XCTAssertEqual(equivalentID, feed.itemID, "canonicalisation collapses the two spellings")
        let repeated = try await store.subscribeIfNeeded(
            PodcastSubscription(feedID: equivalentID, subscribedAt: Timestamp(origin.addingTimeInterval(90 * 86_400)))
        )
        XCTAssertFalse(repeated, "the second subscription is refused, not merged")

        let subscriptions = try await store.subscriptions()
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.subscribedAt.date, origin, "the original horizon is untouched")
    }

    /// Unsubscribing clears every record the feed owned and leaves other feeds
    /// untouched. Media files are deliberately not deleted.
    func testUnsubscribingRemovesTheFeedsRecordsAndSparesOtherFeeds() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let goingURL = URL(string: "https://podcasts.example.test/going/feed.xml")!
        let stayingURL = URL(string: "https://podcasts.example.test/staying/feed.xml")!
        let (going, goingEpisodes) = try episodes(feedURL: goingURL, origin: origin, daysAgo: [1, 2])
        let (staying, stayingEpisodes) = try episodes(feedURL: stayingURL, origin: origin, daysAgo: [1])
        let store = try LocalLibraryStore(url: url)
        for (feed, list) in [(going, goingEpisodes), (staying, stayingEpisodes)] {
            try await store.save(feed: feed)
            try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
            for episode in list { try await store.save(episode: episode) }
        }
        for episode in goingEpisodes + stayingEpisodes {
            try await store.addPodcastQueueEpisode(episode.itemID)
            try await store.save(download: try PodcastDownload(episodeID: episode.itemID, updatedAt: Timestamp(origin)))
            try await store.save(playbackSpeed: try PodcastPlaybackSpeed(itemID: episode.itemID, speed: 1.5, updatedAt: Timestamp(origin)))
        }

        let removed = try await store.unsubscribeFromPodcast(feedID: going.itemID)
        let goneSubscription = try await store.subscription(for: going.itemID)
        let goneFeed = try await store.podcastFeed(for: going.itemID)
        let goneEpisodes = try await store.podcastEpisodes(for: going.itemID)
        XCTAssertEqual(removed, 2)
        XCTAssertNil(goneSubscription)
        XCTAssertNil(goneFeed)
        XCTAssertTrue(goneEpisodes.isEmpty)
        for episode in goingEpisodes {
            let download = try await store.download(for: episode.itemID)
            let speed = try await store.playbackSpeed(for: episode.itemID)
            XCTAssertNil(download)
            XCTAssertNil(speed)
        }
        let queue = try await store.queue().map(\.episodeID)
        let survivingSubscription = try await store.subscription(for: staying.itemID)
        let survivingEpisodes = try await store.podcastEpisodes(for: staying.itemID)
        let survivingDownload = try await store.download(for: stayingEpisodes[0].itemID)
        XCTAssertEqual(queue, stayingEpisodes.map(\.itemID))
        XCTAssertNotNil(survivingSubscription)
        XCTAssertEqual(survivingEpisodes.count, 1)
        XCTAssertNotNil(survivingDownload)
    }

    func testForcedMigrationFailureLeavesEveryCheckpointedStoreFileIdentical() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "v5-forced-failure")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 27))

        let failedURL = url.deletingLastPathComponent().appendingPathComponent("failed/library.sqlite")
        final class SnapshotCheck: @unchecked Sendable {
            var matched = false
            var retainedSidecar = false
        }
        let check = SnapshotCheck()
        XCTAssertThrowsError(try LocalLibraryStore(url: url, migrate: true,
                                                   migrationFailure: {
                                                       do {
                                                           let manager = FileManager.default
                                                           let sourceDirectory = url.deletingLastPathComponent()
                                                           let sourceFiles = try manager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
                                                               .filter { $0.lastPathComponent == url.lastPathComponent || $0.lastPathComponent.hasPrefix("\(url.lastPathComponent)-") }
                                                           let retainedFiles = try manager.contentsOfDirectory(at: failedURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                                                               .filter { $0.lastPathComponent == failedURL.lastPathComponent || $0.lastPathComponent.hasPrefix("\(failedURL.lastPathComponent)-") }
                                                           guard Set(sourceFiles.map(\.lastPathComponent)) == Set(retainedFiles.map(\.lastPathComponent)) else { throw ForcedMigrationFailure() }
                                                           check.retainedSidecar = sourceFiles.contains { $0.lastPathComponent.hasSuffix("-wal") || $0.lastPathComponent.hasSuffix("-shm") }
                                                           for sourceFile in sourceFiles {
                                                               let retainedFile = failedURL.deletingLastPathComponent().appendingPathComponent(sourceFile.lastPathComponent)
                                                               guard try Data(contentsOf: sourceFile) == Data(contentsOf: retainedFile) else { throw ForcedMigrationFailure() }
                                                           }
                                                           check.matched = true
                                                       } catch {
                                                           throw ForcedMigrationFailure()
                                                       }
                                                       throw ForcedMigrationFailure()
                                                   }, retainingAt: failedURL))
        XCTAssertTrue(check.retainedSidecar, "preflight must retain SQLite sidecars when the store provides them")
        XCTAssertTrue(check.matched, "retained post-checkpoint files must match the source before migration")
        let retainedFiles = try FileManager.default.contentsOfDirectory(
            at: failedURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent == failedURL.lastPathComponent || $0.lastPathComponent.hasPrefix("\(failedURL.lastPathComponent)-") }
        XCTAssertFalse(retainedFiles.isEmpty)
    }

    // MARK: - Episode removal

    /// The bug this covers: removing an episode used to hide it in memory only,
    /// so the next refresh -- which re-reads the same feed -- put it straight
    /// back, and so did the next launch.
    func testDismissedEpisodeIsDeletedAndNeverReadmittedByRefresh() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/dismiss/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2, 3])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        let unwanted = all.first { $0.rssGUID == "day-2" }!

        let deleted = try await store.dismissPodcastEpisode(unwanted.itemID, at: Timestamp(origin))
        XCTAssertTrue(deleted)
        var stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(stored, ["day-1", "day-3"], "the row is gone, not merely filtered")

        // The feed still lists it, which is the whole problem: a refresh offers
        // the same three episodes again.
        let refreshed = try await store.savePodcastEpisodes(all, admission: .incremental)
        XCTAssertFalse(refreshed.saved.contains(unwanted.itemID))
        XCTAssertEqual(refreshed.skipped, 1)
        stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(stored, ["day-1", "day-3"])

        // And it survives the process, because it is a row rather than a set.
        let reopened = try LocalLibraryStore(url: url)
        try await reopened.savePodcastEpisodes(all, admission: .incremental)
        stored = try await reopened.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(stored, ["day-1", "day-3"])
        let log = try await reopened.dismissedPodcastEpisodes()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.episodeID, unwanted.itemID)
        XCTAssertEqual(log.first?.feedID, feed.itemID)
        XCTAssertEqual(log.first?.title, "day-2")
        XCTAssertEqual(log.first?.dismissedAt, Timestamp(origin))
    }

    /// Removing twice must not throw, must not duplicate the log, and must not
    /// move the timestamp: the second call is a listener clicking again.
    func testDismissingAnEpisodeTwiceIsIdempotent() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/idempotent/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)

        let first = try await store.dismissPodcastEpisode(all[0].itemID, at: Timestamp(origin))
        let second = try await store.dismissPodcastEpisode(all[0].itemID, at: Timestamp(origin.addingTimeInterval(60)))
        XCTAssertTrue(first)
        XCTAssertFalse(second, "the row was already gone, so there is nothing left to delete")
        let log = try await store.dismissedPodcastEpisodes()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.dismissedAt, Timestamp(origin), "the first removal is when it happened")
    }

    /// Removal takes the queue entry, the download record, the saved speed, and
    /// the artwork with it -- otherwise Up Next keeps an episode the Larder no
    /// longer has.
    func testDismissingAnEpisodeClearsTheRecordsHangingOffIt() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/cascade/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        let doomed = all[0], kept = all[1]
        try await store.addPodcastQueueEpisode(doomed.itemID)
        try await store.addPodcastQueueEpisode(kept.itemID)

        try await store.dismissPodcastEpisode(doomed.itemID, at: Timestamp(origin))
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs.map(\.rawValue), [kept.itemID.rawValue],
                       "Up Next must not hold an episode the Larder removed")
    }

    /// Unsubscribing forgets the feed's dismissals too, so resubscribing does
    /// not inherit an invisible blocklist.
    func testUnsubscribingForgetsTheFeedsDismissals() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/forget/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        try await store.dismissPodcastEpisode(all[0].itemID, at: Timestamp(origin))

        try await store.unsubscribeFromPodcast(feedID: feed.itemID)
        let remaining = try await store.dismissedPodcastEpisodes()
        XCTAssertTrue(remaining.isEmpty)

        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        let stored = try await store.podcastEpisodes(for: feed.itemID).compactMap(\.rssGUID).sorted()
        XCTAssertEqual(stored, ["day-1", "day-2"], "resubscribing starts from the feed, not from the old blocklist")
    }

    /// Restore is one transaction backed by fresh feed evidence. The exact old
    /// target bypasses the subscription horizon while another genuinely new
    /// entry from the same response still follows incremental admission.
    func testRestoreReadmitsTheExactOldTargetAndIncrementallyAdmitsOtherEntries() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/restore/feed.xml")!
        let (feed, oldEntries) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [500])
        let target = try XCTUnwrap(oldEntries.first)
        let newEnclosure = URL(string: "https://podcasts.example.test/restore/new.mp3")!
        let newEpisode = try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "new-entry", enclosureURL: newEnclosure
            ),
            feedID: feed.itemID, feedURL: feedURL, rssGUID: "new-entry", title: "New entry",
            publishedTime: Timestamp(origin.addingTimeInterval(60)), enclosureURL: newEnclosure,
            enclosureMediaType: "audio/mpeg", createdAt: Timestamp(origin.addingTimeInterval(60))
        )
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feed.itemID, subscribedAt: Timestamp(origin)
        ))
        try await store.save(episode: target)
        try await store.dismissPodcastEpisode(target.itemID, at: Timestamp(origin))

        let result = try await store.restorePodcastEpisode(target, from: [target, newEpisode])
        XCTAssertTrue(result.restored)
        XCTAssertEqual(Set(result.saved), [target.itemID, newEpisode.itemID])
        XCTAssertEqual(result.skipped, 0)
        let stored = try await store.podcastEpisodes(for: feed.itemID)
        XCTAssertEqual(Set(stored.compactMap(\.rssGUID)), ["day-500", "new-entry"])
        let dismissals = try await store.dismissedPodcastEpisodes()
        XCTAssertTrue(dismissals.isEmpty)
    }

    /// Evidence for the wrong identity must not clear the durable dismissal.
    func testRestoreWithoutMatchingFeedEvidencePreservesDismissalAcrossRelaunch() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/restore-miss/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let target = all[0]
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.save(episode: target)
        try await store.dismissPodcastEpisode(target.itemID, at: Timestamp(origin))

        let result = try await store.restorePodcastEpisode(target, from: [all[1]])
        XCTAssertFalse(result.restored)
        let reopened = try LocalLibraryStore(url: url)
        let dismissals = try await reopened.dismissedPodcastEpisodes()
        let restoredEpisodes = try await reopened.podcastEpisodes(for: feed.itemID)
        XCTAssertEqual(dismissals.map(\.episodeID), [target.itemID])
        XCTAssertTrue(restoredEpisodes.isEmpty)
    }

    // MARK: - Automation claims

    /// Automation admits and claims in one save, and the claim is the download
    /// record rather than a table beside it.
    ///
    /// The cap takes the newest episodes because that is what a listener reaches
    /// for; feed parse order is not a preference.
    func testAutomaticAdmissionClaimsTheNewestNewEpisodesWithinTheCap() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/claims/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [5, 1, 4, 2, 3])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let claimedAt = Timestamp(origin.addingTimeInterval(60))
        let first = try await store.admitPodcastEpisodes(all, admission: .backfill,
                                                          claimingNewest: 3, claimedAt: claimedAt)
        XCTAssertEqual(first.admission.newlyAdmitted.count, 5)
        let claimedGUIDs = try await store.podcastEpisodes(for: feed.itemID)
            .filter { first.claimed.contains($0.itemID) }
            .compactMap(\.rssGUID).sorted()
        XCTAssertEqual(claimedGUIDs, ["day-1", "day-2", "day-3"],
                       "the cap takes the newest three, not the first three the feed listed")

        let downloads = try await store.downloads()
        XCTAssertEqual(downloads.count, 3)
        XCTAssertTrue(downloads.allSatisfy { $0.status == .queued && $0.updatedAt == claimedAt })

        // Nothing is newly admitted the second time, so nothing is claimed. This
        // is the duplicate-suppression case: a repeated refresh must not enqueue
        // the same episodes again.
        let repeated = try await store.admitPodcastEpisodes(all, admission: .incremental, claimingNewest: 3)
        XCTAssertEqual(repeated.admission.newlyAdmitted, [])
        XCTAssertEqual(repeated.claimed, [])
        let afterRepeat = try await store.downloads()
        XCTAssertEqual(afterRepeat.count, 3)
    }

    /// A manual download already in flight owns the episode. Automation admits
    /// it and moves on to the next one rather than starting a second transfer.
    func testAutomaticAdmissionSkipsAnEpisodeSomethingElseAlreadyHolds() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/held/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2, 3])
        let newest = try XCTUnwrap(all.first { $0.rssGUID == "day-1" })
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.save(download: PodcastDownload(episodeID: newest.itemID, status: .downloading,
                                                        bytesReceived: 512, updatedAt: Timestamp(origin)))

        let result = try await store.admitPodcastEpisodes(all, admission: .backfill, claimingNewest: 2)
        XCTAssertTrue(result.admission.newlyAdmitted.contains(newest.itemID),
                      "the episode is still admitted; only the claim is declined")
        XCTAssertFalse(result.claimed.contains(newest.itemID))
        let claimedGUIDs = try await store.podcastEpisodes(for: feed.itemID)
            .filter { result.claimed.contains($0.itemID) }
            .compactMap(\.rssGUID).sorted()
        XCTAssertEqual(claimedGUIDs, ["day-2", "day-3"])
        let held = try await store.download(for: newest.itemID)
        XCTAssertEqual(held?.status, .downloading, "the transfer in flight keeps its own state")
        XCTAssertEqual(held?.bytesReceived, 512)
    }

    /// A claim outlives the process that made it, and a relaunch finds it
    /// through the store rather than through anything automation kept.
    func testClaimsAndTheirAdmissionSurviveRelaunchTogether() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/recovery/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2, 3])
        var store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        let admitted = try await store.admitPodcastEpisodes(all, admission: .backfill, claimingNewest: 2)
        XCTAssertEqual(admitted.claimed.count, 2)

        store = try LocalLibraryStore(url: url)
        let unfinished = try await store.unfinishedPodcastDownloads()
        let recovered = try await store.podcastEpisodes(for: feed.itemID)
        XCTAssertEqual(Set(unfinished.map(\.episodeID)), Set(admitted.claimed))
        XCTAssertEqual(recovered.count, 3,
                       "the episodes the claims refer to are durable in the same save")

        // A finished claim is not resumable work. Reconciliation must not pick
        // it up again on every launch.
        let settled = try XCTUnwrap(admitted.claimed.first)
        try await store.save(download: PodcastDownload(episodeID: settled, status: .cancelled,
                                                        updatedAt: Timestamp(origin)))
        let stillUnfinished = try await store.unfinishedPodcastDownloads()
        XCTAssertEqual(stillUnfinished.map(\.episodeID), admitted.claimed.filter { $0 != settled })
    }

    /// Manual and automatic entry points race for the same episode. Exactly one
    /// wins, and the loser is told rather than left to start a second transfer.
    func testOnlyTheFirstClaimOnAnEpisodeWins() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let episodeID = try ItemID(rawValue: "item-" + String(repeating: "7", count: 64))
        let store = try LocalLibraryStore(url: url)

        let won = try await store.claimPodcastDownload(episodeID: episodeID, at: Timestamp(origin))
        let lost = try await store.claimPodcastDownload(episodeID: episodeID, at: Timestamp(origin.addingTimeInterval(1)))
        XCTAssertTrue(won)
        XCTAssertFalse(lost, "the second caller must not overwrite the first claim")
        let downloads = try await store.downloads()
        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(downloads.first?.updatedAt, Timestamp(origin), "the first claim stands unchanged")

        // A settled download still blocks automation: retrying it is the
        // listener's call, not something a later launch resumes on its own.
        try await store.save(download: PodcastDownload(episodeID: episodeID, status: .failed,
                                                        updatedAt: Timestamp(origin)))
        let automationAfterSettled = try await store.claimPodcastDownload(episodeID: episodeID)
        XCTAssertFalse(automationAfterSettled)

        // The row's own Retry is deliberate, so it takes the episode back and
        // starts from zero rather than inheriting the failed transfer's bytes.
        let retry = try await store.claimPodcastDownload(
            episodeID: episodeID, scope: .notInFlight, at: Timestamp(origin.addingTimeInterval(9))
        )
        XCTAssertTrue(retry)
        let reclaimed = try await store.download(for: episodeID)
        XCTAssertEqual(reclaimed?.status, .queued)
        XCTAssertEqual(reclaimed?.bytesReceived, 0)

        // A transfer in flight blocks even a deliberate request, which is the
        // case that would otherwise download one episode twice.
        let duringFlight = try await store.claimPodcastDownload(episodeID: episodeID, scope: .notInFlight)
        XCTAssertFalse(duringFlight)
    }

    /// The manual download policy admits exactly as it does today and enqueues
    /// nothing, so turning automation off cannot start a transfer.
    func testALimitOfZeroAdmitsWithoutClaimingAnything() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/manual/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))

        let manual = try await store.admitPodcastEpisodes(all, admission: .backfill, claimingNewest: 0)
        let equivalent = try await store.savePodcastEpisodes([], admission: .backfill)
        XCTAssertEqual(manual.admission.newlyAdmitted.count, 2)
        XCTAssertEqual(manual.claimed, [])
        XCTAssertEqual(equivalent.newlyAdmitted, [])
        let noDownloads = try await store.downloads()
        let noClaims = try await store.unfinishedPodcastDownloads()
        XCTAssertTrue(noDownloads.isEmpty)
        XCTAssertTrue(noClaims.isEmpty)
    }
}
