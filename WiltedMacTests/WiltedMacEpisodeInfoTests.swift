import XCTest
import SwiftData
import WiltedDomain
@testable import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacEpisodeInfoTests: XCTestCase {
    func testEpisodeInfoFailureFixturesRequireFixtureModeAndExplicitFlags() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let storedEpisode = try episode(
            WiltedMacHistoryStoreFixture.Feed("fixture-opt-in").episode("stored", title: "Real stored title"),
            notes: "Real stored notes")
        try await fixture.store.savePodcastEpisodes([storedEpisode], admission: .backfill)
        let saved = try transcript(
            for: storedEpisode.itemID, revisionID: RevisionID(rawValue: "revision-" + String(repeating: "e", count: 64)),
            availability: .available, text: "Real stored transcript.")
        try await fixture.store.save(transcript: saved)
        let liveModel = try await makeModel(fixture)
        XCTAssertFalse(liveModel.fixtureMode)
        for flag in [
            "--wilted-ui-fixture-info-read-fails-once",
            "--wilted-ui-fixture-transcript-read-fails-once",
        ] {
            XCTAssertNil(liveModel.fixtureEpisodeInfoSource(
                id: storedEpisode.itemID.rawValue, showTitle: "Stored show", arguments: [flag]),
                "failure flags alone must not inject a source into a live model")
        }

        let fixtureModel = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("episode-info-fixture-opt-in"),
            storeBootstrap: { _ in fixture.store }, preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await fixtureModel.close() }
        XCTAssertTrue(fixtureModel.fixtureMode)
        XCTAssertNil(fixtureModel.fixtureEpisodeInfoSource(
            id: storedEpisode.itemID.rawValue, showTitle: "Stored show", arguments: ["--wilted-ui-fixture-ready"]),
            "ordinary fixture mode must not inject failures without an explicit failure flag")
        // Fixture startup bypasses asynchronous bootstrap. Bind the isolated
        // fixture store to verify the ordinary factory still reads its rows.
        fixtureModel.store = fixture.store
        for model in [liveModel, fixtureModel] {
            let source = model.episodeInfoSource(id: storedEpisode.itemID.rawValue, showTitle: "Stored show")
            for _ in 0..<2 {
                let details = await source.loadInfo()
                guard case let .loaded(info) = details else {
                    return XCTFail("the default source must read the real stored episode without injected failure")
                }
                XCTAssertEqual(info.title, storedEpisode.title)
                XCTAssertEqual(info.notes, "Real stored notes")
                let result = await source.loadTranscript()
                guard case let .loaded(transcript) = result else {
                    return XCTFail("the default source must read the real stored transcript without injected failure")
                }
                XCTAssertEqual(transcript.text, saved.text)
            }
        }
    }

    func testFixtureReadFailuresSurviveSourceRebuildAndRemainIndependentByEpisode() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let feed = try WiltedMacHistoryStoreFixture.Feed("fixture-source-rebuild")
        let stored = try episode(feed.episode("first", title: "Stored title"), notes: "Stored notes")
        let independent = try feed.episode("second", title: "Independent title")
        try await fixture.store.savePodcastEpisodes([stored, independent], admission: .backfill)
        let saved = try transcript(
            for: stored.itemID,
            revisionID: RevisionID(rawValue: "revision-" + String(repeating: "f", count: 64)),
            availability: .available, text: "Saved rebuilt-source transcript.")
        try await fixture.store.save(transcript: saved)
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("episode-info-source-rebuild"),
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        await model.fixtureInstallTask?.value
        model.store = fixture.store
        let flags = [
            "--wilted-ui-fixture-info-read-fails-once",
            "--wilted-ui-fixture-transcript-read-fails-once",
        ]
        let first = try XCTUnwrap(model.fixtureEpisodeInfoSource(
            id: stored.itemID.rawValue, showTitle: "Stored show", arguments: flags))
        let failedInfo = await first.loadInfo()
        let failedTranscript = await first.loadTranscript()
        XCTAssertEqual(failedInfo, .failed)
        XCTAssertEqual(failedTranscript, .failed)

        // SwiftUI may construct the source again before Retry runs its next task.
        let rebuilt = try XCTUnwrap(model.fixtureEpisodeInfoSource(
            id: stored.itemID.rawValue, showTitle: "Stored show", arguments: flags))
        let recoveredInfo = await rebuilt.loadInfo()
        let recoveredTranscript = await rebuilt.loadTranscript()
        guard case let .loaded(info) = recoveredInfo,
              case let .loaded(transcript) = recoveredTranscript else {
            return XCTFail("a rebuilt source must recover through the real store after the first failure")
        }
        XCTAssertEqual(info.title, stored.title)
        XCTAssertEqual(info.notes, "Stored notes")
        XCTAssertEqual(transcript.text, saved.text)

        let second = try XCTUnwrap(model.fixtureEpisodeInfoSource(
            id: independent.itemID.rawValue, showTitle: "Stored show", arguments: flags))
        let independentInfo = await second.loadInfo()
        let independentTranscript = await second.loadTranscript()
        XCTAssertEqual(independentInfo, .failed, "another episode retains its own first failure")
        XCTAssertEqual(independentTranscript, .failed, "another episode retains its own first failure")
    }

    func testSavedTranscriptWithCorruptNewestRecordFailsWithoutOlderFallback() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let episode = try WiltedMacHistoryStoreFixture.Feed("corrupt-transcript").episode("corrupt", title: "Corrupt")
        let older = try transcript(
            for: episode.itemID, revisionID: RevisionID(rawValue: "revision-" + String(repeating: "a", count: 64)),
            availability: .available, text: "Valid older text.")
        try await fixture.store.save(transcript: older)
        let newest = try Transcript(
            itemID: episode.itemID,
            revisionID: RevisionID(rawValue: "revision-" + String(repeating: "b", count: 64)),
            availability: .available, text: "Corrupt newest text.",
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_001)))
        let context = ModelContext(fixture.store.container)
        let corrupt = try LocalLibrarySchemaV7Models.TranscriptRecord(newest)
        corrupt.availability = "corrupt-availability"
        context.insert(corrupt)
        try context.save()

        let model = try await makeModel(fixture)
        let playing = WiltedMacTranscript(availability: .available, text: "Now Playing sentinel")
        model.currentTranscript = playing
        let result = await model.savedTranscript(forEpisodeID: episode.itemID.rawValue)
        XCTAssertEqual(result, .failed, "corruption must offer Retry, not no-transcript copy or older text")
        XCTAssertEqual(model.currentTranscript, playing)
    }

    func testSavedTranscriptForRetiredEpisodeLoadsWithoutTouchingCurrentTranscript() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let episode = try WiltedMacHistoryStoreFixture.Feed("retired-transcript").episode("retired", title: "Retired")
        let revisionID = try RevisionID(rawValue: "revision-" + String(repeating: "a", count: 64))
        try await fixture.store.savePodcastEpisodes([episode], admission: .backfill)
        try await fixture.store.save(transcript: transcript(
            for: episode.itemID, revisionID: revisionID, availability: .available,
            text: "Saved after retirement.", timing: .published
        ))
        let retired = try await fixture.store.retireEpisode(episode.itemID, at: fixture.at(1))
        XCTAssertTrue(retired)

        let model = try await makeModel(fixture)
        let playing = WiltedMacTranscript(availability: .available, text: "Now Playing sentinel")
        model.currentTranscript = playing
        let result = await model.savedTranscript(forEpisodeID: episode.itemID.rawValue)

        guard case let .loaded(saved) = result else {
            return XCTFail("the retained transcript should load")
        }
        XCTAssertEqual(saved.availability, .available)
        XCTAssertEqual(saved.text, "Saved after retirement.")
        XCTAssertEqual(saved.timingSource, "synced from the feed")
        XCTAssertEqual(saved.cues.map(\.text), ["Saved after retirement."])
        XCTAssertEqual(model.currentTranscript, playing)
    }

    func testSavedTranscriptAfterDismissalIsNone() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let episode = try WiltedMacHistoryStoreFixture.Feed("dismissed-transcript").episode("dismissed", title: "Dismissed")
        let revisionID = try RevisionID(rawValue: "revision-" + String(repeating: "b", count: 64))
        try await fixture.store.savePodcastEpisodes([episode], admission: .backfill)
        try await fixture.store.save(transcript: transcript(
            for: episode.itemID, revisionID: revisionID, availability: .available, text: "Gone"
        ))
        let dismissed = try await fixture.store.dismissPodcastEpisode(episode.itemID, at: fixture.at(2))
        XCTAssertTrue(dismissed)

        let model = try await makeModel(fixture)
        let result = await model.savedTranscript(forEpisodeID: episode.itemID.rawValue)
        XCTAssertEqual(result, .none)
    }

    func testSavedTranscriptWithNoStoreFails() async throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "d", count: 64))
        let result = await model.savedTranscript(forEpisodeID: itemID.rawValue)
        XCTAssertEqual(result, .failed)
    }

    func testEpisodeInfoPrefersModelEpisodesThenStore() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let episode = try WiltedMacHistoryStoreFixture.Feed("info-preference").episode("same", title: "Stored title")
        try await fixture.store.savePodcastEpisodes([episode], admission: .backfill)
        let model = try await makeModel(fixture)
        let inMemory = WiltedMacEpisode(
            id: episode.itemID.rawValue, title: "Current title", feedTitle: "Current show", summary: "",
            notes: "Current notes", artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_123),
            durationSeconds: 42, playbackSeconds: 0, downloadState: .notDownloaded,
            preparationState: .notPrepared
        )
        model.installEpisodeForTesting(inMemory)

        let result = await model.episodeInfo(id: episode.itemID.rawValue, showTitle: "Store show")
        guard case let .loaded(info) = result else {
            return XCTFail("the model episode should resolve")
        }
        XCTAssertEqual(info.title, "Current title")
        XCTAssertEqual(info.notes, "Current notes")
        XCTAssertEqual(info.presentation.showTitle, "Current show")
        XCTAssertEqual(info.presentation.sourceDurationSeconds, 42)
    }

    func testEpisodeInfoLoadsNotesForRetiredAndDismissedRows() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let feed = try WiltedMacHistoryStoreFixture.Feed("info-removals")
        let retired = try episode(feed.episode("retired", title: "Retired row"), notes: "Retired notes")
        let dismissed = try episode(feed.episode("dismissed", title: "Dismissed row"), notes: "Dismissed notes")
        try await fixture.store.savePodcastEpisodes([retired, dismissed], admission: .backfill)
        let retiredResult = try await fixture.store.retireEpisode(retired.itemID, at: fixture.at(3))
        let dismissedResult = try await fixture.store.dismissPodcastEpisode(dismissed.itemID, at: fixture.at(4))
        XCTAssertTrue(retiredResult)
        XCTAssertTrue(dismissedResult)

        let model = try await makeModel(fixture)
        for (id, title, notes) in [
            (retired.itemID.rawValue, "Retired row", "Retired notes"),
            (dismissed.itemID.rawValue, "Dismissed row", "Dismissed notes"),
        ] {
            let result = await model.episodeInfo(id: id, showTitle: "History show")
            guard case let .loaded(info) = result else {
                return XCTFail("stored \(title) should resolve")
            }
            XCTAssertEqual(info.title, title)
            XCTAssertEqual(info.notes, notes)
            XCTAssertEqual(info.presentation.showTitle, "History show")
        }
    }

    func testEpisodeInfoNotFound() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let model = try await makeModel(fixture)
        let missing = try WiltedMacHistoryStoreFixture.Feed("missing-info").episode("missing", title: "Missing")
        let result = await model.episodeInfo(id: missing.itemID.rawValue, showTitle: nil)
        XCTAssertEqual(result, .notFound)
    }

    func testNowPlayingTranscriptLoadStillMapsAvailabilityAndTiming() async throws {
        let fixture = try WiltedMacHistoryStoreFixture(self)
        let episode = try WiltedMacHistoryStoreFixture.Feed("now-playing-transcript").episode("playing", title: "Playing")
        let revisionID = try RevisionID(rawValue: "revision-" + String(repeating: "c", count: 64))
        let stored = try transcript(
            for: episode.itemID, revisionID: revisionID, availability: .stale,
            text: "Timed words.", timing: .aligned
        )
        try await fixture.store.save(transcript: stored)
        let model = try await makeModel(fixture)

        let backend = WiltedMacScriptedBackend()
        model.installPlaybackBackendForTesting(backend)
        let revision = try AudioRevision(
            itemID: episode.itemID, revisionID: revisionID, durationSeconds: 60, byteCount: 1,
            contentHash: "sha256:" + String(repeating: "c", count: 64), mediaType: "audio/mp4",
            createdAt: Timestamp(Date()), schemaVersion: 1
        )
        try await model.playback?.load(StoredAudioRevision(
            revision: revision, mediaURL: wiltedTemporaryDirectory("presentation-mapping").appendingPathComponent("synthetic.m4a")))
        await model.loadTranscript(itemID: episode.itemID, revisionID: revisionID)

        let loaded = try XCTUnwrap(model.currentTranscript)
        XCTAssertEqual(loaded.availability, .stale)
        XCTAssertEqual(loaded.text, "Timed words.")
        XCTAssertEqual(loaded.timingSource, "synced")
        XCTAssertEqual(loaded.cues.count, 1)
        XCTAssertEqual(loaded.cues[0].startSeconds, 0)
        XCTAssertEqual(loaded.cues[0].endSeconds, 1)
        XCTAssertEqual(loaded.cues[0].text, "Timed words.")
    }

    private func makeModel(_ fixture: WiltedMacHistoryStoreFixture) async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("episode-info"),
            storeBootstrap: { _ in fixture.store },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
    }

    private func transcript(
        for itemID: ItemID, revisionID: RevisionID, availability: TranscriptAvailability,
        text: String, timing: TranscriptTiming = .none
    ) throws -> Transcript {
        try Transcript(
            itemID: itemID, revisionID: revisionID, availability: availability, text: text,
            timing: timing,
            cues: timing == .none ? nil : [try TranscriptCue(startSeconds: 0, endSeconds: 1, text: text)],
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
    }

    private func episode(_ source: PodcastEpisode, notes: String) throws -> PodcastEpisode {
        try PodcastEpisode(
            itemID: source.itemID, feedID: source.feedID, feedURL: source.feedURL, rssGUID: source.rssGUID,
            title: source.title, author: source.author, publishedTime: source.publishedTime,
            enclosureURL: source.enclosureURL, enclosureMediaType: source.enclosureMediaType,
            enclosureByteCount: source.enclosureByteCount, durationSeconds: source.durationSeconds,
            artworkURL: source.artworkURL, transcriptSources: source.transcriptSources, notes: notes,
            episodeLink: source.episodeLink, createdAt: source.createdAt
        )
    }
}
