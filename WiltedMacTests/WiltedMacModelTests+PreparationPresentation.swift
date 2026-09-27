import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Preparation presentation

    func testPreparationLabelsSpeakToTheListenerNotTheWorker() {
        let cases: [(String, String)] = [
            ("transcript.published.fetch", "Fetching the published transcript…"),
            ("transcript.stt.start", "Transcribing the audio…"),
            ("transcript.glossary.progress", "Correcting names from the show notes…"),
            ("transcript.glossary.complete", "Correcting names from the show notes…"),
            ("ads.detect.start", "Finding advertisements…"),
            ("ads.cut.refused", "Advertisements left in place."),
            ("audio.publish", "Storing the prepared audio…"),
            ("pipeline.complete", "Prepared."),
        ]
        for (stage, expected) in cases {
            XCTAssertEqual(
                WiltedMacModel.preparationLabel(for: PodcastPreparationProgress(stage: stage)),
                expected, "stage \(stage)"
            )
        }
        // An unrecognised stage still says something rather than going blank.
        XCTAssertEqual(
            WiltedMacModel.preparationLabel(for: PodcastPreparationProgress(stage: "something.new")),
            "Preparing…"
        )
    }

    /// Only a successful terminal journal for the ready revision proves that
    /// an episode is prepared; transcript timing is descriptive, not proof.
    func testPreparationStateComesFromWhatTheLibraryCanProve() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "7", count: 64))
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "7", count: 64))
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        func transcript(_ timing: TranscriptTiming, _ availability: TranscriptAvailability = .available) throws -> Transcript {
            try Transcript(
                itemID: itemID, revisionID: revisionID, availability: availability,
                text: availability == .available ? "Words." : nil, timing: timing,
                cues: timing == .none ? nil : [try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "Words.")],
                updatedAt: when
            )
        }

        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: nil, readyRevisionID: revisionID,
                                                       transcript: nil), .notPrepared)
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: nil, readyRevisionID: revisionID,
                                                       transcript: try transcript(.published)), .notPrepared)
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: nil, readyRevisionID: revisionID,
                                                       transcript: try transcript(.aligned)), .notPrepared)
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: nil, readyRevisionID: revisionID,
                                                       transcript: try transcript(.none)), .notPrepared)

        let failed = PreparationRunSummary(
            requestID: "podcast-prepare|" + itemID.rawValue, itemID: itemID, startedAt: when, updatedAt: when,
            stage: .failed, detail: "Wilted could not start the preparation pipeline.",
            fraction: nil, isTerminal: true, outcome: .failed, failure: nil
        )
        // The row says only that it failed; the reason and the log are on Prep.
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: failed, readyRevisionID: revisionID,
                                                       transcript: nil),
                       .failed(WiltedMacModel.preparationFailedLabel))
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: failed, readyRevisionID: revisionID,
                                                       transcript: try transcript(.aligned)),
                       .failed(WiltedMacModel.preparationFailedLabel))

        let running = PreparationRunSummary(
            requestID: failed.requestID, itemID: itemID, startedAt: when, updatedAt: when,
            stage: .extracting, detail: "Transcribing", fraction: nil, isTerminal: false,
            outcome: nil, failure: nil
        )
        XCTAssertEqual(WiltedMacModel.preparationState(outcome: nil, run: running, readyRevisionID: revisionID,
                                                       transcript: try transcript(.aligned)),
                       .preparing(stage: "Preparing…"))

        // A proven outcome is not demoted by a later run's own failure -- a
        // re-preparation that changed nothing must not un-prepare the episode.
        let outcome = PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID, policyDigest: "d",
                                                pipelineFingerprint: "f", semanticVersion: "v", producedAt: when)
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: outcome, run: failed, readyRevisionID: revisionID,
                                            transcript: try transcript(.aligned)),
            .prepared(summary: "\(PodcastPreparationResult.readyLabel) · \(PodcastPreparationResult.transcriptStep(.aligned))")
        )
        // A legacy-invalidated outcome is not proof, even for the ready revision.
        let invalidated = PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID, policyDigest: "d",
                                                    pipelineFingerprint: "f", semanticVersion: "v", producedAt: when,
                                                    eligibility: .invalid)
        XCTAssertEqual(
            WiltedMacModel.preparationState(outcome: invalidated, run: nil, readyRevisionID: revisionID,
                                            transcript: try transcript(.aligned)),
            .notPrepared
        )
    }

    func testEpisodePreparationStateLarderLabelsShowOnlyProvenCompletedSummary() {
        XCTAssertNil(WiltedMacEpisodePreparationState.notPrepared.larderLabel)

        let summary = "Ready · 5 ads removed (7:22) · transcript synced"
        let prepared = WiltedMacEpisodePreparationState.prepared(summary: summary)
        XCTAssertEqual(prepared.label, summary)
        XCTAssertEqual(prepared.larderLabel, summary)

        let preparing = WiltedMacEpisodePreparationState.preparing(stage: "Preparing…")
        XCTAssertEqual(preparing.label, "Preparing…")
        XCTAssertEqual(preparing.larderLabel, "Preparing…")

        let failed = WiltedMacEpisodePreparationState.failed(WiltedMacModel.preparationFailedLabel)
        XCTAssertEqual(failed.label, WiltedMacModel.preparationFailedLabel)
        XCTAssertEqual(failed.larderLabel, WiltedMacModel.preparationFailedLabel)
    }

    func testEpisodeLifecyclePresentationCoversPrecedenceAndAvailableDetails() {
        let cases: [(
            download: WiltedMacEpisodeDownloadState,
            preparation: WiltedMacEpisodePreparationState,
            expected: String,
            failure: Bool
        )] = [
            (.notDownloaded, .prepared(summary: "Ready \u{00B7} transcript synced"), "Not downloaded", false),
            (.queued, .failed("old failure"), "Download queued", false),
            (.downloading(received: 2, expected: 10), .prepared(summary: "Ready"), "Downloading 20%", false),
            (.downloading(received: 1, expected: nil), .notPrepared, "Downloading 1 byte", false),
            (.downloading(received: 0, expected: nil), .notPrepared, "Downloading", false),
            (.failed, .prepared(summary: "Ready"), "Download failed", true),
            (.cancelled, .preparing(stage: "Finding advertisements\u{2026}"), "Download cancelled", false),
            (.completed, .notPrepared, "Downloaded \u{00B7} Ready to prepare", false),
            (.completed, .preparing(stage: "Queued"), "Preparing \u{00B7} Queued", false),
            (.completed, .preparing(stage: "Preparing\u{2026}"), "Preparing", false),
            (.completed, .prepared(summary: "Ready \u{00B7} 5 ads removed \u{00B7} transcript synced"),
             "Prepared \u{00B7} 5 ads removed \u{00B7} transcript synced", false),
            (.completed, .failed("Preparation failed. See Prep."), "Preparation failed \u{00B7} See Prep.", true),
        ]

        for value in cases {
            let presentation = WiltedMacEpisodeLifecyclePresentation(
                downloadState: value.download,
                preparationState: value.preparation
            )
            XCTAssertEqual(presentation.label, value.expected)
            XCTAssertEqual(presentation.isFailure, value.failure)
        }
    }

    func testArticlePlaybackStateLoadsFromStore() async throws {
        let directory = temporaryDirectory("article-playback-state")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let articleURL = try XCTUnwrap(URL(string: "https://example.test/article-progress"))
        let itemID = try ItemID.derive(from: articleURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let article = try Article(
            itemID: itemID, canonicalURL: articleURL, title: "Partly heard",
            source: "Example", createdAt: created
        )
        let audioURL = directory.appendingPathComponent("article.m4a")
        let assembled = try AudioAssembler().assemble(
            pcm: (0..<(44_100 * 2)).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
            itemID: itemID, destinationURL: audioURL
        )
        let playback = try PlaybackState(
            itemID: itemID, revisionID: assembled.revision.revisionID,
            sessionID: "article-progress", sequence: 1, positionSeconds: 0.75,
            durationSeconds: assembled.revision.durationSeconds, completed: false,
            intent: .progress, deviceID: "test-device", updatedAt: created
        )
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(article: article)
                try await store.save(revision: assembled.revision, mediaURL: audioURL)
                try await store.save(playback: playback)
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let loaded = try XCTUnwrap(model.articles.first)
        XCTAssertEqual(loaded.playbackSeconds, 0.75)
        XCTAssertFalse(loaded.isPlayed)
        XCTAssertEqual(try XCTUnwrap(loaded.durationSeconds, "the loaded article did not carry a duration"),
                       try XCTUnwrap(assembled.revision.durationSeconds, "the assembled revision did not carry a duration"), accuracy: 0.001,
                       "the saved position and the assembled audio's duration both survive the store load")
    }

    func testLivePlaybackReadoutTracksScrubbingWithoutStoreReload() async throws {
        let directory = temporaryDirectory("live-playback-readout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let article = try XCTUnwrap(model.articles.first)
        XCTAssertEqual(article.durationSeconds, 120)

        model.openNowPlaying(for: article)
        await model.waitForPlaybackOperationForTesting()
        model.scrub(to: 60)
        for _ in 0..<100 {
            model.refreshPlaybackReadout()
            if model.playbackPositionSeconds == 60 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.playbackPositionSeconds, 60)
    }

    func testSwitchingPlaybackItemsRetainsOutgoingProgress() async throws {
        let directory = temporaryDirectory("switch-playback-progress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let first = try XCTUnwrap(model.articles.first)
        let second = WiltedMacArticle(
            id: "second-article", title: "Second", source: "Example",
            url: URL(string: "https://example.test/second")!, isReady: true,
            durationSeconds: 120
        )
        model.installArticleForTesting(second)
        model.openNowPlaying(for: first)
        await model.waitForPlaybackOperationForTesting()
        model.scrub(to: 60)
        for _ in 0..<100 {
            model.refreshPlaybackReadout()
            if model.playbackPositionSeconds == 60 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        model.openNowPlaying(for: second)
        await model.waitForPlaybackOperationForTesting()

        // The outgoing article's progress is checkpointed before the overlay
        // moves; the destination does not inherit it.
        XCTAssertEqual(model.articles.first(where: { $0.id == first.id })?.playbackSeconds, 60)
        XCTAssertEqual(model.articles.first(where: { $0.id == second.id })?.playbackSeconds, 0)
    }

    func testFailedArticleSwitchDoesNotCopyOutgoingProgressIntoDestination() async throws {
        let directory = temporaryDirectory("failed-switch-playback-progress")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let first = try XCTUnwrap(model.articles.first)
        let second = WiltedMacArticle(
            id: "failed-destination", title: "Failed destination", source: "Example",
            url: URL(string: "https://example.test/failed-destination")!, isReady: true,
            durationSeconds: 120
        )
        model.installArticleForTesting(second)
        model.openNowPlaying(for: first)
        await model.waitForPlaybackOperationForTesting()
        model.scrub(to: 60)
        for _ in 0..<100 {
            model.refreshPlaybackReadout()
            if model.playbackPositionSeconds == 60 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Selection changes before an asynchronous load completes. Leaving
        // the controller on the first item models the failure boundary.
        model.beginArticlePlaybackTransitionForTesting(second)
        model.refreshPlaybackReadout()

        XCTAssertEqual(model.articles.first(where: { $0.id == first.id })?.playbackSeconds, 60)
        XCTAssertEqual(model.articles.first(where: { $0.id == second.id })?.playbackSeconds, 0)
    }

    func testUnavailableTranscriptProjectsAudioReadyWithoutPreparedPrefix() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "9", count: 64))
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "9", count: 64))
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let run = PreparationRunSummary(
            requestID: WiltedMacModel.podcastRequestPrefix + itemID.rawValue,
            itemID: itemID, startedAt: when, updatedAt: when, stage: .completed,
            detail: "Prepared · no ads found · transcript not synced", fraction: nil,
            isTerminal: true, outcome: .succeeded, failure: nil,
            entries: [PreparationJournalEntry(
                id: "terminal", itemID: itemID,
                requestID: WiltedMacModel.podcastRequestPrefix + itemID.rawValue,
                status: try PreparationStatus(
                    stage: .completed, detail: "Prepared · no ads found · transcript not synced",
                    cancellable: false,
                    terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: revisionID),
                    emittedAt: when
                )
            )]
        )
        let outcome = PodcastPreparationOutcome(episodeID: itemID, revisionID: revisionID, policyDigest: "d",
                                                pipelineFingerprint: "f", semanticVersion: "v", producedAt: when)
        let state = WiltedMacModel.preparationState(outcome: outcome, run: run, readyRevisionID: revisionID,
                                                    transcript: nil)
        XCTAssertEqual(state, .prepared(summary: "Audio ready · Transcript unavailable"))
        XCTAssertEqual(
            WiltedMacEpisodeLifecyclePresentation(downloadState: .completed, preparationState: state).label,
            "Audio ready · Transcript unavailable"
        )
    }

    func testEpisodePlaybackIndicatorsKeepCurrentPlaybackOutOfUpNext() throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let current = try XCTUnwrap(model.episodes.first)
        let queuedID = "queued-episode"

        model.installPlaybackStateForTesting(
            episode: current,
            isPlaying: true,
            position: 1,
            duration: 10,
            queue: [current.id, queuedID]
        )
        XCTAssertEqual(model.episodePlaybackIndicators(for: current.id), ["Playing"])
        XCTAssertEqual(model.episodePlaybackIndicators(for: queuedID), ["In Larder"])

        model.installPlaybackStateForTesting(
            episode: current,
            isPlaying: false,
            position: 1,
            duration: 10,
            queue: [current.id, queuedID]
        )
        XCTAssertEqual(model.episodePlaybackIndicators(for: current.id), ["Now Playing"])
        XCTAssertFalse(model.episodePlaybackIndicators(for: current.id).contains("In Larder"))
    }

    func testPreparedLifecycleSeparatesStatusFromExplicitOutcomes() {
        let presentation = WiltedMacEpisodeLifecyclePresentation(
            downloadState: .completed,
            preparationState: .prepared(summary: "Ready · 3 ads removed · transcript synced")
        )

        XCTAssertEqual(presentation.primaryLabel, "Prepared")
        XCTAssertEqual(presentation.detailLabel, "3 ads removed · transcript synced")
        XCTAssertEqual(presentation.label, "Prepared · 3 ads removed · transcript synced")
    }

    func testPlaybackAndMenuActionsRequireCompletedPreparation() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let base = WiltedMacEpisode(
            id: "episode-state-contract", title: "State contract", feedTitle: "Fixtures",
            summary: "Fixture", artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed,
            preparationState: .notPrepared
        )

        XCTAssertFalse(model.canPlayEpisode(base))
        XCTAssertFalse(model.canAddEpisodeToMenu(base))
        XCTAssertTrue(WiltedMacModel.isEligibleForPreparation(base))

        var preparing = base
        preparing.preparationState = .preparing(stage: "Transcribing")
        XCTAssertFalse(model.canPlayEpisode(preparing))
        XCTAssertFalse(model.canAddEpisodeToMenu(preparing))
        XCTAssertFalse(WiltedMacModel.isEligibleForPreparation(preparing))

        var prepared = base
        prepared.preparationState = .prepared(summary: "Ready · no ads found · transcript synced")
        XCTAssertTrue(model.canPlayEpisode(prepared))
        XCTAssertTrue(model.canAddEpisodeToMenu(prepared))
        XCTAssertFalse(WiltedMacModel.isEligibleForPreparation(prepared))
    }

    func testMenuUpcomingKeepsEveryDurableEntryAroundThePlayingOne() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        func entry(_ id: String, at published: TimeInterval) -> WiltedMacEpisode {
            WiltedMacEpisode(
                id: id, title: id, feedTitle: "Fixtures", summary: "Fixture",
                artworkURL: nil, releasedAt: Date(timeIntervalSince1970: published), durationSeconds: 600,
                playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready · no ads found · transcript synced")
            )
        }
        let current = entry("menu-current", at: 1_700_000_000)
        let earlier = entry("menu-earlier", at: 1_699_000_000)
        let next = entry("menu-next", at: 1_701_000_000)
        let later = entry("menu-later", at: 1_702_000_000)
        for value in [earlier, next, later] { model.installEpisodeForTesting(value) }
        model.installPlaybackStateForTesting(
            episode: current, isPlaying: true, position: 12, duration: 600,
            queue: [earlier.id, current.id, next.id, later.id]
        )

        XCTAssertEqual(model.menuUpcomingEpisodeIDs, [earlier.id, next.id, later.id],
                       "the active podcast is represented by Now Playing, while entries on either side remain waiting")
        XCTAssertEqual(model.menuDisplayEpisodeIDs, [earlier.id, current.id, next.id, later.id],
                       "the sort projection keeps the entries around the playing one too")
        XCTAssertEqual(model.episodePlaybackIndicators(for: current.id), ["Playing"])
        XCTAssertEqual(model.episodePlaybackIndicators(for: next.id), ["In Larder"])
    }

}
