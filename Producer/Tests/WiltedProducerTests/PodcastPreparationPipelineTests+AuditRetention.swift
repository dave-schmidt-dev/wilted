import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

extension PodcastPreparationPipelineTests {
    /// An uncertain response whose global unresolved list is empty still has
    /// causes worth retaining: held spans and declined commercial seeds.
    private static func auditRetentionResponse(
        audioPath: String,
        heldSpans: [[String: Any]],
        declinedSeeds: [[String: Any]]
    ) -> [String: Any] {
        let warning = "original audio includes ads: classifier could not resolve commercial evidence"
        var audit = WorkerStub.cleanAudit()
        audit["unresolvedIds"] = [Int]()
        audit["incompleteError"] = "classifier could not resolve commercial evidence"
        audit["warning"] = warning
        audit["heldSpans"] = heldSpans
        audit["declinedCommercialEvidenceSeeds"] = declinedSeeds
        let report: [String: Any] = [
            "outcome": "uncertain",
            "rawNominations": [[String: Any]](),
            "warning": warning,
            "audit": audit,
        ]
        return [
            "ok": true, "protocolVersion": 2, "timing": "none", "audioPath": audioPath,
            "audioChanged": false, "durationSeconds": 12.0, "removedSeconds": 0.0,
            "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
            "report": report,
        ]
    }

    private static func auditRetentionDecode(
        _ response: [String: Any]
    ) throws -> PodcastPreparationPipeline.WorkerPayload {
        try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: response))
    }

    @Test func uncertainAuditRetainsHeldAndDeclinedCausesAcrossReopen() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let originalBytes = try Data(contentsOf: fixture.audioURL)
        let response = Self.auditRetentionResponse(
            audioPath: fixture.audioURL.path,
            heldSpans: [[
                "reason": "programme-boundary",
                "startSeconds": 12.5,
                "endSeconds": 18.0,
            ]],
            declinedSeeds: [[
                "status": "declined",
                "reason": "review-declined",
                "ids": [4, 9],
                "startSeconds": 20.25,
                "endSeconds": 24.0,
            ]]
        )

        let payload = try Self.auditRetentionDecode(response)
        #expect(payload.adRemovalOutcome == "uncertain")
        #expect(payload.adAuditDiagnostics["unresolvedIds"] == "")
        #expect(payload.adSegments.isEmpty)
        #expect(payload.keepIntervals.isEmpty)

        let result = try await fixture.pipeline(WorkerStub(response: response))
            .prepare(episodeID: fixture.episodeID)
        #expect(result.revision.revisionID == fixture.revisionID)
        #expect(result.mediaURL == fixture.audioURL)
        #expect(result.adSegments.isEmpty)
        #expect(result.warning?.hasPrefix("original audio includes ads:") == true)
        #expect(try Data(contentsOf: fixture.audioURL) == originalBytes)

        let reopened = try LocalLibraryStore(url: fixture.root.appendingPathComponent("library.sqlite"))
        let ready = try #require(try await reopened.readyRevision(for: fixture.episodeID))
        #expect(ready.revision.revisionID == fixture.revisionID)
        #expect(ready.mediaURL == fixture.audioURL)

        let requestID = PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        let entries = try await reopened.preparationJournal(for: requestID)
        let resultEntry = try #require(entries.first { $0.id.contains("|pipeline.result#") })
        let evidence = try #require(resultEntry.status.evidence)
        #expect(evidence.kind == "worker-result")
        #expect(evidence.fields["adRemovalOutcome"] == "uncertain")
        #expect(evidence.fields["advertisements"] == "0")
        #expect(evidence.fields["removedSeconds"] == "0.000")
        #expect(evidence.fields["audioChanged"] == "false")
        #expect(evidence.fields["unresolvedIds"] == "")
        let expectedHeld = "total=1;examined=1;omittedByCount=0;invalid=0;omittedByLength=0;shown=1;"
            + "spans=[programme-boundary@12.5-18.0]"
        let expectedDeclined = "total=1;examined=1;omittedByCount=0;invalid=0;omittedByLength=0;shown=1;"
            + "idsShown=2;idsOmittedByCount=0;idsOmittedByLength=0;"
            + "seeds=[review-declined@20.25-24.0#4,9]"
        #expect(evidence.fields["heldSpans"] == expectedHeld)
        #expect(evidence.fields["declinedCommercialEvidenceSeeds"] == expectedDeclined)

        let terminal = try #require(entries.last { $0.status.terminal })
        #expect(terminal.status.terminalResult?.outcome == .succeeded)
        #expect(terminal.status.detail.contains("original audio includes ads:"))
        #expect(!entries.contains { $0.status.stage == .assembling && $0.id.contains("ads.detect.span") })
    }

    @Test func cutOutcomeKeepsItsExistingEvidenceWithoutUncertainDiagnostics() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let result = try await fixture.pipeline(Fixture.cuttingStub())
            .prepare(episodeID: fixture.episodeID)

        let expectedRevision = try RevisionID.derive(
            podcastDownloadedAudioItemID: fixture.episodeID,
            contentHash: Fixture.contentHash(Fixture.cuttingAudio)
        )
        #expect(result.revision.revisionID == expectedRevision)
        #expect(result.revision.revisionID != fixture.revisionID)
        #expect(result.mediaURL != fixture.audioURL)
        #expect(try Data(contentsOf: result.mediaURL) == Fixture.cuttingAudio)
        #expect(result.adRemovalOutcome == "cut")
        #expect(result.removedSeconds == 4.5)
        #expect(result.adSegments.map { $0.startSeconds..<$0.endSeconds } == [3.0..<7.5])

        let entries = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        )
        let evidence = try #require(
            entries.first { $0.id.contains("|pipeline.result#") }?.status.evidence
        )
        #expect(evidence.kind == "worker-result")
        #expect(evidence.fields["advertisements"] == "1")
        #expect(evidence.fields["adRemovalOutcome"] == "cut")
        #expect(evidence.fields["audioChanged"] == "true")
        #expect(evidence.fields["heldSpans"] == nil)
        #expect(evidence.fields["declinedCommercialEvidenceSeeds"] == nil)
        #expect(evidence.fields["unresolvedIds"] == nil)

        let terminal = try #require(entries.last { $0.status.terminal })
        #expect(terminal.status.terminalResult?.outcome == .succeeded)
        #expect(terminal.status.terminalResult?.revisionID == expectedRevision)
        #expect(terminal.status.timeline?.removed.map { $0.originalStartSeconds..<$0.originalEndSeconds }
                == [3.0..<7.5])
        #expect(terminal.status.timeline?.kept.count == 2)
    }

    @Test func oversizedAuditArraysStayBoundedCompleteAndContentFree() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let originalBytes = try Data(contentsOf: fixture.audioURL)
        let heldSpans: [[String: Any]] = [
            ["reason": "programme-boundary", "startSeconds": 1.25, "endSeconds": 2.5],
            ["reason": "total-share-ceiling", "startSeconds": 3.0, "endSeconds": 4.0],
            ["reason": "SECRET transcript model response prompt", "startSeconds": 5.0, "endSeconds": 6.0,
             "detail": "SECRET transcript model response prompt"],
            ["reason": "programme-boundary", "startSeconds": 6.0, "endSeconds": 7.0],
            ["reason": "credits-boundary-unresolved", "startSeconds": 7.0, "endSeconds": 8.0],
            ["reason": "boundary-review-unresolved", "startSeconds": 9.0, "endSeconds": 10.0],
            ["reason": "sponsor-prefix-programme-found", "startSeconds": 11.0, "endSeconds": 12.0],
            ["reason": "pod-continuation-bracket", "startSeconds": 13.0, "endSeconds": 14.0],
            ["reason": "programme-boundary", "startSeconds": 15.0, "endSeconds": 16.0],
            ["reason": "total-share-ceiling", "startSeconds": 17.0, "endSeconds": 18.0],
            ["reason": "credits-boundary-unresolved", "startSeconds": 19.0, "endSeconds": 20.0],
            ["reason": "boundary-review-unresolved", "startSeconds": 21.0, "endSeconds": 22.0],
        ]
        let declinedSeeds: [[String: Any]] = [
            ["status": "declined", "reason": "review-unresolved",
             "ids": Array(0..<40), "startSeconds": 1.0, "endSeconds": 2.0],
            ["status": "declined", "reason": "review-declined",
             "ids": [100, 101], "startSeconds": 3.0, "endSeconds": 4.0],
            ["status": "declined", "reason": "SECRET model-response prompt",
             "ids": [200], "startSeconds": 5.0, "endSeconds": 6.0,
             "detail": "SECRET transcript model response prompt"],
            ["status": "declined", "reason": "dropped-after-proposal",
             "ids": [201, 202], "startSeconds": 7.0, "endSeconds": 8.0],
            ["status": "declined", "reason": "review-unresolved",
             "ids": [203], "startSeconds": 9.0, "endSeconds": 10.0],
            ["status": "declined", "reason": "review-declined",
             "ids": [204, 205, 206], "startSeconds": 11.0, "endSeconds": 12.0],
            ["status": "declined", "reason": "review-unresolved",
             "ids": [207], "startSeconds": 13.0, "endSeconds": 14.0],
            ["status": "declined", "reason": "review-declined",
             "ids": [208], "startSeconds": 15.0, "endSeconds": 16.0],
            ["status": "declined", "reason": "review-unresolved",
             "ids": [209], "startSeconds": 17.0, "endSeconds": 18.0],
            ["status": "declined", "reason": "review-declined",
             "ids": [210], "startSeconds": 19.0, "endSeconds": 20.0],
            ["status": "declined", "reason": "review-unresolved",
             "ids": [211], "startSeconds": 21.0, "endSeconds": 22.0],
            ["status": "declined", "reason": "review-declined",
             "ids": [212], "startSeconds": 23.0, "endSeconds": 24.0],
        ]
        let response = Self.auditRetentionResponse(
            audioPath: fixture.audioURL.path, heldSpans: heldSpans, declinedSeeds: declinedSeeds
        )

        let first = PodcastPreparationPipeline.resultProgress(try Self.auditRetentionDecode(response))
        let second = PodcastPreparationPipeline.resultProgress(try Self.auditRetentionDecode(response))
        let evidence = try #require(first.evidence)
        #expect(evidence.kind == "worker-result")
        #expect(evidence.fields.count == 15)
        #expect(evidence.fields.count <= 16)
        for value in evidence.fields.values {
            #expect(value.count <= 256)
            #expect(value.unicodeScalars.allSatisfy { $0.isASCII })
        }
        #expect(first.evidence?.fields["heldSpans"] == second.evidence?.fields["heldSpans"])
        #expect(first.evidence?.fields["declinedCommercialEvidenceSeeds"]
                == second.evidence?.fields["declinedCommercialEvidenceSeeds"])

        let held = try #require(evidence.fields["heldSpans"])
        #expect(held.contains("total=12;examined=8;omittedByCount=4;invalid=1;"))
        #expect(held.contains("omittedByLength="))
        #expect(held.contains("programme-boundary@1.25-2.5"))
        #expect(!held.contains("SECRET"))
        #expect(!held.contains("transcript"))
        #expect(!held.contains("model response"))
        #expect(!held.contains("prompt"))

        let declined = try #require(evidence.fields["declinedCommercialEvidenceSeeds"])
        #expect(declined.contains("total=12;examined=8;omittedByCount=4;invalid=1;"))
        #expect(declined.contains("idsOmittedByCount=24"))
        #expect(declined.contains("#0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15"))
        #expect(!declined.contains("15,16"))
        #expect(!declined.contains("omittedByLength=0;"))
        #expect(declined.contains("idsOmittedByLength="))
        #expect(!declined.contains("SECRET"))
        #expect(!declined.contains("transcript"))
        #expect(!declined.contains("model response"))
        #expect(!declined.contains("prompt"))

        let result = try await fixture.pipeline(WorkerStub(response: response))
            .prepare(episodeID: fixture.episodeID)
        #expect(result.revision.revisionID == fixture.revisionID)
        #expect(result.mediaURL == fixture.audioURL)
        #expect(try Data(contentsOf: fixture.audioURL) == originalBytes)

        let reopened = try LocalLibraryStore(url: fixture.root.appendingPathComponent("library.sqlite"))
        let entries = try await reopened.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        )
        let persisted = try #require(
            entries.first { $0.id.contains("|pipeline.result#") }?.status.evidence
        )
        #expect(persisted.fields["heldSpans"] == held)
        #expect(persisted.fields["declinedCommercialEvidenceSeeds"] == declined)
        let terminal = try #require(entries.last { $0.status.terminal })
        #expect(terminal.status.terminalResult?.outcome == .succeeded)
    }

    @Test func declinedCueIdentifiersRetainExactIntegerPrecision() throws {
        let identifier = 9_007_199_254_740_993
        let response = Self.auditRetentionResponse(
            audioPath: "/synthetic/original.mp3", heldSpans: [],
            declinedSeeds: [["status": "declined", "reason": "review-unresolved",
                             "ids": [identifier], "startSeconds": 2.0, "endSeconds": 3.0]]
        )
        let payload = try Self.auditRetentionDecode(response)
        let summary = try #require(payload.adAuditDiagnostics["declinedCommercialEvidenceSeeds"])
        #expect(summary.contains("#\(identifier)]"))
        #expect(!summary.contains("#9007199254740992]"))
    }

    @Test func booleanAuditIntervalsAreNeverProjectedAsNumbers() throws {
        let response = Self.auditRetentionResponse(
            audioPath: "/tmp/original.mp3",
            heldSpans: [["reason": "programme-boundary", "startSeconds": true, "endSeconds": 2.0]],
            declinedSeeds: []
        )
        do {
            let payload = try Self.auditRetentionDecode(response)
            let evidence = try #require(PodcastPreparationPipeline.resultProgress(payload).evidence)
            let held = try #require(evidence.fields["heldSpans"])
            #expect(held.contains("total=1;examined=1;omittedByCount=0;invalid=1;"))
            #expect(!held.contains("programme-boundary@1.0-2.0"))
        } catch {
            // The existing audit guard may reject the boolean outright. Either
            // way it must never become numeric diagnostic evidence.
            #expect(error is PodcastPreparationError)
        }
    }

    @Test func maximumUncertainEvidenceKeepsEveryFieldWithinTheDomainBound() throws {
        var response = Self.auditRetentionResponse(
            audioPath: "/tmp/original.mp3",
            heldSpans: [["reason": "programme-boundary", "startSeconds": 1.0, "endSeconds": 2.0]],
            declinedSeeds: [["status": "declined", "reason": "review-unresolved",
                             "ids": [3, 4], "startSeconds": 2.0, "endSeconds": 3.0]]
        )
        let longWarning = "original audio includes ads: " + String(repeating: "w", count: 800)
        var report = try #require(response["report"] as? [String: Any])
        var audit = try #require(report["audit"] as? [String: Any])
        report["warning"] = longWarning
        audit["warning"] = longWarning
        audit["incompleteError"] = String(repeating: "e", count: 900)
        audit["unresolvedIds"] = Array(0..<200)
        report["audit"] = audit
        response["report"] = report

        let progress = PodcastPreparationPipeline.resultProgress(try Self.auditRetentionDecode(response))
        let evidence = try #require(progress.evidence)
        #expect(evidence.fields.count == 15)
        #expect(evidence.fields.values.allSatisfy { $0.count <= 256 })
        #expect(evidence.fields["warning"]?.count == 256)
        #expect(evidence.fields["incompleteError"]?.count == 256)
        #expect(evidence.fields["unresolvedIds"]?.count == 256)
        #expect(evidence.fields["heldSpans"] != nil)
        #expect(evidence.fields["declinedCommercialEvidenceSeeds"] != nil)
    }

    @Test func malformedUncertainDiagnosticsStillRejectWithoutProjection() throws {
        let negative = Self.auditRetentionResponse(
            audioPath: "/tmp/original.mp3",
            heldSpans: [["reason": "programme-boundary", "startSeconds": -1.0, "endSeconds": 2.0]],
            declinedSeeds: []
        )
        #expect(throws: PodcastPreparationError.self) {
            _ = try Self.auditRetentionDecode(negative)
        }

        let nonNumeric = Self.auditRetentionResponse(
            audioPath: "/tmp/original.mp3",
            heldSpans: [["reason": "programme-boundary", "startSeconds": "1.0", "endSeconds": 2.0]],
            declinedSeeds: []
        )
        #expect(throws: PodcastPreparationError.self) {
            _ = try Self.auditRetentionDecode(nonNumeric)
        }

        let nonFinite = Data(#"{"ok":true,"protocolVersion":2,"timing":"none","audioPath":"/tmp/original.mp3","audioChanged":false,"durationSeconds":12.0,"removedSeconds":0.0,"adSegments":[],"keepIntervals":[],"report":{"outcome":"uncertain","rawNominations":[],"warning":"original audio includes ads: classifier could not resolve IDs 0","audit":{"classifierRequests":3,"classifierValidRequests":3,"classifierInvalidRequests":0,"exhaustedSingletonLineages":0,"modelRequests":3,"modelFailures":0,"experimentalRequests":0,"unresolvedIds":[0],"candidates":[],"declinedCommercialEvidenceSeeds":[],"heldSpans":[{"reason":"programme-boundary","startSeconds":1e999,"endSeconds":2.0}],"incompleteError":"classifier could not resolve IDs 0","warning":"original audio includes ads: classifier could not resolve IDs 0"}}}"#.utf8)
        #expect(throws: PodcastPreparationError.self) {
            _ = try PodcastPreparationPipeline.decode(nonFinite)
        }
    }
}
