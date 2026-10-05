import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Podcast preparation pipeline")
struct PodcastPreparationPipelineTests {
    @Test func semanticVersionTracksTheWorkerBehaviour() {
        #expect(PodcastPreparationPipeline.semanticVersion == "podcast-preparation-v6")
    }

    @Test(arguments: [false, true])
    func everySuccessfulUncutTerminalPathRecordsSourceAudioButNoAdTime(removeAds: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false
        ])
        _ = try await fixture.pipeline(stub).prepare(
            episodeID: fixture.episodeID,
            policy: PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: removeAds)
        )

        let totals = try await fixture.store.lifetimeStatistics()
        #expect(totals.audioProcessedSeconds == 12)
        #expect(totals.confirmedAdTimeRemovedSeconds == 0)
    }

    @Test func committedCutRecordsOnlyQualifiedRemovedTime() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        _ = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)

        let totals = try await fixture.store.lifetimeStatistics()
        #expect(totals.audioProcessedSeconds == 12)
        #expect(totals.confirmedAdTimeRemovedSeconds == 4.5)
    }

    @Test func refusesToPrepareAnEpisodeThatIsNotDownloaded() async throws {
        let fixture = try await Fixture(installDownload: false)
        defer { fixture.remove() }
        await #expect(throws: PodcastPreparationError.episodeNotDownloaded) {
            _ = try await fixture.pipeline(WorkerStub(response: [:])).prepare(episodeID: fixture.episodeID)
        }
    }

    @Test func recordsTheSemanticPipelineFingerprintWithEachAttempt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false
        ])
        _ = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)

        let request = try #require(await stub.lastRequest())
        let object = try #require(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(object["pipelineFingerprint"] as? String == PodcastPreparationPipeline.semanticFingerprint)
        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        )
        let provenance = entries.compactMap(\.status.evidence).first {
            $0.kind == LocalLibraryStore.pipelineProvenanceEvidenceKind
        }
        #expect(provenance?.fields["fingerprint"] == PodcastPreparationPipeline.semanticFingerprint)
        #expect(provenance?.fields["sourceHash"] == fixture.contentHash)
    }

    @Test func semanticFingerprintCoverageRequiresTheWorkerAndSwiftSourcesToBeBumped() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workerHash = try ProducerSource.workerSourceHash(root: sourceRoot)
        #expect(workerHash == PodcastPreparationPipeline.workerSourceHash)

        let pipelineHash = try ProducerSource.pipelineSourceHash(root: sourceRoot)
        #expect(pipelineHash == PodcastPreparationPipeline.pipelineSourceHash)
    }

    @Test func semanticFingerprintTracksExternalPythonDependencies() throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("wilted", isDirectory: true)
        let speechPackage = root.appendingPathComponent("speech_stack", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: speechPackage, withIntermediateDirectories: true)
        let dependency = package.appendingPathComponent("ads.py")
        try Data("CLIENT = 1\n".utf8).write(to: speechPackage.appendingPathComponent("client.py"))
        try Data("DETECTOR = 1\n".utf8).write(to: dependency)
        let worker = root.appendingPathComponent("worker.py")
        try Data("WORKER = 1\n".utf8).write(to: worker)
        let environment = [
            "WILTED_PIPELINE_PYTHONPATH": root.path,
            "WILTED_SPEECH_STACK_PYTHONPATH": root.path,
            "WILTED_PIPELINE_WORKER": worker.path
        ]
        let first = try #require(PodcastPreparationPipeline.resolvedSemanticFingerprint(environment: environment))

        try Data("DETECTOR = 2\n".utf8).write(to: dependency)
        let second = try #require(PodcastPreparationPipeline.resolvedSemanticFingerprint(environment: environment))
        try Data("DETECTOR = 1\n".utf8).write(to: dependency)
        try Data("WORKER = 2\n".utf8).write(to: worker)
        let workerChanged = try #require(
            PodcastPreparationPipeline.resolvedSemanticFingerprint(environment: environment)
        )

        #expect(first != second)
        #expect(first != workerChanged)
        try FileManager.default.removeItem(at: speechPackage)
        #expect(PodcastPreparationPipeline.resolvedSemanticFingerprint(environment: environment) == nil)
        try FileManager.default.createDirectory(at: speechPackage, withIntermediateDirectories: true)
        try Data("CLIENT = 1\n".utf8).write(to: speechPackage.appendingPathComponent("client.py"))
        let unreadable = speechPackage.appendingPathComponent("unreadable.py")
        try Data("PRIVATE = 1\n".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        #expect(PodcastPreparationPipeline.resolvedSemanticFingerprint(environment: environment) == nil)
    }

    @Test func semanticFingerprintTracksWorkerPackageModules() throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker.py")
        let wilted = root.appendingPathComponent("wilted", isDirectory: true)
        let speechStack = root.appendingPathComponent("speech_stack", isDirectory: true)
        try FileManager.default.createDirectory(at: wilted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: speechStack, withIntermediateDirectories: true)
        try Data("WORKER = 1\n".utf8).write(to: worker)
        try Data("DETECTOR = 1\n".utf8).write(to: wilted.appendingPathComponent("ads.py"))
        try Data("CLIENT = 1\n".utf8).write(to: speechStack.appendingPathComponent("client.py"))
        let environment = [
            "WILTED_PIPELINE_PYTHONPATH": root.path,
            "WILTED_SPEECH_STACK_PYTHONPATH": root.path,
            "WILTED_PIPELINE_WORKER": worker.path
        ]
        let loneFileFingerprint = try #require(
            PodcastPreparationPipeline.resolvedSemanticFingerprint(environment: environment)
        )

        let workerPackage = root.appendingPathComponent("wilted_worker", isDirectory: true)
        try FileManager.default.createDirectory(at: workerPackage, withIntermediateDirectories: true)
        let module = workerPackage.appendingPathComponent("a.py")
        try Data("MODULE = 1\n".utf8).write(to: module)
        let first = try #require(PodcastPreparationPipeline.resolvedSemanticFingerprint(environment: environment))
        try Data("MODULE = 2\n".utf8).write(to: module)
        let changed = try #require(PodcastPreparationPipeline.resolvedSemanticFingerprint(environment: environment))

        #expect(first != changed)
        try FileManager.default.removeItem(at: workerPackage)
        let afterDeletingPackage = try #require(
            PodcastPreparationPipeline.resolvedSemanticFingerprint(environment: environment)
        )
        #expect(afterDeletingPackage == loneFileFingerprint)
    }

    /// The transcript the feed publishes is preferred, arrives already timed,
    @Test func keepsTheSpeakerTheWorkerNamedOnEachCue() async throws {
        let fixture = try await Fixture(publishesTranscript: true)
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "published", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "text": "Welcome back. Thanks for having me. And we are off.",
            "languageCode": "en",
            "cues": [["startSeconds": 0.0, "endSeconds": 2.5, "text": "Welcome back.", "speaker": "Angie"],
                     ["startSeconds": 2.5, "endSeconds": 6.0, "text": "Thanks for having me.", "speaker": "Chris"],
                     ["startSeconds": 6.0, "endSeconds": 8.0, "text": "And we are off."]],
        ])

        let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)

        #expect(result.transcript.cues?.map(\.speaker) == ["Angie", "Chris", nil])
        // The flattened text is what search and ad detection read. A name in
        // there would corrupt both to buy a display feature.
        #expect(result.transcript.text?.contains("Angie") == false)
        #expect(result.transcript.schemaVersion == Transcript.currentSchemaVersion)
    }

    /// and is handed to the worker as text rather than as a URL.
    @Test func fetchesThePublishedTranscriptAndKeepsItsTiming() async throws {
        let fixture = try await Fixture(publishesTranscript: true)
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "aligned", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "text": "Welcome back. Today we talk about latency.",
            "languageCode": "en",
            "cues": [["startSeconds": 0.0, "endSeconds": 2.5, "text": "Welcome back."],
                     ["startSeconds": 2.5, "endSeconds": 6.0, "text": "Today we talk about latency."]],
        ])

        let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)

        let requestData = try #require(await stub.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        #expect(request["publishedTranscript"] == nil,
                "removal forces aligned STT, so publisher cues are not fetched")
        #expect(request["audioPath"] as? String == fixture.audioURL.path)
        #expect(request["protocolVersion"] as? Int == 2)
        #expect(request["sourceHash"] as? String == fixture.contentHash)
        #expect(request["alignedTranscriptModel"] as? String == PodcastPreparationPipeline.alignedTranscriptModel)
        #expect(request["transcriptPolicy"] as? String == "bestAvailable")
        #expect(request["removeAds"] as? Bool == true)
        #expect(request["readableTranscript"] == nil)
        #expect(request["readableTranscriptModel"] == nil)
        #expect(request["allowSpeechToText"] as? Bool == true)
        // The show notes ride along as the worker's glossary.
        #expect(request["episodeNotes"] as? String == "Host: Leo Laporte (https://twit.tv/people/leo-laporte)")
        #expect(request["episodeTitle"] as? String == "Episode")
        #expect(result.transcript.timing == .aligned)
        #expect(result.transcript.cues?.count == 2)
        #expect(result.revision.revisionID == fixture.revisionID)
        #expect(result.audioWasCut == false)

        let stored = try #require(try await fixture.store.transcript(for: fixture.episodeID, revisionID: fixture.revisionID))
        #expect(stored.cues?.last?.text == "Today we talk about latency.")
        #expect(stored.schemaVersion == Transcript.currentSchemaVersion)
    }

    @Test(arguments: [
        (PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable, removeAds: true
        ), "bestAvailable", true, true),
        (PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ), "alwaysTranscribe", false, true),
        (PodcastPreparationPolicySnapshot(
            transcriptPolicy: .noLocalSTT, removeAds: true
        ), "noLocalSTT", true, false),
    ])
    func mapsEachAdmissionPolicyIntoAnImmutableWorkerRequest(
        argument: (PodcastPreparationPolicySnapshot, String, Bool, Bool)
    ) async throws {
        let (policy, expectedName, expectedRemoveAds, expectedSTT) = argument
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
        #expect(request["readableTranscript"] == nil)
        #expect(request["readableTranscriptModel"] == nil)
        #expect(request["allowSpeechToText"] as? Bool == expectedSTT)
        #expect((request["publishedTranscript"] != nil) == (!policy.removeAds && policy.transcriptPolicy != .alwaysTranscribe))
    }

    @Test func legacyPolicySnapshotDecodesWithoutRestoringTheSecondPass() throws {
        let data = Data(#"{"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":false}"#.utf8)

        let snapshot = try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: data)
        #expect(snapshot == PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true))

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        #expect(encoded?["readableTranscriptPass"] == nil)
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

        let result = try await fixture.pipeline(stub).prepare(
            episodeID: fixture.episodeID,
            policy: PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: false)
        ) { progress in
            statuses.append(progress.stage)
        }

        let sentData = try #require(await stub.lastRequest())
        let sent = try #require(try JSONSerialization.jsonObject(with: sentData) as? [String: Any])
        #expect(sent["publishedTranscript"] == nil)
        #expect(statuses.stages.contains("transcript.published.unreadable"))
        #expect(result.transcript.timing == .aligned)
    }

    /// The worker names a removal's kind separately from its detector label,
    /// and the two deliberately disagree: a merged span takes the *first*
    /// overlapping nomination's label while its kind is the strongest of the
    /// union. Reading the kind off the label here would put the first-label
    /// attribution back that the merge fix removed.
    @Test func adSegmentsCarryTheWorkersRemovalKindRatherThanDerivingItFromTheLabel() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let cutBody = Data("shorter-audio-bytes".utf8)
        let stub = WorkerStub(response: [
            "ok": true, "timing": "aligned", "audioChanged": true, "durationSeconds": 7.5,
            "text": "Kept words.", "cues": [["startSeconds": 0.0, "endSeconds": 3.0, "text": "Kept words."]],
            "removedSeconds": 4.5,
            // `self_promo` maps to a house promotion, but this span merged a
            // paid read in, so the worker reports paid. The label still names
            // the first nomination.
            "adSegments": [["startSeconds": 3.0, "endSeconds": 7.5, "label": "self_promo",
                            "confidence": 0.91, "kind": "paid advertising"]],
            "keepIntervals": [["startSeconds": 0.0, "endSeconds": 3.0, "outputStartSeconds": 0.0],
                              ["startSeconds": 7.5, "endSeconds": 12.0, "outputStartSeconds": 3.0]],
        ], writesCutAudio: cutBody)

        let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)

        #expect(result.adSegments.first?.label == "self_promo")
        #expect(result.adSegments.first?.kind == "paid advertising")
    }

    /// A kind is a display string from an external process. An unrecognised
    /// one reads as paid -- the conservative reading of an unknown removal --
    /// rather than failing a preparation whose audio is already finished.
    @Test func anUnrecognisedOrAbsentRemovalKindReadsAsPaidRatherThanFailingThePreparation() async throws {
        for supplied in [["kind": "sponsored content"], [:]] as [[String: String]] {
            let fixture = try await Fixture()
            defer { fixture.remove() }
            let cutBody = Data("shorter-audio-bytes".utf8)
            var span: [String: Any] = ["startSeconds": 3.0, "endSeconds": 7.5,
                                       "label": "host read", "confidence": 0.91]
            for (key, value) in supplied { span[key] = value }
            let stub = WorkerStub(response: [
                "ok": true, "timing": "aligned", "audioChanged": true, "durationSeconds": 7.5,
                "text": "Kept words.", "cues": [["startSeconds": 0.0, "endSeconds": 3.0, "text": "Kept words."]],
                "removedSeconds": 4.5, "adSegments": [span],
                "keepIntervals": [["startSeconds": 0.0, "endSeconds": 3.0, "outputStartSeconds": 0.0],
                                  ["startSeconds": 7.5, "endSeconds": 12.0, "outputStartSeconds": 3.0]],
            ], writesCutAudio: cutBody)

            let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)
            #expect(result.adSegments.first?.kind == PodcastAdSegment.defaultKind)
        }
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
            "adSegments": [["startSeconds": 3.0, "endSeconds": 7.5, "label": "host read", "confidence": 0.91]],
            "keepIntervals": [["startSeconds": 0.0, "endSeconds": 3.0, "outputStartSeconds": 0.0],
                              ["startSeconds": 7.5, "endSeconds": 12.0, "outputStartSeconds": 3.0]],
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
            "adSegments": [["startSeconds": 3.0, "endSeconds": 7.5, "label": "host read", "confidence": 0.91]],
            "keepIntervals": [["startSeconds": 0.0, "endSeconds": 3.0, "outputStartSeconds": 0.0],
                              ["startSeconds": 7.5, "endSeconds": 12.0, "outputStartSeconds": 3.0]],
        ])
        await #expect(throws: PodcastPreparationError.preparedAudioUnreadable) {
            _ = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

}
