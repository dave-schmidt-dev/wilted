import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

extension PodcastPreparationPipelineTests {
    /// The failure worth guarding is the one straight after a download
    /// finalises: there is no older prepared revision to fall back to, so a
    /// ready revision lost here is the episode lost.
    @Test func keepsAFreshlyFinalizedDownloadWhenPreparationFails() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let before = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))
        let failing = WorkerStub(response: [
            "ok": false, "code": "cut-render-timeout", "message": "ffmpeg exceeded its 7200s limit",
        ])
        await #expect(throws: PodcastPreparationError.workerFailed(code: "cut-render-timeout",
                                                                  message: "ffmpeg exceeded its 7200s limit")) {
            _ = try await fixture.pipeline(failing).prepare(episodeID: fixture.episodeID)
        }
        #expect(try await fixture.store.readyRevision(for: fixture.episodeID) == before)
        #expect(try Data(contentsOf: fixture.audioURL) == Data("original-audio-bytes".utf8))
    }

    /// The same guarantee one revision later, where it costs more: the audio a
    /// prepared episode plays from is the only copy left, the download it was
    /// cut out of having been deleted along with its revision. A failed re-run
    /// must leave that copy and its transcript exactly where they are.
    @Test func keepsAnAlreadyPreparedRevisionWhenAReRunFails() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let prepared = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        let before = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))

        let failing = WorkerStub(response: [
            "ok": false, "code": "cut-render-timeout", "message": "ffmpeg exceeded its 7200s limit",
        ])
        await #expect(throws: PodcastPreparationError.workerFailed(code: "cut-render-timeout",
                                                                  message: "ffmpeg exceeded its 7200s limit")) {
            _ = try await fixture.pipeline(failing).prepare(episodeID: fixture.episodeID)
        }
        #expect(try await fixture.store.readyRevision(for: fixture.episodeID) == before)
        #expect(try Data(contentsOf: prepared.mediaURL) == Fixture.cuttingAudio)
        #expect(try await fixture.store.transcript(for: fixture.episodeID,
                                                   revisionID: prepared.revision.revisionID) != nil)
    }

    /// Phase 4 gate: `commit(...)` writes the outcome row inside
    /// `replaceReadyRevision`'s save, strictly before `prepare()` ever calls
    /// `journalTerminal` -- whose own store write is best-effort (`try?`) and
    /// is documented as never allowed to be the thing that fails a
    /// preparation. So the outcome's durability cannot depend on that later
    /// write succeeding, and it must read back identically across repeated
    /// store reopens (no oscillation).
    @Test func commitPersistsTheOutcomeIndependentlyOfTheJournalAndSurvivesRepeatedReopens() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let result = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)

        let outcome = try #require(
            try await fixture.store.preparationOutcome(for: fixture.episodeID, revisionID: result.revision.revisionID)
        )
        #expect(outcome.episodeID == fixture.episodeID)
        #expect(outcome.revisionID == result.revision.revisionID)
        #expect(outcome.eligibility == .current)

        let storeURL = fixture.root.appendingPathComponent("library.sqlite")
        let firstReopen = try LocalLibraryStore(url: storeURL)
        let firstOutcome = try await firstReopen.preparationOutcome(
            for: fixture.episodeID, revisionID: result.revision.revisionID
        )
        #expect(firstOutcome == outcome)

        let secondReopen = try LocalLibraryStore(url: storeURL)
        let secondOutcome = try await secondReopen.preparationOutcome(
            for: fixture.episodeID, revisionID: result.revision.revisionID
        )
        #expect(secondOutcome == outcome, "the outcome must not oscillate across repeated reopens")
        #expect(firstOutcome == secondOutcome)
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
        #expect(PodcastPreparationResult.summary(advertisements: 0, secondsRemoved: 0, timing: .published,
                                                 adRemovalOutcome: "disabled")
                == "Ready · ad removal disabled · transcript synced from the feed")
    }

    @Test func rejectsLegacyAndIncompleteV2WorkerResponses() {
        let legacy = Data(#"{"ok":true,"protocolVersion":1,"timing":"none","audioPath":"/tmp/a.mp3"}"#.utf8)
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("unsupported protocolVersion")) {
            _ = try PodcastPreparationPipeline.decode(legacy)
        }
        let missingReport = Data(#"{"ok":true,"protocolVersion":2,"timing":"none","audioPath":"/tmp/a.mp3"}"#.utf8)
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("missing or invalid ad-removal report")) {
            _ = try PodcastPreparationPipeline.decode(missingReport)
        }
        let malformedNomination = v2Response(report:
            #"{"outcome":"noAds","rawNominations":[{"startSeconds":9.0,"endSeconds":1.0,"label":"x","confidence":0.5}],"# +
            #""audit":\#(cleanAuditJSON)}"#)
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("missing or invalid ad-removal report")) {
            _ = try PodcastPreparationPipeline.decode(malformedNomination)
        }
    }

    /// `noAds` from a detector that examined every window and `noAds` from one
    /// that never reached the model are the same sentence. Only the audit
    /// separates them, so an outcome without it is not a clean result.
    @Test func rejectsAnAdRemovalOutcomeThatCannotBeAudited() {
        let noAudit = v2Response(report: #"{"outcome":"noAds","rawNominations":[]}"#)
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("missing or unresolved ad-removal audit")) {
            _ = try PodcastPreparationPipeline.decode(noAudit)
        }
        let neverRan = v2Response(report:
            #"{"outcome":"noAds","rawNominations":[],"audit":{"modelRequests":0,"modelFailures":0,"# +
            #""experimentalRequests":0,"unresolvedIds":[],"incompleteError":null}}"#)
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("missing or unresolved ad-removal audit")) {
            _ = try PodcastPreparationPipeline.decode(neverRan)
        }
        let unresolved = v2Response(report:
            #"{"outcome":"noAds","rawNominations":[],"audit":{"modelRequests":4,"modelFailures":1,"# +
            #""experimentalRequests":0,"unresolvedIds":[7],"incompleteError":null}}"#)
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("missing or unresolved ad-removal audit")) {
            _ = try PodcastPreparationPipeline.decode(unresolved)
        }
        let incomplete = v2Response(report:
            #"{"outcome":"noAds","rawNominations":[],"audit":{"modelRequests":4,"modelFailures":2,"# +
            #""experimentalRequests":0,"unresolvedIds":[],"incompleteError":"budget exhausted"}}"#)
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("missing or unresolved ad-removal audit")) {
            _ = try PodcastPreparationPipeline.decode(incomplete)
        }
    }

    /// The outcome label is a claim about the delivered audio, so it has to
    /// agree with the map that describes it.
    @Test func rejectsAV2PayloadWhoseOutcomeContradictsItsTimeline() {
        let cutWithoutACut = v2Response(report:
            #"{"outcome":"cut","rawNominations":[],"audit":\#(cleanAuditJSON)}"#)
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("inconsistent ad-removal report")) {
            _ = try PodcastPreparationPipeline.decode(cutWithoutACut)
        }
        let disabledWithEvidence = v2Response(report:
            #"{"outcome":"disabled","rawNominations":[],"audit":\#(cleanAuditJSON)}"#)
        #expect(throws: PodcastPreparationError.malformedWorkerResponse("disabled ad removal reported detector evidence")) {
            _ = try PodcastPreparationPipeline.decode(disabledWithEvidence)
        }
    }

    @Test func realPythonUncertainResponsesDecodeUnderTheSwiftContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let python = ProcessInfo.processInfo.environment["WILTED_PIPELINE_PYTHON"]
            ?? "/opt/homebrew/opt/python@3.15/bin/python3.15"
        process.arguments = ["-u", "PYTHONPATH", python, "-B", "-c",
                             "import json; from test_wilted_pipeline import uncertain_contract_payloads; print(json.dumps(uncertain_contract_payloads()))"]
        process.currentDirectoryURL = root.appendingPathComponent("Producer/Workers")
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        let errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0, "synthetic Python worker contract failed: \(String(decoding: errorBytes, as: UTF8.self))")
        let entries = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        #expect(entries.compactMap { $0["scenario"] as? String } == ["missing-model", "share-ceiling", "declined-unresolved"])
        for entry in entries {
            let response = try #require(entry["payload"] as? [String: Any])
            let payload = try Self.decodeResponse(response)
            #expect(payload.adRemovalOutcome == "uncertain")
            #expect(!payload.audioChanged && payload.adSegments.isEmpty && payload.keepIntervals.isEmpty)
            #expect(payload.warning?.contains("original audio includes ads") == true)
            #expect(payload.adAuditDiagnostics["incompleteError"]?.isEmpty == false)
        }
    }

    private func uncertainResponse(audioPath: String = "/tmp/original.mp3") -> [String: Any] {
        let warning = "original audio includes ads: classifier could not resolve IDs 0, 1"
        var audit = WorkerStub.cleanAudit()
        audit["unresolvedIds"] = [0, 1]
        audit["incompleteError"] = "classifier could not resolve IDs 0, 1"
        audit["warning"] = warning
        audit["heldSpans"] = [[String: Any]]()
        audit["declinedCommercialEvidenceSeeds"] = [[String: Any]]()
        return ["ok": true, "protocolVersion": 2, "timing": "none", "audioPath": audioPath,
                "audioChanged": false, "durationSeconds": 12.0, "removedSeconds": 0.0,
                "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
                "report": ["outcome": "uncertain", "rawNominations": [[String: Any]](),
                           "warning": warning, "audit": audit]]
    }

    @Test func acceptsUncertaintyWithHonestDiagnosticsAndNoCuts() throws {
        var response = uncertainResponse()
        let payload = try Self.decodeResponse(response)
        #expect(payload.adRemovalOutcome == "uncertain")
        #expect(payload.warning?.contains("original audio includes ads") == true)
        #expect(!payload.audioChanged && payload.keepIntervals.isEmpty && payload.adSegments.isEmpty)
        var report = response["report"] as! [String: Any]
        var audit = report["audit"] as! [String: Any]
        audit["modelRequests"] = 0
        audit["modelFailures"] = 0
        audit["classifierRequests"] = 0
        audit["classifierValidRequests"] = 0
        report["audit"] = audit
        response["report"] = report
        #expect(try Self.decodeResponse(response).adRemovalOutcome == "uncertain")
    }

    private static func decodeResponse(_ response: [String: Any]) throws -> PodcastPreparationPipeline.WorkerPayload {
        try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: response))
    }

    @Test func rejectsDishonestOrMalformedUncertainEvidence() throws {
        let changes: [(String, Any)] = [
            ("audioChanged", true), ("removedSeconds", 1.0), ("durationSeconds", 0.0),
            ("adSegments", [["startSeconds": 1.0, "endSeconds": 2.0, "label": "ad", "confidence": 0.9]]),
            ("keepIntervals", [["startSeconds": 0.0, "endSeconds": 12.0, "outputStartSeconds": 0.0]])
        ]
        for (key, value) in changes {
            var response = uncertainResponse()
            response[key] = value
            #expect(throws: PodcastPreparationError.self) { _ = try Self.decodeResponse(response) }
        }
        for (key, value) in [("modelRequests", -1 as Any), ("modelFailures", "bad" as Any),
                             ("experimentalRequests", 1 as Any), ("unresolvedIds", [-1] as Any),
                             ("incompleteError", NSNull() as Any), ("heldSpans", "bad" as Any)] {
            var response = uncertainResponse()
            var report = response["report"] as! [String: Any]
            var audit = report["audit"] as! [String: Any]
            audit[key] = value
            report["audit"] = audit
            response["report"] = report
            #expect(throws: PodcastPreparationError.self) { _ = try Self.decodeResponse(response) }
        }
        for outcome in ["noAds", "cut"] {
            var response = uncertainResponse()
            var report = response["report"] as! [String: Any]
            report["outcome"] = outcome
            response["report"] = report
            #expect(throws: PodcastPreparationError.self) { _ = try Self.decodeResponse(response) }
        }
        var response = uncertainResponse()
        var report = response["report"] as! [String: Any]
        report["warning"] = ""
        response["report"] = report
        #expect(throws: PodcastPreparationError.self) { _ = try Self.decodeResponse(response) }
    }

    @Test func uncertaintyCompletesWithOriginalAudioAndDurableJournalWarning() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let result = try await fixture.pipeline(WorkerStub(response: uncertainResponse(audioPath: fixture.audioURL.path)))
            .prepare(episodeID: fixture.episodeID)
        #expect(result.revision.revisionID == fixture.revisionID)
        #expect(result.mediaURL == fixture.audioURL)
        #expect(try Data(contentsOf: result.mediaURL) == Data("original-audio-bytes".utf8))
        #expect(result.summary.contains("original audio includes ads"))
        #expect(!result.summary.contains("no ads found"))
        let reopened = try LocalLibraryStore(url: fixture.root.appendingPathComponent("library.sqlite"))
        let entries = try await reopened.preparationJournal(for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        let terminal = try #require(entries.last { $0.status.terminal })
        #expect(terminal.status.terminalResult?.outcome == .succeeded)
        #expect(terminal.status.detail.contains("original audio includes ads"))
        let evidence = try #require(entries.first { $0.id.contains("|pipeline.result#") })
        #expect(evidence.status.detail.contains("original audio includes ads"))
        #expect(evidence.status.evidence?.fields["warning"]?.contains("original audio includes ads") == true)
        #expect(evidence.status.evidence?.fields["unresolvedIds"] == "0,1")
        #expect(evidence.status.evidence?.fields["modelRequests"] == "3")
    }

    @Test func rejectsUncertaintyThatNamesDifferentAudioBeforeCommit() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        await #expect(throws: PodcastPreparationError.self) {
            _ = try await fixture.pipeline(WorkerStub(response: uncertainResponse(audioPath: "/tmp/changed.mp3")))
                .prepare(episodeID: fixture.episodeID)
        }
        #expect(try Data(contentsOf: fixture.audioURL) == Data("original-audio-bytes".utf8))
    }

    private var cleanAuditJSON: String {
        #"{"modelRequests":3,"modelFailures":0,"experimentalRequests":0,"unresolvedIds":[],"incompleteError":null}"#
    }

    private func v2Response(report: String) -> Data {
        Data(#"{"ok":true,"protocolVersion":2,"timing":"none","audioPath":"/tmp/a.mp3","audioChanged":false,"report":\#(report)}"#.utf8)
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

    /// Task 5.7, fourth clause. Every span's readout must be that span's own
    /// number: while the detector reported a constant 1.0 the percentage was
    /// true by accident, and a reader had no way to tell a corroborated span
    /// from a bare one.
    @Test func adProgressRendersEachSpansOwnConfidenceAsItsPercentage() {
        for confidence in [0.5, 0.6, 0.7, 0.775, 0.8, 0.95, 1.0] {
            let progress = PodcastPreparationPipeline.adProgress(
                PodcastAdSegment(startSeconds: 12, endSeconds: 24, label: "host read",
                                 confidence: confidence),
                ordinal: 1
            )
            let expected = "\(Int((confidence * 100).rounded()))%"
            #expect(progress.detail.hasSuffix("· " + expected),
                    "\(confidence) rendered as \(progress.detail)")
            #expect(progress.evidence?.fields["confidence"] == String(format: "%.4f", confidence))
        }

        // Two spans from one run must not render the same figure.
        let weak = PodcastPreparationPipeline.adProgress(
            PodcastAdSegment(startSeconds: 0, endSeconds: 10, label: "ad_break", confidence: 0.775),
            ordinal: 1
        )
        let strong = PodcastPreparationPipeline.adProgress(
            PodcastAdSegment(startSeconds: 20, endSeconds: 30, label: "ad_break", confidence: 0.95),
            ordinal: 2
        )
        #expect(weak.detail.hasSuffix("78%"))
        #expect(strong.detail.hasSuffix("95%"))
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

}

extension PodcastPreparationPipelineTests {
    @Test func persistedRunningTicketGenerationIsAttachedToEveryPipelineEvent() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let ticket = try await fixture.store.readmitWorkTicket(kind: .podcastPreparation,
            subjectID: fixture.episodeID.rawValue, requestSequence: 51, to: .running, at: Timestamp(Date()))
        let attempt = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
        _ = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID, attempt: attempt)
        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID), attempt: attempt)
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.status.attempt == attempt && $0.id.contains("|" + attempt.key + "|") })
        #expect(entries.last?.status.terminalResult?.outcome == .succeeded)
    }
}
