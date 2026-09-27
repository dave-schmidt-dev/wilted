import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
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
                                                 superseding: originalID,
                                                 outcome: PodcastPreparationOutcome(
                                                    episodeID: episodeID, revisionID: preparedID, policyDigest: "d",
                                                    pipelineFingerprint: "f", semanticVersion: "v", producedAt: when))
            XCTFail("expected the store to refuse a mismatched download")
        } catch LocalLibraryStoreError.invalidPodcastState { }
        let untouched = try await store.revisions(for: episodeID)
        XCTAssertEqual(untouched.map(\.revision.revisionID), [originalID])

        try await store.replaceReadyRevision(prepared, mediaURL: preparedURL, transcript: preparedTranscript,
                                             download: try download(preparedHash, preparedURL, bytes: 80),
                                             superseding: originalID,
                                             outcome: PodcastPreparationOutcome(
                                                episodeID: episodeID, revisionID: preparedID, policyDigest: "d",
                                                pipelineFingerprint: "f", semanticVersion: "v", producedAt: when),
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

    /// Phase 4 gate, literal form: the outcome row alone -- with no journal
    /// entry ever written -- is durable proof of readiness across a relaunch.
    /// This is the no-audio-change success path (`saveReadyRevision`), which
    /// never touches the journal at all.
    func testSaveReadyRevisionOutcomeSurvivesRelaunchWithNoJournalEntryAtAll() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/no-journal.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://cdn.example.test/no-journal.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "nj1", enclosureURL: enclosureURL)
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "d", count: 64))
        let mediaURL = URL(fileURLWithPath: "/tmp/no-journal/audio.mp3")
        let hash = "sha256:" + String(repeating: "d", count: 64)
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let revision = try AudioRevision(itemID: episodeID, revisionID: revisionID, durationSeconds: 30, byteCount: 40,
                                         contentHash: hash, mediaType: "audio/mpeg", createdAt: when, schemaVersion: 3)
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: mediaURL,
            download: try PodcastDownload(episodeID: episodeID, status: .completed, bytesReceived: 40,
                                          expectedByteCount: 40, localURL: mediaURL, contentHash: hash, updatedAt: when)
        )
        let transcript = try Transcript(itemID: episodeID, revisionID: revisionID, availability: .available,
                                        text: "No ads to cut.", updatedAt: when)
        let outcome = PodcastPreparationOutcome(episodeID: episodeID, revisionID: revisionID, policyDigest: "d",
                                                pipelineFingerprint: "f", semanticVersion: "v", producedAt: when)

        try await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: transcript, outcome: outcome)
        let journal = try await store.preparationJournal(for: PodcastPreparationPipeline.requestID(for: episodeID))
        XCTAssertTrue(journal.isEmpty, "the outcome must prove readiness without any journal entry at all")

        let firstReopen = try LocalLibraryStore(url: url)
        let firstOutcome = try await firstReopen.preparationOutcome(for: episodeID, revisionID: revisionID)
        XCTAssertEqual(firstOutcome, outcome)

        let secondReopen = try LocalLibraryStore(url: url)
        let secondOutcome = try await secondReopen.preparationOutcome(for: episodeID, revisionID: revisionID)
        XCTAssertEqual(secondOutcome, outcome, "the outcome row must not oscillate across repeated reopens")
        XCTAssertEqual(firstOutcome, secondOutcome)
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

}
