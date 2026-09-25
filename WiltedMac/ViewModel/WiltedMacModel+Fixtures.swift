import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

extension WiltedMacModel {
#if canImport(WiltedProducer)
    func installFixture(ready: Bool, preparing: Bool = false, podcasts: Bool = false) {
        if preparing {
            let url = URL(string: "https://example.test/wilted-preparing-fixture")!
            guard let itemID = try? ItemID.derive(from: url) else { return }
            articles = [WiltedMacArticle(
                id: itemID.rawValue, title: "Preparing article", source: "Example source",
                url: url, isReady: false, durationSeconds: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
            return
        }
        guard ready, let store else { return }
        let url = URL(string: "https://example.test/wilted-fixture")!
        guard let itemID = try? ItemID.derive(from: url),
              let article = try? Article(
                itemID: itemID, canonicalURL: url, title: "Fixture article", source: "Example source",
                createdAt: Timestamp(Date())
              ),
              let revisionID = try? RevisionID(rawValue: "fixture-revision"),
              let revision = try? AudioRevision(
                itemID: itemID, revisionID: revisionID, durationSeconds: 120, byteCount: 1,
                contentHash: "sha256:\(String(repeating: "0", count: 64))", mediaType: "audio/mp4",
                createdAt: Timestamp(Date()), schemaVersion: 1
              ) else { return }
        let mediaURL = URL(fileURLWithPath: "/tmp/wilted-fixture.m4a")
        fixtureRevision = StoredAudioRevision(revision: revision, mediaURL: mediaURL)
        let fixtureTranscript = try? Transcript(
            itemID: itemID,
            revisionID: revisionID,
            availability: .available,
            text: "This fixture transcript proves saved article text stays readable while listening.",
            updatedAt: Timestamp(Date())
        )
        articles = [WiltedMacArticle(
            id: itemID.rawValue, title: article.title, source: article.source,
            url: article.canonicalURL, isReady: true, durationSeconds: revision.durationSeconds,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]
        if podcasts { installPodcastFixture(in: store) }
        Task {
            try? await store.save(article: article)
            if let fixtureTranscript {
                try? await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: fixtureTranscript)
            } else {
                try? await store.saveReadyRevision(revision, mediaURL: mediaURL)
            }
        }
    }

    /// The fixture's prepared episode reads the way a real one does after a
    /// relaunch: the journal's terminal summary, not just "synced".
    static let fixturePreparedSummary = "Ready · 5 ads removed (7:22) · transcript synced"

    /// A two-voice interview transcript for the fixture episode.
    ///
    /// Published timing rather than aligned, because a publisher's WebVTT is
    /// the only thing that names anyone -- speech-to-text produces no speaker,
    /// so an aligned fixture could not show the labels at all. Two people
    /// alternating is the case the display rule exists for: the name is drawn
    /// where the voice changes, and the run of lines in between carries none.
    private static func fixtureEpisodeTranscript(
        episodeID: ItemID, revisionID: RevisionID, isLong: Bool
    ) -> Transcript? {
        let lines: [(Double, Double, String, String?)]
        if isLong {
            guard let timeline = fixtureLongTranscriptTimeline else { return nil }
            lines = (0..<105).compactMap { originalIndex in
                let originalStart = Double(originalIndex * 14)
                let originalEnd = originalStart + 14
                guard let keep = timeline.kept.first(where: {
                    $0.originalStartSeconds <= originalStart && $0.originalEndSeconds >= originalEnd
                }) else { return nil }
                let preparedStart = keep.outputStartSeconds + originalStart - keep.originalStartSeconds
                return (preparedStart, preparedStart + 14, "Long prepared cue \(originalIndex).", nil)
            }
        } else {
            lines = [
                (0, 6, "Welcome back to Field Notes. Today, the machines that keep the office quiet.", "Angie"),
                (6, 13, "Thanks for having me. I have opinions about ventilation.", "Chris"),
                (13, 20, "Everyone does, eventually.", nil),
                (20, 28, "Let us start with the one under the stairs.", "Angie"),
            ]
        }
        let cues = lines.compactMap {
            try? TranscriptCue(startSeconds: $0.0, endSeconds: $0.1, text: $0.2, speaker: $0.3)
        }
        guard cues.count == lines.count else { return nil }
        return try? Transcript(
            itemID: episodeID, revisionID: revisionID, availability: .available,
            text: cues.map(\.text).joined(separator: " "),
            languageCode: "en", timing: .published, cues: cues,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200))
        )
    }

    /// A valid prepared-audio timeline with several cuts. The scrolling
    /// fixture reads these through the same persisted journal path as a real
    /// prepared episode, so marker rows are not invented by the view.
    private static var fixtureLongTranscriptTimeline: PreparationStatus.PreparationTimeline? {
        let cutBounds: [(Double, Double)] = [
            (168, 182), (336, 350), (504, 518), (672, 686),
            (840, 854), (1_008, 1_022), (1_176, 1_190), (1_320, 1_334),
        ]
        let removed = cutBounds.compactMap {
            try? PreparationStatus.PreparationTimeline.RemovedInterval(
                originalStartSeconds: $0.0, originalEndSeconds: $0.1,
                label: "advertisement", confidence: 0.9
            )
        }
        guard removed.count == cutBounds.count else { return nil }

        var kept: [PreparationStatus.PreparationTimeline.KeptInterval] = []
        var originalStart = 0.0
        var outputStart = 0.0
        for cut in cutBounds {
            guard let interval = try? PreparationStatus.PreparationTimeline.KeptInterval(
                originalStartSeconds: originalStart, originalEndSeconds: cut.0, outputStartSeconds: outputStart
            ) else { return nil }
            kept.append(interval)
            outputStart += cut.0 - originalStart
            originalStart = cut.1
        }
        guard let finalInterval = try? PreparationStatus.PreparationTimeline.KeptInterval(
            originalStartSeconds: originalStart, originalEndSeconds: 1_482, outputStartSeconds: outputStart
        ) else { return nil }
        kept.append(finalInterval)
        return try? PreparationStatus.PreparationTimeline(removed: removed, kept: kept)
    }

    private func installPodcastFixture(in store: LocalLibraryStore) {
        let feedURL = URL(string: "https://fixtures.example.test/field-notes.xml")!
        let enclosureURL = URL(string: "https://fixtures.example.test/media/quiet-machines.mp3")!
        guard let feedID = try? ItemID.derivePodcastFeed(from: feedURL),
              let episodeID = try? ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "fixture-episode-001", enclosureURL: enclosureURL
              ),
              let feed = try? PodcastFeed(
                itemID: feedID, canonicalURL: feedURL, title: "Field Notes",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200))
              ),
              let episode = try? PodcastEpisode(
                itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "fixture-episode-001",
                title: "Quiet Machines", author: "Field Notes desk",
                publishedTime: Timestamp(Date(timeIntervalSince1970: 1_699_827_200)),
                enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", durationSeconds: 1_482,
                // Persisted as well as drawn: a download or a play reloads the
                // rows from the store, and a fixture episode saved without its
                // notes came back with none, so the player's notes pane and the
                // title's popover tested a row that no longer existed.
                notes: Self.fixtureEpisodeNotes,
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200))
              ) else { return }
        episodes = [WiltedMacEpisode(
            id: episodeID.rawValue, title: episode.title, feedTitle: feed.title,
            summary: Self.episodeSummary(notes: Self.fixtureEpisodeNotes, fallback: "Field Notes desk"),
            notes: Self.fixtureEpisodeNotes, artworkURL: nil, releasedAt: episode.createdAt.date,
            durationSeconds: episode.durationSeconds, playbackSeconds: 0,
            downloadState: fixtureDownloadFailuresRemaining > 0 ? .notDownloaded : .completed,
            preparationState: fixtureEpisodeIsPrepared
                ? .prepared(summary: fixtureEpisodeHasLongTranscript
                    ? "Ready · 8 ads removed (1:52) · transcript synced"
                    : Self.fixturePreparedSummary)
                : (fixtureEpisodeIsDeferred ? .preparing(stage: Self.preparationQueuedStage) : .notPrepared)
        )]
        if fixtureEpisodeIsDeferred {
            // The same shape `admitAutomaticPreparation` writes when the
            // off-peak window is shut, minus the download that produced it.
            deferredAutomaticPreparations = [DeferredAutomaticPreparation(
                episodeID: episodeID.rawValue,
                processingPolicy: automationSettings.processingPolicy,
                policySnapshot: Self.preparationPolicySnapshot(from: automationSettings)
            )]
            preparationQueue.enter(WiltedMacWaitingPreparation(
                id: episodeID.rawValue, title: episode.title, source: feed.title
            ))
        }
        // The Feeds card reads `subscriptions`, which only the store-backed load
        // path populates. Fixture mode assigns the library directly, so it has
        // to supply the same rows -- including a feed the listener has hidden,
        // so the card's hidden-from-Larder state is covered by evidence rather
        // than assumed. The hidden feed is written to the store too, so a
        // reload during a test agrees with what was drawn.
        let hiddenFeedURL = URL(string: "https://fixtures.example.test/quiet-season.xml")!
        let hiddenFeed = try? PodcastFeed(
            itemID: ItemID.derivePodcastFeed(from: hiddenFeedURL), canonicalURL: hiddenFeedURL,
            title: "Quiet Season", createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_740_800))
        )
        subscriptions = [
            WiltedMacSubscription(
                id: feedID.rawValue, title: feed.title, feedURL: feedURL, episodeCount: 1,
                subscribedAt: Date(timeIntervalSince1970: 1_699_827_200), enabled: true
            ),
        ] + (hiddenFeed.map { hidden in
            [WiltedMacSubscription(
                id: hidden.itemID.rawValue, title: hidden.title, feedURL: hiddenFeedURL, episodeCount: 0,
                subscribedAt: Date(timeIntervalSince1970: 1_699_740_800), enabled: false
            )]
        } ?? [])
        let mediaURL = mediaDirectory.appendingPathComponent("fixture-podcast.mp3")
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: mediaURL.path, contents: Data([0]))
        let revision = try? AudioRevision(
            itemID: episodeID, revisionID: RevisionID(rawValue: "fixture-podcast-revision"),
            durationSeconds: fixtureEpisodeHasLongTranscript ? 1_370 : 1_482, byteCount: 1,
            contentHash: "sha256:" + String(repeating: "9", count: 64), mediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200)), schemaVersion: 1
        )
        fixturePodcastInstallTask = Task {
            try? await store.save(feed: feed)
            try? await store.save(episode: episode)
            try? await store.save(subscription: PodcastSubscription(
                feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_699_827_200))
            ))
            if let hiddenFeed {
                try? await store.save(feed: hiddenFeed)
                try? await store.save(subscription: PodcastSubscription(
                    feedID: hiddenFeed.itemID,
                    subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_699_740_800)), enabled: false
                ))
            }
            if let revision {
                if let transcript = Self.fixtureEpisodeTranscript(
                    episodeID: episodeID, revisionID: revision.revisionID,
                    isLong: fixtureEpisodeHasLongTranscript
                ) {
                    try? await store.saveReadyRevision(
                        revision, mediaURL: mediaURL, transcript: transcript
                    )
                } else {
                    try? await store.saveReadyRevision(revision, mediaURL: mediaURL)
                }
            }
            // A prepared fixture episode has a history for Prep to read, in
            // the worker's own vocabulary, so the detailed log is exercised
            // through the same journal the real pipeline writes.
            if fixtureEpisodeIsPrepared, let revision {
                // `preparationState` reads the outcome row as its proof, not
                // the journal below -- without this the fixture's "prepared"
                // episode would read as not-prepared on any reload.
                try? await store.savePreparationOutcome(PodcastPreparationOutcome(
                    episodeID: episodeID, revisionID: revision.revisionID, policyDigest: "fixture-policy",
                    pipelineFingerprint: "fixture-fingerprint", semanticVersion: "fixture-semantic-version",
                    producedAt: Timestamp(Date(timeIntervalSince1970: 1_699_830_300))
                ))
            }
            if fixtureEpisodeIsPrepared {
                let requestID = Self.podcastRequestPrefix + episodeID.rawValue
                let started = Date(timeIntervalSince1970: 1_699_830_000)
                let journalled: [(String, PreparationStage, String, Double?)] = [
                    ("pipeline.start", .preparing, episode.title, nil),
                    ("transcript.stt.start", .extracting, "transcript.stt.start", nil),
                    ("ads.detect.calls", .assembling, "50 requests, 0 failed", nil),
                    ("ads.detect.span.1", .assembling, "0:01:20–0:02:10 · host read · 91%", nil),
                    ("ads.cut.complete", .assembling,
                     fixtureEpisodeHasLongTranscript ? "112.00 s removed" : "442.12 s removed", 0.9),
                ]
                for (offset, (stage, coarse, detail, fraction)) in journalled.enumerated() {
                    guard let status = try? PreparationStatus(
                        stage: coarse, detail: detail, fraction: fraction, cancellable: true,
                        emittedAt: Timestamp(started.addingTimeInterval(Double(offset) * 60))
                    ) else { continue }
                    try? await store.record(preparation: PreparationJournalEntry(
                        id: requestID + "|" + stage, itemID: episodeID, requestID: requestID, status: status
                    ))
                }
                if let terminal = try? PreparationTerminalResult(outcome: .succeeded, revisionID: revision?.revisionID),
                   let status = try? PreparationStatus(
                    stage: .completed,
                    detail: fixtureEpisodeHasLongTranscript
                        ? "Ready · 8 ads removed (1:52) · transcript synced"
                        : Self.fixturePreparedSummary,
                    cancellable: false, terminalResult: terminal,
                    emittedAt: Timestamp(started.addingTimeInterval(300)),
                    timeline: fixtureEpisodeHasLongTranscript ? Self.fixtureLongTranscriptTimeline : nil
                   ) {
                    try? await store.record(preparation: PreparationJournalEntry(
                        id: requestID + "|terminal", itemID: episodeID, requestID: requestID, status: status
                    ))
                }
            }
        }
    }

    /// Jumps playback to a transcript line the listener picked.
    func seekToTranscriptCue(_ cue: WiltedMacTranscriptCue) {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(to: cue.startSeconds)
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
#endif
    }

    /// The transcript line the audio is currently in, if the transcript is
    /// synchronised with it.
    /// What preparation cut out of the episode now playing.
    ///
    /// Empty for an article, which is synthesized from text and has nothing to
    /// cut, and for an episode played from an unprepared revision.
    var currentRemovedSpans: [WiltedMacRemovedSpan] {
        guard let currentPodcastEpisodeID else { return [] }
        return removedSpansByEpisode[currentPodcastEpisodeID] ?? []
    }

    var activeTranscriptCueID: Int? {
        currentTranscript?.cueIndex(at: playbackPositionSeconds)
    }

    func seek(by seconds: TimeInterval) {
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(by: seconds)
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
    }

    func navigatePodcastQueue(previous: Bool) {
#if canImport(WiltedProducer)
        guard isPodcastPlayback else { return }
        guard let playback else {
            if previous {
                if let prev = previousEligiblePodcastQueueEpisode() {
                    currentPodcastEpisodeID = prev.id
                    refreshPlaybackReadout()
                }
            } else if let next = nextEligiblePodcastQueueEpisode() {
                currentPodcastEpisodeID = next.id
                refreshPlaybackReadout()
            }
            return
        }
        playbackOperationStatus = previous ? "Opening previous episode…" : "Opening next episode…"
        playbackOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selected = try await (previous
                    ? playback.selectPreviousPodcastQueueEpisode()
                    : playback.selectNextPodcastQueueEpisode())
                if selected {
                    await self.refreshPodcastQueueState()
                    self.refreshPlaybackReadout()
                    self.playbackError = nil
                }
                self.playbackOperationStatus = nil
            } catch {
                self.playbackOperationStatus = nil
                // A manual skip throws before `podcastStateHandler` ever runs,
                // so this is the only place that repairs the flag for this path.
                if case let PlaybackControllerError.podcastMediaUnavailable(unavailableID) = error,
                   let index = self.episodes.firstIndex(where: { $0.id == unavailableID.rawValue }) {
                    self.episodes[index].isReadyMediaAvailable = false
                }
                self.playbackError = previous
                    ? "The previous episode is unavailable."
                    : "The next episode is unavailable."
            }
        }
#endif
    }

    static func stateDirectory(fixtureMode: Bool) -> URL {
        if fixtureMode {
            let temporaryDirectory = FileManager.default.temporaryDirectory
            // XCUITest terminates the fixture host it drives by design, so this
            // process's own previous wilted-ui-fixture-<pid> directory (from a
            // prior launch that never got to run any cleanup, trapped or
            // otherwise) is still sitting in $TMPDIR. Shell callers get this
            // from scripts/lib/temp-sweep.sh; this is its Swift equivalent,
            // scoped only to the family this function itself creates. The 24h
            // cutoff mirrors that library's and is the same safety argument: a
            // directory nothing has touched in a day belongs to a run that is
            // not coming back, and a fixture launch that is still running is at
            // most minutes old.
            sweepStaleFixtureDirectories(in: temporaryDirectory)
            // Suffixed per instance, not just per process: a single xctest
            // process constructs many fixture-mode models across unrelated
            // test methods, and now that fixture downloads write real store
            // rows (Phase 1b), a PID-only path let one model's completed
            // download satisfy another's `completedResult` cache lookup and
            // silently skip its cancellation/failure simulation. Tests that
            // want two instances to share state (relaunch simulation) already
            // pass an explicit `stateDirectoryOverride` rather than relying on
            // this default.
            return temporaryDirectory
                .appendingPathComponent(
                    "wilted-ui-fixture-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                    isDirectory: true
                )
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Wilted", isDirectory: true)
    }

    /// Removes abandoned `wilted-ui-fixture-*` directories under `root` older
    /// than 24 hours. Never throws and never fails the caller: this is
    /// housekeeping in front of a fixture launch, not a precondition for one.
    private static func sweepStaleFixtureDirectories(in root: URL) {
        let maxAge: TimeInterval = 24 * 60 * 60
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for entry in entries {
            // Re-validated here, in the loop that deletes, not only by relying
            // on this being the only prefix `stateDirectory` ever mints.
            guard entry.lastPathComponent.hasPrefix("wilted-ui-fixture-") else { continue }
            guard let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))
                .flatMap(\.contentModificationDate), modified < cutoff else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
#endif
}
