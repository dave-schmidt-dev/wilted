import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Podcast preparation pipeline")
struct PodcastPreparationPipelineTests {
    @Test func refusesToPrepareAnEpisodeThatIsNotDownloaded() async throws {
        let fixture = try await Fixture(installDownload: false)
        defer { fixture.remove() }
        await #expect(throws: PodcastPreparationError.episodeNotDownloaded) {
            _ = try await fixture.pipeline(WorkerStub(response: [:])).prepare(episodeID: fixture.episodeID)
        }
    }

    /// The transcript the feed publishes is preferred, arrives already timed,
    /// and is handed to the worker as text rather than as a URL.
    @Test func fetchesThePublishedTranscriptAndKeepsItsTiming() async throws {
        let fixture = try await Fixture(publishesTranscript: true)
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "published", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "text": "Welcome back. Today we talk about latency.",
            "languageCode": "en",
            "cues": [["startSeconds": 0.0, "endSeconds": 2.5, "text": "Welcome back."],
                     ["startSeconds": 2.5, "endSeconds": 6.0, "text": "Today we talk about latency."]],
        ])

        let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)

        let requestData = try #require(await stub.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let published = try #require(request["publishedTranscript"] as? [String: Any])
        #expect(published["mediaType"] as? String == "text/vtt")
        #expect((published["body"] as? String)?.contains("WEBVTT") == true)
        #expect(request["audioPath"] as? String == fixture.audioURL.path)
        #expect(request["sourceHash"] as? String == fixture.contentHash)
        #expect(request["alignedTranscriptModel"] as? String == PodcastPreparationPipeline.alignedTranscriptModel)
        #expect(request["transcriptPolicy"] as? String == "bestAvailable")
        #expect(request["removeAds"] as? Bool == true)
        #expect(request["readableTranscript"] as? Bool == true)
        #expect(request["allowSpeechToText"] as? Bool == true)
        // The show notes ride along as the worker's glossary.
        #expect(request["episodeNotes"] as? String == "Host: Leo Laporte (https://twit.tv/people/leo-laporte)")
        #expect(request["episodeTitle"] as? String == "Episode")
        #expect(result.transcript.timing == .published)
        #expect(result.transcript.cues?.count == 2)
        #expect(result.revision.revisionID == fixture.revisionID)
        #expect(result.audioWasCut == false)

        let stored = try #require(try await fixture.store.transcript(for: fixture.episodeID, revisionID: fixture.revisionID))
        #expect(stored.cues?.last?.text == "Today we talk about latency.")
        #expect(stored.schemaVersion == 2)
    }

    @Test(arguments: [
        (PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable, removeAds: true, readableTranscriptPass: true
        ), "bestAvailable", true, true, true),
        (PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false, readableTranscriptPass: false
        ), "alwaysTranscribe", false, false, true),
        (PodcastPreparationPolicySnapshot(
            transcriptPolicy: .noLocalSTT, removeAds: true, readableTranscriptPass: false
        ), "noLocalSTT", true, false, false),
    ])
    func mapsEachAdmissionPolicyIntoAnImmutableWorkerRequest(
        argument: (PodcastPreparationPolicySnapshot, String, Bool, Bool, Bool)
    ) async throws {
        let (policy, expectedName, expectedRemoveAds, expectedReadable, expectedSTT) = argument
        let fixture = try await Fixture(publishesTranscript: true)
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
        ])

        _ = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID, policy: policy)

        let data = try #require(await stub.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request["transcriptPolicy"] as? String == expectedName)
        #expect(request["removeAds"] as? Bool == expectedRemoveAds)
        #expect(request["readableTranscript"] as? Bool == expectedReadable)
        #expect(request["allowSpeechToText"] as? Bool == expectedSTT)
        #expect((request["publishedTranscript"] != nil) == (policy.transcriptPolicy != .alwaysTranscribe))
    }

    /// An unreachable transcript document is a downgrade, not a failure: the
    /// worker still runs and falls through to speech-to-text.
    @Test func continuesWithoutThePublishedTranscriptWhenItCannotBeFetched() async throws {
        let fixture = try await Fixture(publishesTranscript: true, transcriptStatusCode: 404)
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "aligned", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "text": "Spoken words.", "cues": [["startSeconds": 0.0, "endSeconds": 1.0, "text": "Spoken words."]],
        ])
        let statuses = StatusLog()

        let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID) { progress in
            statuses.append(progress.stage)
        }

        let sentData = try #require(await stub.lastRequest())
        let sent = try #require(try JSONSerialization.jsonObject(with: sentData) as? [String: Any])
        #expect(sent["publishedTranscript"] == nil)
        #expect(statuses.stages.contains("transcript.published.unreadable"))
        #expect(result.transcript.timing == .aligned)
    }

    /// The whole point of the pipeline: cut audio is different audio, so it
    /// takes a new revision identity, replaces the download, and the remapped
    /// cues bind to the revision they actually describe.
    @Test func cutAudioBecomesANewRevisionThatTheTranscriptBindsTo() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let cutBody = Data("shorter-audio-bytes".utf8)
        let stub = WorkerStub(response: [
            "ok": true, "timing": "aligned", "audioChanged": true, "durationSeconds": 7.5,
            "text": "Kept words.", "cues": [["startSeconds": 0.0, "endSeconds": 3.0, "text": "Kept words."]],
            "removedSeconds": 4.5,
            "adSegments": [["startSeconds": 3.0, "endSeconds": 7.5, "label": "host read", "confidence": 0.91]],
            "keepIntervals": [["startSeconds": 0.0, "endSeconds": 3.0, "outputStartSeconds": 0.0],
                              ["startSeconds": 7.5, "endSeconds": 12.0, "outputStartSeconds": 3.0]],
        ], writesCutAudio: cutBody)

        let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)

        let expectedID = try RevisionID.derive(
            podcastDownloadedAudioItemID: fixture.episodeID,
            contentHash: Fixture.contentHash(cutBody)
        )
        #expect(result.revision.revisionID == expectedID)
        #expect(result.revision.revisionID != fixture.revisionID)
        #expect(result.revision.durationSeconds == 7.5)
        #expect(result.revision.byteCount == Int64(cutBody.count))
        #expect(result.removedSeconds == 4.5)
        #expect(result.adSegments.first?.label == "host read")
        #expect(result.transcript.revisionID == expectedID)

        #expect(try Data(contentsOf: result.mediaURL) == cutBody)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path) == false)
        let download = try #require(try await fixture.store.download(for: fixture.episodeID))
        #expect(download.localURL == result.mediaURL)
        #expect(download.contentHash == result.revision.contentHash)
        let ready = try #require(try await fixture.store.readyRevision(for: fixture.episodeID, revisionID: expectedID))
        #expect(ready.mediaURL == result.mediaURL)

        // The superseded revision described audio that no longer exists, so it
        // must not survive as a record any lookup can return.
        let all = try await fixture.store.revisions(for: fixture.episodeID)
        #expect(all.map(\.revision.revisionID) == [expectedID])
        let newest = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))
        #expect(newest.revision.revisionID == expectedID)
        #expect(try await fixture.store.transcript(for: fixture.episodeID, revisionID: fixture.revisionID) == nil)
    }

    /// A listener halfway through an episode keeps their place: the position
    /// moves onto the cut audio rather than being lost with the revision.
    @Test func carriesTheListeningPositionOntoThePreparedAudio() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(playback: try PlaybackState(
            itemID: fixture.episodeID, revisionID: fixture.revisionID, sessionID: "session-1", sequence: 4,
            positionSeconds: 9.0, durationSeconds: 12, completed: false, intent: .progress, deviceID: "mac-1",
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_150))
        ))
        let result = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)

        // 0-3 survives as 0-3 and 7.5-12 survives as 3-7.5, so 9.0 lands at 4.5.
        let carried = try #require(try await fixture.store.playbackState(for: fixture.episodeID,
                                                                        revisionID: result.revision.revisionID))
        #expect(carried.positionSeconds == 4.5)
        #expect(carried.durationSeconds == 7.5)
        #expect(carried.sessionID == "session-1")
        #expect(carried.sequence == 5)
        #expect(try await fixture.store.playbackState(for: fixture.episodeID, revisionID: fixture.revisionID) == nil)
    }

    /// A position inside a removed advertisement has nowhere honest to land.
    @Test func dropsAPositionThatFellInsideARemovedAdvertisement() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(playback: try PlaybackState(
            itemID: fixture.episodeID, revisionID: fixture.revisionID, sessionID: "session-1", sequence: 4,
            positionSeconds: 5.0, durationSeconds: 12, completed: false, intent: .progress, deviceID: "mac-1",
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_150))
        ))
        let result = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        #expect(try await fixture.store.playbackState(for: fixture.episodeID,
                                                      revisionID: result.revision.revisionID) == nil)
    }

    /// The original audio is the only copy until the store commits. A store
    /// that rejects the replacement must leave a playable episode behind.
    @Test func keepsTheOriginalAudioWhenTheStoreRefusesTheReplacement() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // A worker that returns byte-identical audio derives the revision it is
        // meant to be replacing, which the store refuses.
        let stub = WorkerStub(response: [
            "ok": true, "timing": "none", "audioChanged": true,
            "keepIntervals": [["startSeconds": 0.0, "endSeconds": 12.0, "outputStartSeconds": 0.0]],
        ], writesCutAudio: Data("original-audio-bytes".utf8))

        await #expect(throws: LocalLibraryStoreError.self) {
            _ = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        let stored = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))
        #expect(stored.mediaURL == fixture.audioURL)
        #expect(try Data(contentsOf: fixture.audioURL) == Data("original-audio-bytes".utf8))
    }

    @Test func mapsPositionsThroughTheKeepIntervals() {
        let keeps = [PodcastKeepInterval(startSeconds: 0, endSeconds: 3, outputStartSeconds: 0),
                     PodcastKeepInterval(startSeconds: 7.5, endSeconds: 12, outputStartSeconds: 3)]
        #expect(PodcastKeepInterval.map(0, through: keeps) == 0)
        #expect(PodcastKeepInterval.map(2.5, through: keeps) == 2.5)
        #expect(PodcastKeepInterval.map(5, through: keeps) == nil)
        #expect(PodcastKeepInterval.map(7.5, through: keeps) == 3)
        #expect(PodcastKeepInterval.map(99, through: keeps) == 7.5)
        #expect(PodcastKeepInterval.map(1, through: []) == nil)
    }

    @Test func reportsWorkerFailuresAndUnreadableResults() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await #expect(throws: PodcastPreparationError.workerFailed(code: "stt-unavailable", message: "daemon down")) {
            _ = try await fixture.pipeline(WorkerStub(response: [
                "ok": false, "code": "stt-unavailable", "message": "daemon down",
            ])).prepare(episodeID: fixture.episodeID)
        }
        await #expect(throws: PodcastPreparationError.malformedWorkerResponse("no audioPath")) {
            _ = try await fixture.pipeline(WorkerStub(response: ["ok": true, "timing": "none"]))
                .prepare(episodeID: fixture.episodeID)
        }
    }

    /// A worker that claims it cut the audio but leaves nothing behind must not
    /// be believed into a revision that points at a missing file.
    @Test func rejectsCutAudioThatIsNotOnDisk() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "none", "audioChanged": true,
            "audioPath": fixture.workDirectory.appendingPathComponent("absent.mp3").path,
        ])
        await #expect(throws: PodcastPreparationError.preparedAudioUnreadable) {
            _ = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    /// A run that failed while the window was closed still has to leave
    /// evidence, so every status is journalled as well as reported.
    @Test func journalsTheRunSoItsOutcomeOutlivesTheWindow() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let worker = WorkerStub(
            response: Fixture.cuttingStubResponse(), writesCutAudio: Fixture.cuttingAudio,
            progress: [
                PodcastPreparationProgress(stage: "ads.detect.calls", detail: "1 request, 0 failed"),
                PodcastPreparationProgress(stage: "ads.detect.calls", detail: "2 requests, 0 failed"),
            ]
        )
        _ = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID)

        let requestID = PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        let entries = try await fixture.store.preparationJournal(for: requestID)
        #expect(entries.contains { $0.status.stage == .preparing })
        #expect(entries.contains { $0.status.stage == .saving })
        let result = try #require(entries.first { $0.id.contains("|pipeline.result#") })
        #expect(result.status.evidence?.kind == "worker-result")
        #expect(result.status.evidence?.fields["advertisements"] == "1")
        let ad = try #require(entries.first { $0.id.contains("|ads.detect.span.1#") })
        #expect(ad.status.evidence?.kind == "advertisement")
        #expect(ad.status.evidence?.fields["startSeconds"] == "3.000")
        #expect(ad.status.evidence?.fields["label"] == "host read")
        #expect(entries.filter { $0.id.contains("|ads.detect.calls#") }.count == 2,
                "Repeated worker stages must retain both observations.")
        #expect(Set(entries.map(\.id)).count == entries.count)
        let terminal = try #require(entries.last { $0.status.terminal })
        #expect(terminal.status.terminalResult?.outcome == .succeeded)
        #expect(terminal.status.terminalResult?.revisionID != nil)
        #expect(terminal.status.timeline?.removed == [
            try PreparationStatus.PreparationTimeline.RemovedInterval(
                originalStartSeconds: 3, originalEndSeconds: 7.5, label: "host read", confidence: 0.91
            )
        ])
        #expect(terminal.status.timeline?.kept.count == 2)
        #expect(entries.allSatisfy { $0.itemID == fixture.episodeID })
        // The terminal row says what was done, not just that it finished:
        // it is what a relaunched app shows under the episode.
        #expect(terminal.status.detail == "Ready · 1 ad removed (0:05) · transcript synced")
    }

    @Test func summaryStatesWhatWasActuallyDone() {
        #expect(PodcastPreparationResult.summary(advertisements: 3, secondsRemoved: 185, timing: .aligned)
                == "Ready · 3 ads removed (3:05) · transcript synced")
        #expect(PodcastPreparationResult.summary(advertisements: 1, secondsRemoved: 42, timing: .published)
                == "Ready · 1 ad removed (0:42) · transcript synced from the feed")
        #expect(PodcastPreparationResult.summary(advertisements: 5, secondsRemoved: 3_722, timing: .aligned)
                == "Ready · 5 ads removed (1:02:02) · transcript synced")
        // A gap is named rather than omitted, so a listener whose transcript
        // will not follow the audio learns it from the row.
        #expect(PodcastPreparationResult.summary(advertisements: 0, secondsRemoved: 0, timing: .none)
                == "Ready · no ads found · transcript not synced")
    }

    /// The journal is keyed by item, not attempt. Before it was cleared at the
    /// start of a run, the previous attempt's terminal row reported the next
    /// attempt as finished while it was still running, and stage rows the new
    /// attempt had not reached yet read as its own.
    @Test func aSecondAttemptStartsWithAnEmptyJournal() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let requestID = PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        _ = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        let firstTerminal = try #require(try await fixture.store.preparationJournal(for: requestID).last { $0.status.terminal })
        #expect(firstTerminal.status.terminalResult?.outcome == .succeeded)

        let store = fixture.store
        let probe = ProbingWorker { [store] in
            // Journal writes queue behind the pipeline's actor, so wait for
            // this attempt's first row rather than reading whatever landed.
            var running: PreparationRunSummary?
            for _ in 0..<200 where running == nil {
                running = try await store.preparationRuns().first { $0.requestID == requestID }
                if running == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            let observed = try #require(running)
            #expect(!observed.isTerminal, "the first attempt's terminal row must not describe the second")
            #expect(!observed.entries.contains { $0.status.stage == .saving }, "stale stage rows must be gone")
        }
        _ = try? await fixture.pipeline(probe).prepare(episodeID: fixture.episodeID)

        let second = try #require(try await fixture.store.preparationRuns().first { $0.requestID == requestID })
        #expect(second.isTerminal)
        #expect(second.outcome == .failed)
        #expect(second.entries.last?.status.terminal == true)
        #expect(!second.entries.contains { $0.status.stage == .saving })
    }

    @Test func journalsAFailureWithTheCodeThatCausedIt() async throws {
        let fixture = try await Fixture(installDownload: false)
        defer { fixture.remove() }
        _ = try? await fixture.pipeline(WorkerStub(response: [:])).prepare(episodeID: fixture.episodeID)

        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        )
        let terminal = try #require(entries.last { $0.status.terminal })
        #expect(terminal.status.stage == .failed)
        #expect(terminal.status.terminalResult?.error?.code == .invalidRequest)
    }

    @Test func rejectsMalformedTimelineBeforeSuccessIsJournalled() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let malformed = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "adSegments": [["startSeconds": 3.0, "endSeconds": 7.0, "label": "sponsor", "confidence": 1.2]],
        ])
        await #expect(throws: PodcastPreparationError.malformedWorkerResponse("invalid preparation timeline")) {
            _ = try await fixture.pipeline(malformed).prepare(episodeID: fixture.episodeID)
        }
        let entries = try await fixture.store.preparationJournal(for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        let terminal = try #require(entries.last { $0.status.terminal })
        #expect(terminal.status.terminalResult?.outcome == .failed)
        #expect(terminal.status.terminalResult?.error?.code == .protocolMismatch)
        #expect(terminal.status.timeline == nil)
    }

    @Test func journalOrdersEqualTimestampEventsByNumericOrdinalThroughBothAPIs() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let requestID = "same-timestamp"
        let timestamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        for id in ["event#10", "legacy", "event#2", "event#1"] {
            try await fixture.store.record(preparation: PreparationJournalEntry(
                id: id, itemID: fixture.episodeID, requestID: requestID,
                status: try PreparationStatus(stage: .preparing, detail: id, cancellable: true, emittedAt: timestamp)
            ))
        }

        let expected = ["event#1", "event#2", "event#10", "legacy"]
        #expect(try await fixture.store.preparationJournal(for: requestID).map(\.id) == expected)
        #expect(try await fixture.store.preparationRuns().first(where: { $0.requestID == requestID })?.entries.map(\.id) == expected)
    }

    @Test func adProgressUsesBoundedFallbackForNonFiniteConfidence() {
        let progress = PodcastPreparationPipeline.adProgress(
            PodcastAdSegment(startSeconds: 12, endSeconds: 24, label: "host read", confidence: .infinity),
            ordinal: 1
        )
        #expect(progress.detail == "0:00:12–0:00:24 · host read · unknown confidence")
        #expect(progress.evidence?.fields["confidence"]?.contains("inf") == true)
    }

    @Test func adProgressBoundsAnOversizedWorkerLabelWithoutDroppingEvidence() {
        let progress = PodcastPreparationPipeline.adProgress(
            PodcastAdSegment(startSeconds: 12, endSeconds: 24,
                             label: String(repeating: "L", count: 512), confidence: 0.5),
            ordinal: 1
        )
        let label = progress.evidence?.fields["label"]
        #expect(label?.count == 256)
        #expect(label?.hasSuffix("...") == true)
        #expect(progress.detail.count <= 1_024)
        #expect(progress.detail.contains("... · 50%"))
    }

    // MARK: Transcript construction

    @Test func recordsAnAbsentTranscriptWhenTheWorkerFoundNoWords() throws {
        let transcript = try PodcastPreparationPipeline.transcript(
            from: Self.payload(text: nil), itemID: Self.itemID, revisionID: Self.revisionID,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(transcript.availability == .absent)
        #expect(transcript.timing == TranscriptTiming.none)
    }

    @Test func recordsOversizedRatherThanDiscardingAnEpisode() throws {
        let huge = String(repeating: "a ", count: Transcript.maximumTextUTF8Bytes)
        let transcript = try PodcastPreparationPipeline.transcript(
            from: Self.payload(text: huge), itemID: Self.itemID, revisionID: Self.revisionID,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(transcript.availability == .oversized)
        #expect(transcript.text == nil)
    }

    /// Timing that will not fit costs the timing, never the words.
    @Test func keepsTheWordsWhenTheCuesExceedTheTransportBudget() throws {
        let cues = try (0..<(Transcript.maximumCueCount + 10)).map {
            try TranscriptCue(startSeconds: Double($0), endSeconds: Double($0) + 1, text: "cue \($0)")
        }
        var payload = Self.payload(text: "Words that fit.")
        payload.timing = .aligned
        payload.cues = cues
        let transcript = try PodcastPreparationPipeline.transcript(
            from: payload, itemID: Self.itemID, revisionID: Self.revisionID,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        #expect(transcript.availability == .available)
        #expect(transcript.text == "Words that fit.")
        #expect(transcript.timing == TranscriptTiming.none)
        #expect(transcript.cues == nil)
    }

    // MARK: Subprocess runner

    /// Exercises the real process plumbing with a shell script standing in for
    /// the Python worker, so stdin delivery, NDJSON progress, and result
    /// collection are covered by the gate without a virtualenv or a model.
    @Test func subprocessRunnerStreamsProgressAndReturnsTheResult() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("worker.sh")
        try """
        #!/bin/sh
        printf '{"stage":"one","detail":"first","fraction":0.25}\\n' >&2
        printf 'not json at all\\n' >&2
        printf '{"stage":"two","detail":"second"}\\n' >&2
        request=$(cat)
        printf '{"ok":true,"echo":%s}' "$request"
        """.write(to: worker, atomically: true, encoding: .utf8)

        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 30
        ))
        let statuses = StatusLog()
        let output = try await runner.run(request: Data(#"{"audioPath":"/tmp/a.mp3"}"#.utf8)) { progress in
            statuses.append(progress.stage, detail: progress.detail, fraction: progress.fraction)
        }

        let decoded = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(decoded["ok"] as? Bool == true)
        #expect((decoded["echo"] as? [String: Any])?["audioPath"] as? String == "/tmp/a.mp3")
        #expect(statuses.stages == ["one", "two"])
        #expect(statuses.fractions.first == 0.25)
    }

    @Test func subprocessRunnerReportsAWorkerThatProducesNothing() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("silent.sh")
        try "#!/bin/sh\nexit 3\n".write(to: worker, atomically: true, encoding: .utf8)
        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 30
        ))
        await #expect(throws: PodcastPreparationError.self) {
            _ = try await runner.run(request: Data("{}".utf8)) { _ in }
        }
    }

    @Test func subprocessRunnerRefusesToStartWithoutItsPieces() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: directory.appendingPathComponent("no-python").path),
            workerURL: directory.appendingPathComponent("worker.py")
        ))
        await #expect(throws: PodcastPreparationError.self) {
            _ = try await missing.run(request: Data("{}".utf8)) { _ in }
        }
    }

    /// Every path is overridable, and the shipped defaults name real things.
    @Test func configurationResolvesFromTheEnvironment() {
        let overridden = SubprocessPodcastPipelineRunner.Configuration.resolved(environment: [
            "WILTED_PIPELINE_PYTHON": "/opt/py", "WILTED_PIPELINE_WORKER": "/opt/w.py",
            "WILTED_PIPELINE_PYTHONPATH": "/opt/src", "WILTED_PIPELINE_TIMEOUT_S": "60",
            "WILTED_PIPELINE_TOOL_PATH": "/opt/tools/bin:/opt/more",
        ])
        #expect(overridden.interpreterURL.path == "/opt/py")
        #expect(overridden.workerURL.path == "/opt/w.py")
        #expect(overridden.pythonPath?.path == "/opt/src")
        #expect(overridden.timeout == 60)
        #expect(overridden.toolSearchPaths == ["/opt/tools/bin", "/opt/more"])

        let defaults = SubprocessPodcastPipelineRunner.Configuration.resolved(environment: [:])
        #expect(defaults.workerURL.lastPathComponent == "wilted_pipeline.py")
        #expect(defaults.timeout > 0)
        #expect(defaults.toolSearchPaths.contains("/opt/homebrew/bin"))
    }

    /// The app is launched from Finder with a PATH that cannot find ffmpeg;
    /// the worker's PATH must, without losing anything the app inherited.
    @Test func workerPATHAppendsToolDirectoriesItDoesNotAlreadyHave() {
        let configuration = SubprocessPodcastPipelineRunner.Configuration(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: URL(fileURLWithPath: "/w.sh"),
            toolSearchPaths: ["/opt/homebrew/bin", "/usr/local/bin"]
        )
        #expect(configuration.workerPATH(inherited: "/usr/bin:/bin") == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(configuration.workerPATH(inherited: "/opt/homebrew/bin:/usr/bin") == "/opt/homebrew/bin:/usr/bin:/usr/local/bin")
        #expect(configuration.workerPATH(inherited: nil) == "/opt/homebrew/bin:/usr/local/bin")
        #expect(configuration.workerPATH(inherited: "::/usr/bin:") == "/usr/bin:/opt/homebrew/bin:/usr/local/bin")

        // Nothing inherited and nothing configured is still a usable PATH.
        let bare = SubprocessPodcastPipelineRunner.Configuration(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: URL(fileURLWithPath: "/w.sh"),
            toolSearchPaths: [""]
        )
        #expect(bare.workerPATH(inherited: "") == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func subprocessRunnerHandsTheWorkerTheExtendedPATH() async throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("path.sh")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"path":"%s"}' "$PATH"
        """.write(to: worker, atomically: true, encoding: .utf8)
        let runner = SubprocessPodcastPipelineRunner(configuration: .init(
            interpreterURL: URL(fileURLWithPath: "/bin/sh"), workerURL: worker, timeout: 30,
            toolSearchPaths: [directory.path]
        ))
        let output = try await runner.run(request: Data("{}".utf8)) { _ in }
        let decoded = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        let path = try #require(decoded["path"] as? String)
        #expect(path.split(separator: ":").map(String.init).contains(directory.path))
        // Everything the app inherited is still there, ahead of the additions.
        if let inherited = ProcessInfo.processInfo.environment["PATH"] {
            #expect(path.hasPrefix(inherited.split(separator: ":", omittingEmptySubsequences: true).joined(separator: ":")))
        }
    }

    // MARK: Fixtures

    private static let itemID = try! ItemID(rawValue: "item-" + String(repeating: "4", count: 64))
    private static let revisionID = try! RevisionID.derive(downloadedAudioContentHash: Fixture.contentHash(Data("x".utf8)))

    private static func payload(text: String?) -> PodcastPreparationPipeline.WorkerPayload {
        PodcastPreparationPipeline.WorkerPayload(
            timing: .none, cues: [], text: text, languageCode: "en",
            audioPath: "/tmp/a.mp3", audioChanged: false, durationSeconds: nil,
            adSegments: [], removedSeconds: 0, keepIntervals: [],
            timeline: try! PreparationStatus.PreparationTimeline(removed: [], kept: [])
        )
    }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, String, Double?)] = []

    func append(_ stage: String, detail: String = "", fraction: Double? = nil) {
        lock.lock(); recorded.append((stage, detail, fraction)); lock.unlock()
    }

    var stages: [String] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.0) }
    var fractions: [Double] { lock.lock(); defer { lock.unlock() }; return recorded.compactMap(\.2) }
}

/// Stands in for the Python worker, and records what it was asked to do.
private actor WorkerStub: PodcastPipelineRunning {
    private let response: [String: Any]
    private let writesCutAudio: Data?
    private let progress: [PodcastPreparationProgress]
    private var request: Data?

    init(response: [String: Any], writesCutAudio: Data? = nil,
         progress: [PodcastPreparationProgress] = [PodcastPreparationProgress(stage: "worker.start")]) {
        self.response = response
        self.writesCutAudio = writesCutAudio
        self.progress = progress
    }

    /// Returned as bytes: a decoded `[String: Any]` cannot cross the actor
    /// boundary, and the caller wants to inspect it anyway.
    func lastRequest() -> Data? { request }

    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
        request = payload
        progress.forEach(onProgress)
        var answer = response
        if let body = writesCutAudio, let outputPath = decoded["outputPath"] as? String {
            try body.write(to: URL(fileURLWithPath: outputPath))
            answer["audioPath"] = outputPath
        }
        return try JSONSerialization.data(withJSONObject: answer)
    }
}

/// A worker that lets a test look at the store mid-run, then fails.
private actor ProbingWorker: PodcastPipelineRunning {
    private let probe: @Sendable () async throws -> Void

    init(probe: @escaping @Sendable () async throws -> Void) { self.probe = probe }

    func run(
        request payload: Data,
        onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        onProgress(PodcastPreparationProgress(stage: "worker.start"))
        try await probe()
        throw PodcastPreparationError.workerUnavailable("probe")
    }
}

private struct TranscriptDocumentLoader: PodcastFeedLoading {
    let statusCode: Int
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(
            url: url, statusCode: statusCode,
            data: Data("WEBVTT\n\n00:00:00.000 --> 00:00:02.500\nWelcome back.\n".utf8)
        )
    }
}

private struct Fixture {
    let root: URL
    let libraryDirectory: URL
    let workDirectory: URL
    let store: LocalLibraryStore
    let episodeID: ItemID
    let revisionID: RevisionID
    let contentHash: String
    let audioURL: URL
    let transcriptStatusCode: Int

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func contentHash(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init(installDownload: Bool = true, publishesTranscript: Bool = false, transcriptStatusCode: Int = 200) async throws {
        root = try Fixture.temporaryDirectory()
        libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        workDirectory = root.appendingPathComponent("Work", isDirectory: true)
        for directory in [libraryDirectory, workDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.transcriptStatusCode = transcriptStatusCode
        store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))

        let feedURL = try #require(URL(string: "https://feeds.example.test/show.xml"))
        let enclosureURL = try #require(URL(string: "https://cdn.example.test/e1.mp3"))
        episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "e1", enclosureURL: enclosureURL)
        var sources: [PodcastTranscriptSource] = []
        if publishesTranscript {
            sources = [try PodcastTranscriptSource(
                url: try #require(URL(string: "https://cdn.example.test/e1.vtt")),
                mediaType: "text/vtt", languageCode: "en", isCaptions: true
            )]
        }
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: try ItemID.derivePodcastFeed(from: feedURL), feedURL: feedURL,
            rssGUID: "e1", title: "Episode", enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
            enclosureByteCount: 19, transcriptSources: sources,
            notes: "Host: Leo Laporte (https://twit.tv/people/leo-laporte)",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))

        let body = Data("original-audio-bytes".utf8)
        contentHash = Fixture.contentHash(body)
        revisionID = try RevisionID.derive(downloadedAudioContentHash: contentHash)
        let audioDirectory = libraryDirectory.appendingPathComponent("PodcastAudio", isDirectory: true)
            .appendingPathComponent(episodeID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        audioURL = audioDirectory.appendingPathComponent(revisionID.rawValue + ".mp3")
        guard installDownload else { return }
        try body.write(to: audioURL)
        try await store.finalizePodcastDownload(
            revision: try AudioRevision(
                itemID: episodeID, revisionID: revisionID, durationSeconds: 12,
                byteCount: Int64(body.count), contentHash: contentHash, mediaType: "audio/mpeg",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)), schemaVersion: 3
            ),
            mediaURL: audioURL,
            download: try PodcastDownload(
                episodeID: episodeID, status: .completed, bytesReceived: Int64(body.count),
                expectedByteCount: Int64(body.count), localURL: audioURL, contentHash: contentHash,
                updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
            )
        )
    }

    /// A worker that removes 3.0-7.5 from a twelve second episode.
    static func cuttingStub() -> some PodcastPipelineRunning {
        WorkerStub(response: cuttingStubResponse(), writesCutAudio: cuttingAudio)
    }

    static let cuttingAudio = Data("shorter-audio-bytes".utf8)

    static func cuttingStubResponse() -> [String: Any] {
        [
            "ok": true, "timing": "aligned", "audioChanged": true, "durationSeconds": 7.5,
            "text": "Kept words.", "cues": [["startSeconds": 0.0, "endSeconds": 3.0, "text": "Kept words."]],
            "removedSeconds": 4.5,
            "adSegments": [["startSeconds": 3.0, "endSeconds": 7.5, "label": "host read", "confidence": 0.91]],
            "keepIntervals": [["startSeconds": 0.0, "endSeconds": 3.0, "outputStartSeconds": 0.0],
                              ["startSeconds": 7.5, "endSeconds": 12.0, "outputStartSeconds": 3.0]],
        ]
    }

    func pipeline(_ runner: some PodcastPipelineRunning) -> PodcastPreparationPipeline {
        PodcastPreparationPipeline(
            store: store, workDirectory: workDirectory, runner: runner,
            documentLoader: TranscriptDocumentLoader(statusCode: transcriptStatusCode),
            now: { Date(timeIntervalSince1970: 1_700_000_200) }
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
