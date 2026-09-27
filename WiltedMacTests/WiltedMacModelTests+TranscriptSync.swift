import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Transcript synchronisation

    /// The reading position has to track the playback clock exactly, including
    /// before the first cue, across a boundary, and past the last one.
    func testCueLookupFollowsThePlaybackClock() {
        let transcript = WiltedMacTranscript(
            availability: .available, text: "one two three",
            cues: [
                WiltedMacTranscriptCue(id: 0, startSeconds: 2, endSeconds: 4, text: "one"),
                WiltedMacTranscriptCue(id: 1, startSeconds: 4, endSeconds: 6, text: "two"),
                WiltedMacTranscriptCue(id: 2, startSeconds: 6, endSeconds: 9, text: "three"),
            ],
            timingSource: "synced"
        )
        XCTAssertNil(transcript.cueIndex(at: 0), "nothing has been said yet")
        XCTAssertNil(transcript.cueIndex(at: 1.99))
        XCTAssertEqual(transcript.cueIndex(at: 2), 0)
        XCTAssertEqual(transcript.cueIndex(at: 3.9), 0)
        XCTAssertEqual(transcript.cueIndex(at: 4), 1)
        XCTAssertEqual(transcript.cueIndex(at: 8.5), 2)
        XCTAssertEqual(transcript.cueIndex(at: 500), 2, "past the end stays on the last line")
        XCTAssertTrue(transcript.isSynchronized)
        XCTAssertEqual(transcript.disclosureTitle, "Transcript · synced")
    }

    /// Cues arrive in order but may overlap, and a large episode carries
    /// thousands of them: the lookup must stay correct at both ends.
    func testCueLookupHandlesALongEpisode() {
        let cues = (0..<5_000).map {
            WiltedMacTranscriptCue(id: $0, startSeconds: Double($0) * 2,
                                   endSeconds: Double($0) * 2 + 2.5, text: "line \($0)")
        }
        let transcript = WiltedMacTranscript(availability: .available, text: "long",
                                             cues: cues, timingSource: "synced")
        XCTAssertEqual(transcript.cueIndex(at: 0), 0)
        XCTAssertEqual(transcript.cueIndex(at: 4_999), 2_499)
        XCTAssertEqual(transcript.cueIndex(at: 9_998), 4_999)
    }

    /// A plain-text transcript is still readable; it just cannot be followed.
    func testAnUntimedTranscriptIsReadableButNotSynchronized() {
        let transcript = WiltedMacTranscript(availability: .available, text: "Words with no timing.")
        XCTAssertTrue(transcript.isReadable)
        XCTAssertFalse(transcript.isSynchronized)
        XCTAssertNil(transcript.cueIndex(at: 10))
        XCTAssertEqual(transcript.disclosureTitle, "Transcript")
    }

    /// The wiring the feature actually rests on: the player is what reads a
    /// transcript, and until this landed the episode path set `.unavailable`
    /// unconditionally, so a timed transcript in the library was unreachable.
    func testPlayingAnEpisodeSurfacesItsSyncedTranscript() async throws {
        let directory = temporaryDirectory("episode-transcript")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("episode.m4a")

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/synced.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/synced.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "synced-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Synced", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "synced-1",
                    title: "Synced episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                let assembled = try AudioAssembler().assemble(
                    pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
                    itemID: episodeID, destinationURL: audioURL
                )
                try await store.finalizePodcastDownload(
                    revision: assembled.revision, mediaURL: audioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed,
                        bytesReceived: assembled.revision.byteCount,
                        expectedByteCount: assembled.revision.byteCount,
                        localURL: audioURL, contentHash: assembled.revision.contentHash,
                        updatedAt: created
                    )
                )
                try await store.save(transcript: try Transcript(
                    itemID: episodeID, revisionID: assembled.revision.revisionID,
                    availability: .available, text: "First line. Second line.",
                    timing: .published,
                    cues: [try TranscriptCue(startSeconds: 0, endSeconds: 0.5, text: "First line."),
                           try TranscriptCue(startSeconds: 0.5, endSeconds: 1.0, text: "Second line.")],
                    updatedAt: created
                ))
                try await store.record(preparation: PreparationJournalEntry(
                    id: "prep-synced", itemID: episodeID, requestID: "podcast-prepare|synced",
                    status: try PreparationStatus(
                        stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                        terminalResult: try PreparationTerminalResult(
                            outcome: .succeeded, revisionID: assembled.revision.revisionID
                        ),
                        emittedAt: created,
                        timeline: try PreparationStatus.PreparationTimeline(
                            removed: [try .init(originalStartSeconds: 30, originalEndSeconds: 90,
                                                label: "advertisement", confidence: 0.9)],
                            kept: [try .init(originalStartSeconds: 0, originalEndSeconds: 30, outputStartSeconds: 0),
                                   try .init(originalStartSeconds: 90, originalEndSeconds: 200, outputStartSeconds: 30)]
                        )
                    )
                ))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        try await settle(model)
        defer { model.togglePlayback() }

        let transcript = try XCTUnwrap(model.currentTranscript)
        XCTAssertTrue(transcript.isSynchronized, "playing an episode has to surface its timed transcript")
        XCTAssertEqual(transcript.cues.map(\.text), ["First line.", "Second line."])
        XCTAssertEqual(transcript.disclosureTitle, "Transcript \u{00B7} synced from the feed")
        XCTAssertEqual(transcript.cueIndex(at: 0.6), 1)

        // What preparation cut, placed where the listener meets it: the
        // seam is on the prepared clock the cues are stamped in, and the
        // span it names is on the original clock, which is what Prep reports
        // for the same run.
        let spans = model.currentRemovedSpans
        XCTAssertEqual(spans.count, 1, "a prepared episode says what came out of it")
        XCTAssertEqual(spans.first?.preparedSeconds, 30)
        XCTAssertEqual(spans.first?.originalStartSeconds, 30)
        XCTAssertEqual(spans.first?.originalEndSeconds, 90)
        XCTAssertEqual(spans.first?.summary, "Ad removed \u{00B7} 1:00 \u{00B7} original 0:30–1:30")
    }

    /// An episode the listener is finished with early has no other way to
    /// close out: progress is written from where the audio is, so it stays at
    /// the abandoned position for good and the Larder goes on offering it.
    /// The press has to reach the durable record and retire the row, the same
    /// as playing the episode to its end does -- a control whose only effect
    /// is a scrubber jumping to the end is indistinguishable from one that
    /// did nothing.
    func testMarkingTheCurrentEpisodeCompletedRetiresItFromTheLarder() async throws {
        let directory = temporaryDirectory("episode-mark-completed")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("episode.m4a")

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/completed.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/completed.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "completed-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Finished", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "completed-1",
                    title: "Finished episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                let assembled = try AudioAssembler().assemble(
                    pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
                    itemID: episodeID, destinationURL: audioURL
                )
                try await store.finalizePodcastDownload(
                    revision: assembled.revision, mediaURL: audioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed,
                        bytesReceived: assembled.revision.byteCount,
                        expectedByteCount: assembled.revision.byteCount,
                        localURL: audioURL, contentHash: assembled.revision.contentHash,
                        updatedAt: created
                    )
                )
                try await store.savePreparationOutcome(PodcastPreparationOutcome(
                    episodeID: episodeID, revisionID: assembled.revision.revisionID,
                    policyDigest: "fixture-policy", pipelineFingerprint: "fixture-fingerprint",
                    semanticVersion: "fixture-semantic-version", producedAt: created
                ))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        XCTAssertFalse(episode.isPlayed)
        model.playEpisode(episode)
        try await settle(model)
        XCTAssertFalse(model.playbackCompleted)

        model.markCurrentPlaybackCompleted()
        try await settle(model)
        XCTAssertTrue(model.playbackCompleted, "the player has to stop offering to mark what it just marked")
        XCTAssertFalse(model.isPlaying, "marking an episode finished stops the audio")

        XCTAssertLessThan(model.playbackPositionSeconds, model.playbackDurationSeconds,
                          "the playhead stays where the listener left it; only the completed flag is written")

        let retired = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue },
                                    "retirement is not dismissal -- the row survives, just off the shelf")
        XCTAssertNotNil(retired.retiredAt)
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == episodeID.rawValue },
                       "saying \"I am done with this\" takes it off the shelf, the same as playing it to the end")
        XCTAssertFalse(model.dismissedEpisodes.contains { $0.id == episodeID.rawValue },
                       "retirement is not a dismissal -- nothing was deleted")
        XCTAssertEqual(model.podcastOperationMessage, "Finished \(episode.title).")
        XCTAssertTrue(model.playbackCompletionIsSettled,
                      "both halves are done, so the control has nothing left to offer")
    }

    /// Reported 2026-09-07: an episode marked completed on a build that wrote
    /// the record without retiring the row stayed in the Larder, and the
    /// control that would have retired it read "Completed" and was disabled.
    /// The record and the shelf can still disagree after Phase 5's bootstrap
    /// sweep -- a completion synced from iPhone against a revision this
    /// device has since re-downloaded, for instance, which the sweep
    /// deliberately leaves alone rather than retiring sight unseen -- so the
    /// press has to remain available until the row is actually gone, and it
    /// has to finish the half that was skipped rather than repeat the half
    /// that was not.
    func testAnEpisodeAlreadyMarkedCompletedCanStillBeRetired() async throws {
        let directory = temporaryDirectory("episode-completed-not-retired")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("episode.m4a")

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/stranded.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/stranded.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "stranded-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Stranded", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "stranded-1",
                    title: "Stranded episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                let assembled = try AudioAssembler().assemble(
                    pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
                    itemID: episodeID, destinationURL: audioURL
                )
                try await store.finalizePodcastDownload(
                    revision: assembled.revision, mediaURL: audioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed,
                        bytesReceived: assembled.revision.byteCount,
                        expectedByteCount: assembled.revision.byteCount,
                        localURL: audioURL, contentHash: assembled.revision.contentHash,
                        updatedAt: created
                    )
                )
                try await store.savePreparationOutcome(PodcastPreparationOutcome(
                    episodeID: episodeID, revisionID: assembled.revision.revisionID,
                    policyDigest: "fixture-policy", pipelineFingerprint: "fixture-fingerprint",
                    semanticVersion: "fixture-semantic-version", producedAt: created
                ))
                // The state a sync from another device can leave behind:
                // finished on the record, with no retirement to take the row
                // off the shelf. The listening fact names a revision this
                // device does not currently have ready -- e.g. synced before
                // a local re-download -- so the bootstrap sweep in
                // `startStoreBootstrap()` must not retire it, leaving the
                // press with real work still to do.
                try await store.save(playback: try PlaybackState(
                    itemID: episodeID, revisionID: assembled.revision.revisionID,
                    sessionID: "stranded-session", sequence: 3,
                    positionSeconds: assembled.revision.durationSeconds,
                    durationSeconds: assembled.revision.durationSeconds,
                    completed: true, intent: .progress, deviceID: "stranded-device",
                    updatedAt: created
                ))
                try await store.saveListening(PodcastListeningState(
                    episodeID: episodeID, completedAt: created,
                    lastRevisionID: try RevisionID(rawValue: "stranded-superseded-revision"),
                    updatedAt: created
                ))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        XCTAssertTrue(episode.isPlayed, "the record survived; only the retirement was missed")
        model.playEpisode(episode)
        try await settle(model)

        XCTAssertTrue(model.playbackCompleted, "the loaded record still says finished")
        XCTAssertFalse(model.playbackCompletionIsSettled,
                       "the row is still on the shelf, so the press still has work to do")

        model.markCurrentPlaybackCompleted()
        try await settle(model)

        let retired = try XCTUnwrap(model.episodes.first { $0.id == episodeID.rawValue },
                                    "retirement is not dismissal -- the row survives, just off the shelf")
        XCTAssertNotNil(retired.retiredAt, "pressing it a second time has to retire the row the first press never did")
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == episodeID.rawValue })
        XCTAssertFalse(model.dismissedEpisodes.contains { $0.id == episodeID.rawValue })
        XCTAssertTrue(model.playbackCompletionIsSettled,
                      "and then stop offering, because there is nothing left to finish")
    }

    /// Placement is the whole point: a cut is meaningless unless it sits where
    /// the audio jumps. The seam is the end of the last kept interval carried
    /// onto the output clock, so the second cut of an episode has to account
    /// for everything removed ahead of it rather than reporting its original
    /// time.
    func testRemovedSpansArePlacedOnThePreparedClock() throws {
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 60, originalEndSeconds: 120, label: "advertisement", confidence: 0.9),
                      try .init(originalStartSeconds: 600, originalEndSeconds: 690, label: "sponsor", confidence: 0.8)],
            kept: [try .init(originalStartSeconds: 0, originalEndSeconds: 60, outputStartSeconds: 0),
                   try .init(originalStartSeconds: 120, originalEndSeconds: 600, outputStartSeconds: 60),
                   try .init(originalStartSeconds: 690, originalEndSeconds: 1_200, outputStartSeconds: 540)]
        )
        let spans = WiltedMacModel.removedSpans(in: timeline)
        XCTAssertEqual(spans.map(\.preparedSeconds), [60, 540],
                       "the second cut lands a minute earlier than its original time, because the first was removed")
        XCTAssertEqual(spans.map(\.originalStartSeconds), [60, 600])
        XCTAssertEqual(spans.map(\.summary), [
            "Ad removed \u{00B7} 1:00 \u{00B7} original 1:00–2:00",
            "Ad removed \u{00B7} 1:30 \u{00B7} original 10:00–11:30",
        ])
    }

    /// A cut that opens the episode has nothing kept ahead of it, so it sits
    /// at the very start rather than being dropped or placed by a fallback
    /// that happens to also be zero for a different reason.
    func testACutAtTheStartOfAnEpisodeSitsAtZero() throws {
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 0, originalEndSeconds: 30, label: "advertisement", confidence: 0.9)],
            kept: [try .init(originalStartSeconds: 30, originalEndSeconds: 600, outputStartSeconds: 0)]
        )
        XCTAssertEqual(WiltedMacModel.removedSpans(in: timeline).map(\.preparedSeconds), [0])
    }

    /// The transcript pane merges cues and cuts onto one clock. A marker
    /// belongs before the first line that starts at or after it: it describes
    /// audio the listener is about to not hear, so interrupting the line
    /// already in progress would put it a beat too late.
    func testRemovedMarkersAreMergedBeforeTheLineTheyPrecede() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Before."),
            WiltedTranscriptCueLine(id: 1, startSeconds: 60, text: "After."),
            WiltedTranscriptCueLine(id: 2, startSeconds: 90, text: "Later."),
        ]
        let markers = [
            WiltedTranscriptMarkerLine(id: 1, atSeconds: 95, text: "Ad removed"),
            WiltedTranscriptMarkerLine(id: 0, atSeconds: 60, text: "Ad removed"),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, markers: markers, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.rows.map(\.id), ["cue-0", "marker-0", "cue-1", "cue-2", "marker-1"],
                       "markers sort into the cues by time, and one past the last line still shows")

        let withoutMarkers = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil, identifier: "test") { _ in }
        XCTAssertEqual(withoutMarkers.rows.map(\.id), ["cue-0", "cue-1", "cue-2"])
    }

    /// Following the audio means handing `ScrollViewReader` the identity the
    /// row actually carries. When markers joined the list, row identity became
    /// a `String` while auto-scroll still passed the cue's `Int`, so the active
    /// line stayed highlighted but was never scrolled into view.
    func testTheScrollTargetMatchesTheRowIdentityOfTheActiveCue() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Before."),
            WiltedTranscriptCueLine(id: 41, startSeconds: 60, text: "After."),
        ]
        let markers = [WiltedTranscriptMarkerLine(id: 0, atSeconds: 30, text: "Ad removed")]
        let view = WiltedSyncedTranscriptView(cues: cues, markers: markers, activeCueID: 41,
                                              identifier: "test") { _ in }
        let target = WiltedSyncedTranscriptView.Row.scrollTarget(forCueID: 41)
        XCTAssertTrue(view.rows.contains { $0.id == target },
                      "the scroll target has to be a row identity, or a lazy list cannot resolve it")
        XCTAssertEqual(view.rows.first { $0.id == target }.map { row -> Int? in
            if case .cue(let cue) = row { return cue.id }
            return nil
        } ?? nil, 41, "and it has to be the active cue's row, not a marker that happens to share a number")
        XCTAssertNotEqual(target, WiltedSyncedTranscriptView.Row.scrollTarget(forCueID: 0))
    }

    /// A name is drawn where the voice changes, not on every line. An
    /// interview alternates two people for an hour, and repeating both names
    /// down the whole transcript is noise the reader reads past to find words.
    func testTheSpeakerIsLabelledOnlyWhereItChanges() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Welcome.", speaker: "Angie"),
            WiltedTranscriptCueLine(id: 1, startSeconds: 5, text: "Still me.", speaker: "Angie"),
            WiltedTranscriptCueLine(id: 2, startSeconds: 10, text: "Thanks.", speaker: "Chris"),
            WiltedTranscriptCueLine(id: 3, startSeconds: 15, text: "Back again.", speaker: "Angie"),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.speakerHeadingCueIDs, [0, 2, 3],
                       "the first attributed line always says who is talking, then only changes do")
    }

    /// Publishers attribute the line that changes hands and leave the rest
    /// bare. Treating a bare line as "unknown speaker" would redraw the name
    /// on every line after it.
    func testAnUnattributedLineDoesNotEndTheSpeakersRun() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Welcome.", speaker: "Angie"),
            WiltedTranscriptCueLine(id: 1, startSeconds: 5, text: "No attribution here."),
            WiltedTranscriptCueLine(id: 2, startSeconds: 10, text: "Still Angie.", speaker: "Angie"),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.speakerHeadingCueIDs, [0])
    }

    func testATranscriptThatNamesNobodyLabelsNothing() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "One."),
            WiltedTranscriptCueLine(id: 1, startSeconds: 5, text: "Two."),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertTrue(view.speakerHeadingCueIDs.isEmpty)
    }

    /// The visual heading is `accessibilityHidden` so the name is not read
    /// twice. That makes the spoken label the only place a reader using
    /// VoiceOver learns the voice changed.
    func testTheSpokenLabelCarriesTheNameExactlyWhereTheHeadingDoes() {
        let named = WiltedTranscriptCueLine(id: 0, startSeconds: 65, text: "Welcome.", speaker: "Angie")
        let view = WiltedSyncedTranscriptView(cues: [named], activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.spokenLabel(named, showsSpeaker: true), "1:05. Angie. Welcome.")
        XCTAssertEqual(view.spokenLabel(named, showsSpeaker: false), "1:05. Welcome.")
    }

}
