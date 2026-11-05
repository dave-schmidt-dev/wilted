import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Podcast opening review diagnostics")
struct PodcastOpeningReviewDiagnosticsTests {
    private typealias Fixture = PodcastPreparationPipelineTests.Fixture

    private static let validDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private static func validOpeningReview(
        schemaVersion: Any = 1,
        status: Any = "accepted",
        candidateEndSeconds: Any = 15.0,
        candidateCueCount: Any = 10,
        quoteCount: Any = 2,
        coveredCueIDs: Any = [0, 1, 2],
        quoteEvidenceDigest: Any = validDigest,
        quoteOrigin: Any? = nil,
        extraFields: [String: Any] = [:]
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "schemaVersion": schemaVersion,
            "status": status,
            "candidateEndSeconds": candidateEndSeconds,
            "candidateCueCount": candidateCueCount,
            "quoteCount": quoteCount,
            "coveredCueIDs": coveredCueIDs,
            "quoteEvidenceDigest": quoteEvidenceDigest,
        ]
        if let quoteOrigin {
            dict["quoteOrigin"] = quoteOrigin
        }
        dict.merge(extraFields) { _, new in new }
        return dict
    }

    private static func cutResponse(
        openingReview: [String: Any]? = nil,
        silenceTrims: [[String: Any]] = []
    ) -> [String: Any] {
        var response = Fixture.cuttingStubResponse()
        response["protocolVersion"] = 2
        response["audioPath"] = "/tmp/test-audio.mp3"
        response["silenceTrims"] = silenceTrims
        var audit = WorkerStub.cleanAudit()
        if let openingReview {
            audit["openingReview"] = openingReview
        }
        response["report"] = [
            "outcome": "cut",
            "rawNominations": response["adSegments"] as? [[String: Any]] ?? [],
            "audit": audit,
        ]
        return response
    }

    private static func uncertainResponse(
        openingReview: [String: Any]? = nil
    ) -> [String: Any] {
        let warning = "original audio includes ads: classifier could not resolve IDs 0"
        var audit = WorkerStub.cleanAudit()
        audit["unresolvedIds"] = [0]
        audit["incompleteError"] = "classifier could not resolve IDs 0"
        audit["warning"] = warning
        audit["heldSpans"] = [[
            "reason": "programme-boundary",
            "startSeconds": 1.0,
            "endSeconds": 2.0,
        ]]
        audit["declinedCommercialEvidenceSeeds"] = [[
            "status": "declined",
            "reason": "review-declined",
            "ids": [0],
            "startSeconds": 1.0,
            "endSeconds": 2.0,
        ]]
        if let openingReview {
            audit["openingReview"] = openingReview
        }
        let report: [String: Any] = [
            "outcome": "uncertain",
            "rawNominations": [[String: Any]](),
            "warning": warning,
            "audit": audit,
        ]
        return [
            "ok": true, "protocolVersion": 2, "timing": "none", "audioPath": "/tmp/test-audio.mp3",
            "audioChanged": false, "durationSeconds": 12.0, "removedSeconds": 0.0,
            "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
            "report": report,
        ]
    }

    @Test func validAcceptedReceiptSurvivesDecodeAndJournalOnCut() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        let receipt = Self.validOpeningReview(
            candidateEndSeconds: 15.0,
            candidateCueCount: 10,
            quoteCount: 2,
            coveredCueIDs: [0, 1, 2]
        )
        let response = Self.cutResponse(openingReview: receipt)
        let payload = try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: response))

        let expectedSummary = "end=15.0;candidateCount=10;quoteCount=2;"
            + "quoteOrigin=unreported;coveredIDs=0,1,2;omittedIDCount=0;digest=\(Self.validDigest)"
        #expect(payload.adAuditDiagnostics["openingReview"] == expectedSummary)

        let progress = PodcastPreparationPipeline.resultProgress(payload)
        let progressEvidence = try #require(progress.evidence)
        #expect(progressEvidence.fields["openingReview"] == expectedSummary)

        let worker = WorkerStub(response: response, writesCutAudio: Fixture.cuttingAudio)
        let result = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID)
        #expect(result.adRemovalOutcome == "cut")

        let requestID = PodcastPreparationPipeline.requestID(for: fixture.episodeID)
        let entries = try await fixture.store.preparationJournal(for: requestID)
        let resultEntry = try #require(entries.first { $0.id.contains("|pipeline.result#") })
        let journalEvidence = try #require(resultEntry.status.evidence)
        #expect(journalEvidence.kind == "worker-result")
        #expect(journalEvidence.fields["openingReview"] == expectedSummary)
        #expect(journalEvidence.fields["advertisements"] == "1")
        #expect(journalEvidence.fields["adRemovalOutcome"] == "cut")
        #expect(journalEvidence.fields["heldSpans"] == nil)
        #expect(journalEvidence.fields["declinedCommercialEvidenceSeeds"] == nil)
    }

    @Test func absentOldPayloadUnchanged() throws {
        let cutResponse = Self.cutResponse(openingReview: nil)
        let cutPayload = try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: cutResponse))
        #expect(cutPayload.adAuditDiagnostics.isEmpty)
        let cutProgress = PodcastPreparationPipeline.resultProgress(cutPayload)
        #expect(cutProgress.evidence?.fields["openingReview"] == nil)

        let uncertainResponse = Self.uncertainResponse(openingReview: nil)
        let uncertainPayload = try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: uncertainResponse))
        #expect(uncertainPayload.adAuditDiagnostics["openingReview"] == nil)
        #expect(uncertainPayload.adAuditDiagnostics["incompleteError"] != nil)
        let uncertainProgress = PodcastPreparationPipeline.resultProgress(uncertainPayload)
        #expect(uncertainProgress.evidence?.fields["openingReview"] == nil)
        #expect(uncertainProgress.evidence?.fields["incompleteError"] != nil)
    }

    @Test func quoteOriginIsBoundedAndLegacyMissingOriginIsAccepted() {
        let legacy = Self.validOpeningReview()
        let legacySummary = PodcastPreparationPipeline.openingReviewDiagnosticSummary(legacy)
        #expect(legacySummary?.contains("quoteOrigin=unreported") == true)

        for origin in ["initial", "literal-repair"] {
            let receipt = Self.validOpeningReview(quoteOrigin: origin)
            let summary = PodcastPreparationPipeline.openingReviewDiagnosticSummary(receipt)
            #expect(summary?.contains("quoteOrigin=\(origin)") == true)
        }

        for invalidOrigin: Any in ["model", 7, NSNull()] {
            let receipt = Self.validOpeningReview(quoteOrigin: invalidOrigin)
            #expect(PodcastPreparationPipeline.openingReviewDiagnosticSummary(receipt) == nil)
        }
    }

    @Test func malformedReceiptIgnoredWithoutFailingAudio() throws {
        let invalidReceipts: [(name: String, receipt: [String: Any])] = [
            ("bool schemaVersion", Self.validOpeningReview(schemaVersion: true)),
            ("unknown schemaVersion", Self.validOpeningReview(schemaVersion: 2)),
            ("schemaVersion 0", Self.validOpeningReview(schemaVersion: 0)),
            ("non-accepted status", Self.validOpeningReview(status: "rejected")),
            ("bool status", Self.validOpeningReview(status: true)),
            ("infinite candidateEndSeconds", Self.validOpeningReview(candidateEndSeconds: Double.infinity)),
            ("NaN candidateEndSeconds", Self.validOpeningReview(candidateEndSeconds: Double.nan)),
            ("zero candidateEndSeconds", Self.validOpeningReview(candidateEndSeconds: 0.0)),
            ("negative candidateEndSeconds", Self.validOpeningReview(candidateEndSeconds: -1.0)),
            ("candidateEndSeconds > 300", Self.validOpeningReview(candidateEndSeconds: 300.1)),
            ("bool candidateEndSeconds", Self.validOpeningReview(candidateEndSeconds: true)),
            ("candidateCueCount 0", Self.validOpeningReview(candidateCueCount: 0)),
            ("candidateCueCount 96", Self.validOpeningReview(candidateCueCount: 96)),
            ("bool candidateCueCount", Self.validOpeningReview(candidateCueCount: true)),
            ("quoteCount 0", Self.validOpeningReview(quoteCount: 0)),
            ("quoteCount 96", Self.validOpeningReview(quoteCount: 96)),
            ("bool quoteCount", Self.validOpeningReview(quoteCount: true)),
            ("empty coveredCueIDs", Self.validOpeningReview(coveredCueIDs: [Int]())),
            ("coveredCueIDs > 95", Self.validOpeningReview(candidateCueCount: 95, coveredCueIDs: Array(0...95))),
            ("bool in coveredCueIDs", Self.validOpeningReview(coveredCueIDs: [0, true, 2])),
            ("negative ID in coveredCueIDs", Self.validOpeningReview(coveredCueIDs: [-1, 1])),
            ("ID >= candidateCueCount", Self.validOpeningReview(candidateCueCount: 5, coveredCueIDs: [0, 5])),
            ("unsorted coveredCueIDs", Self.validOpeningReview(coveredCueIDs: [0, 3, 2])),
            ("duplicated coveredCueIDs", Self.validOpeningReview(coveredCueIDs: [1, 1])),
            ("short digest", Self.validOpeningReview(quoteEvidenceDigest: "0123456789abcdef")),
            ("long digest", Self.validOpeningReview(quoteEvidenceDigest: Self.validDigest + "a")),
            ("uppercase digest", Self.validOpeningReview(quoteEvidenceDigest: Self.validDigest.uppercased())),
            ("non-hex digest", Self.validOpeningReview(quoteEvidenceDigest: String(repeating: "z", count: 64))),
            ("unknown quoteOrigin", Self.validOpeningReview(quoteOrigin: "model")),
            ("non-string quoteOrigin", Self.validOpeningReview(quoteOrigin: 7)),
        ]

        for (name, receipt) in invalidReceipts {
            let response = Self.cutResponse(openingReview: receipt)
            // NaN and infinity cannot travel in JSON; exercise their defensive
            // projection check directly rather than failing fixture encoding.
            guard JSONSerialization.isValidJSONObject(response) else {
                #expect(PodcastPreparationPipeline.openingReviewDiagnosticSummary(receipt) == nil)
                continue
            }
            let payload = try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: response))
            #expect(payload.adAuditDiagnostics["openingReview"] == nil, "Failed to ignore malformed receipt: \(name)")
            let progress = PodcastPreparationPipeline.resultProgress(payload)
            #expect(progress.evidence?.fields["openingReview"] == nil, "Progress leaked malformed receipt: \(name)")
        }
    }

    @Test func max95IDReceiptObeysDiagnosticAndJournalEvidenceLimits() throws {
        let maxIDs = Array(0..<95)
        let receipt = Self.validOpeningReview(
            candidateEndSeconds: 300.0,
            candidateCueCount: 95,
            quoteCount: 95,
            coveredCueIDs: maxIDs
        )
        var cutResponse = Self.cutResponse(
            openingReview: receipt,
            silenceTrims: [["startSeconds": 0.0, "endSeconds": 0.5]]
        )
        cutResponse["durationSeconds"] = 7.0
        cutResponse["keepIntervals"] = [
            ["startSeconds": 0.5, "endSeconds": 3.0, "outputStartSeconds": 0.0],
            ["startSeconds": 7.5, "endSeconds": 12.0, "outputStartSeconds": 2.5],
        ]
        let cutPayload = try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: cutResponse))

        let diagnostic = try #require(cutPayload.adAuditDiagnostics["openingReview"])
        #expect(diagnostic.count <= 256)
        #expect(diagnostic.contains("end=300.0"))
        #expect(diagnostic.contains("candidateCount=95"))
        #expect(diagnostic.contains("quoteCount=95"))
        let expectedFirst16 = Array(0..<16).map(String.init).joined(separator: ",")
        #expect(diagnostic.contains("coveredIDs=\(expectedFirst16)"))
        #expect(diagnostic.contains("omittedIDCount=79"))
        #expect(diagnostic.contains("digest=\(Self.validDigest)"))

        let cutProgress = PodcastPreparationPipeline.resultProgress(cutPayload)
        let cutEvidence = try #require(cutProgress.evidence)
        #expect(cutEvidence.fields.count <= 16)
        #expect(cutEvidence.fields["silenceRemovedSeconds"] != nil)
        #expect(cutEvidence.fields["openingReview"] == diagnostic)
        for (key, value) in cutEvidence.fields {
            #expect(key.count <= 64)
            #expect(value.count <= 256)
        }

        let uncertainResponse = Self.uncertainResponse(openingReview: receipt)
        let uncertainPayload = try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: uncertainResponse))
        #expect(uncertainPayload.adAuditDiagnostics["openingReview"] == diagnostic)

        let uncertainProgress = PodcastPreparationPipeline.resultProgress(uncertainPayload)
        let uncertainEvidence = try #require(uncertainProgress.evidence)
        #expect(uncertainEvidence.fields.count <= 16)
        #expect(uncertainEvidence.fields["warning"] != nil)
        #expect(uncertainEvidence.fields["openingReview"] == diagnostic)
        for (key, value) in uncertainEvidence.fields {
            #expect(key.count <= 64)
            #expect(value.count <= 256)
        }
    }

    @Test func rawQuotesAndUnknownFieldsNeverEmitted() throws {
        let rawQuote = "Commercial sponsor raw body text that should not leak."
        let secretURL = "https://sensitive.internal.example/tracker"
        let receipt = Self.validOpeningReview(
            extraFields: [
                "rawQuote": rawQuote,
                "privateURL": secretURL,
                "validatedQuotes": [
                    [
                        "id": "q1",
                        "coveredIDs": [0, 1],
                        "wordCount": 10,
                        "sha256": Self.validDigest,
                        "rawText": rawQuote,
                        "url": secretURL,
                    ],
                ],
                "arbitraryExtra": "discard-me",
            ]
        )

        let response = Self.cutResponse(openingReview: receipt)
        let payload = try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: response))
        let diagnostic = try #require(payload.adAuditDiagnostics["openingReview"])

        #expect(!diagnostic.contains(rawQuote))
        #expect(!diagnostic.contains(secretURL))
        #expect(!diagnostic.contains("validatedQuotes"))
        #expect(!diagnostic.contains("arbitraryExtra"))
        #expect(!diagnostic.contains("discard-me"))

        let progress = PodcastPreparationPipeline.resultProgress(payload)
        let evidence = try #require(progress.evidence)
        for (_, value) in evidence.fields {
            #expect(!value.contains(rawQuote))
            #expect(!value.contains(secretURL))
            #expect(!value.contains("discard-me"))
        }
    }

    @Test func attachesOnSuccessfulNoAdsOutcome() throws {
        var response = Fixture.cuttingStubResponse()
        response["protocolVersion"] = 2
        response["audioPath"] = "/tmp/test-audio.mp3"
        response["audioChanged"] = false
        response["removedSeconds"] = 0.0
        response["adSegments"] = [[String: Any]]()
        response["keepIntervals"] = [[String: Any]]()
        var audit = WorkerStub.cleanAudit()
        audit["openingReview"] = Self.validOpeningReview()
        response["report"] = [
            "outcome": "noAds",
            "rawNominations": [[String: Any]](),
            "audit": audit,
        ]

        let payload = try PodcastPreparationPipeline.decode(JSONSerialization.data(withJSONObject: response))
        #expect(payload.adRemovalOutcome == "noAds")
        #expect(payload.adAuditDiagnostics["openingReview"] != nil)
        let progress = PodcastPreparationPipeline.resultProgress(payload)
        #expect(progress.evidence?.fields["openingReview"] != nil)
    }
}
