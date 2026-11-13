import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The diagnostic stamp the episode info popover shows: which Wilted build
/// and ad engine produced the audio, and what the newest attempt did when it
/// failed. The prepared line always names the run behind the ready revision,
/// never whichever attempt happens to be newest.
@MainActor
final class WiltedMacPreparationStampTests: XCTestCase {
    private typealias BuildStamp = (appVersion: String?, engineVersion: String, codeRevision: String?)
    private let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    private let later = Timestamp(Date(timeIntervalSince1970: 1_700_003_600))

    // MARK: Prepared line

    func testStampedSuccessfulRunNamesTheBuildAndEngine() throws {
        let itemID = try makeItemID()
        let revisionID = try makeRevisionID("7")
        let run = try succeededRun(
            itemID: itemID, revisionID: revisionID,
            stamp: (appVersion: "0.7.0 (12, abc1234567)", engineVersion: "podcast-preparation-v8",
                    codeRevision: "d9e8fb14de"))

        let stamp = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: revisionID),
            readyRevisionID: revisionID,
            runs: [run]))

        XCTAssertEqual(stamp.prepared, "Prepared by Wilted 0.7.0 (12, abc1234567) · ad engine v8 (d9e8fb14de)")
        XCTAssertNil(stamp.lastFailure)
        XCTAssertNil(stamp.failureDetail)
    }

    func testStampedSuccessfulRunWithoutCodeRevisionOmitsIt() throws {
        let itemID = try makeItemID()
        let revisionID = try makeRevisionID("7")
        let run = try succeededRun(
            itemID: itemID, revisionID: revisionID,
            stamp: (appVersion: "0.7.0 (12, abc1234567)", engineVersion: "podcast-preparation-v8",
                    codeRevision: nil))

        let stamp = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: revisionID),
            readyRevisionID: revisionID,
            runs: [run]))

        XCTAssertEqual(stamp.prepared, "Prepared by Wilted 0.7.0 (12, abc1234567) · ad engine v8")
    }

    func testUnstampedSuccessfulRunFallsBackToTheSemanticVersion() throws {
        let itemID = try makeItemID()
        let revisionID = try makeRevisionID("7")
        let run = try succeededRun(itemID: itemID, revisionID: revisionID, stamp: nil)

        let stamp = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: makeOutcome(
                itemID: itemID, revisionID: revisionID, semanticVersion: "podcast-preparation-v9"),
            readyRevisionID: revisionID,
            runs: [run]))

        XCTAssertEqual(stamp.prepared, "Prepared with ad engine v9 · app build not recorded")
    }

    // MARK: Failure line

    func testNewerFailedRunKeepsThePreparedLineAndBoundsTheDetail() throws {
        let itemID = try makeItemID()
        let revisionID = try makeRevisionID("7")
        let prepared = try succeededRun(
            itemID: itemID, revisionID: revisionID,
            stamp: (appVersion: "0.7.0 (12, abc1234567)", engineVersion: "podcast-preparation-v8",
                    codeRevision: "d9e8fb14de"))
        let failed = try failedRun(
            itemID: itemID, message: String(repeating: "x", count: 500),
            stamp: (appVersion: "0.7.0 (12, abc1234567)", engineVersion: "podcast-preparation-v9",
                    codeRevision: nil),
            updatedAt: later)

        let stamp = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: revisionID),
            readyRevisionID: revisionID,
            runs: [prepared, failed]))

        XCTAssertEqual(stamp.prepared, "Prepared by Wilted 0.7.0 (12, abc1234567) · ad engine v8 (d9e8fb14de)",
                       "a later failed retry must not relabel the audio the older success produced")
        XCTAssertEqual(stamp.lastFailure, "Last attempt failed · Wilted 0.7.0 (12, abc1234567) · ad engine v9")
        let detail = try XCTUnwrap(stamp.failureDetail)
        XCTAssertEqual(detail.count, 300)
        XCTAssertTrue(detail.hasSuffix("…"))
        XCTAssertEqual(stamp.displayText,
                       "\(stamp.prepared ?? "")\n\(stamp.lastFailure ?? "")\n\(detail)")
    }

    func testFailedRunWithoutStampSaysBuildNotRecorded() throws {
        let itemID = try makeItemID()
        let revisionID = try makeRevisionID("7")
        let failed = try failedRun(
            itemID: itemID, message: "Worker exited before producing output.",
            stamp: nil, updatedAt: later)

        let stamp = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: revisionID),
            readyRevisionID: revisionID,
            runs: [failed]))

        XCTAssertNil(stamp.prepared, "no run produced the ready revision, so nothing is proven prepared")
        XCTAssertEqual(stamp.lastFailure, "Last attempt failed · build not recorded")
        XCTAssertEqual(stamp.failureDetail, "Worker exited before producing output.")
    }

    // MARK: Guards

    func testInvalidOutcomeShowsNoPreparedLine() throws {
        let itemID = try makeItemID()
        let revisionID = try makeRevisionID("7")
        let run = try succeededRun(
            itemID: itemID, revisionID: revisionID,
            stamp: (appVersion: "0.7.0 (12, abc1234567)", engineVersion: "podcast-preparation-v8",
                    codeRevision: "d9e8fb14de"))

        let stamp = WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: revisionID, eligibility: .invalid),
            readyRevisionID: revisionID,
            runs: [run])

        XCTAssertNil(stamp?.prepared)
    }

    func testOutcomeForAnotherRevisionShowsNoPreparedLine() throws {
        let itemID = try makeItemID()
        let readyRevisionID = try makeRevisionID("7")
        let staleRevisionID = try makeRevisionID("8")
        let staleRun = try succeededRun(
            itemID: itemID, revisionID: staleRevisionID,
            stamp: (appVersion: "0.7.0 (12, abc1234567)", engineVersion: "podcast-preparation-v8",
                    codeRevision: "d9e8fb14de"))

        let stamp = WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: staleRevisionID),
            readyRevisionID: readyRevisionID,
            runs: [staleRun])

        XCTAssertNil(stamp?.prepared)
    }

    func testNoOutcomeAndNoRunsGivesNil() {
        XCTAssertNil(WiltedMacPreparationStamp.make(
            outcome: nil, readyRevisionID: nil, runs: []))
    }

    // MARK: Earlier ad-finding setting

    func testEarlierSettingLineAppearsOnlyForDifferingDigest() throws {
        let itemID = try makeItemID()
        let revisionID = try makeRevisionID("7")
        let recorded = "sha256:" + String(repeating: "aa", count: 32)
        let other = "sha256:" + String(repeating: "bb", count: 32)
        let run = try succeededRun(
            itemID: itemID, revisionID: revisionID,
            stamp: (appVersion: "0.7.0 (12, abc1234567)",
                    engineVersion: PodcastPreparationPipeline.semanticVersion,
                    codeRevision: nil),
            policyDigest: recorded)

        let differing = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: revisionID, policyDigest: recorded),
            readyRevisionID: revisionID,
            runs: [run],
            labelledDigestInForce: other))
        XCTAssertEqual(differing.earlierAdFindingSetting,
                       WiltedMacPreparationStamp.earlierAdFindingSettingLine)
        XCTAssertTrue(differing.displayText?.contains(WiltedMacPreparationStamp.earlierAdFindingSettingLine) == true)

        let equal = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: revisionID, policyDigest: recorded),
            readyRevisionID: revisionID,
            runs: [run],
            labelledDigestInForce: recorded))
        XCTAssertNil(equal.earlierAdFindingSetting)

        let empty = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: revisionID, policyDigest: ""),
            readyRevisionID: revisionID,
            runs: [try succeededRun(
                itemID: itemID, revisionID: revisionID,
                stamp: (appVersion: "0.7.0 (12, abc1234567)",
                        engineVersion: PodcastPreparationPipeline.semanticVersion,
                        codeRevision: nil),
                policyDigest: "")],
            labelledDigestInForce: other))
        XCTAssertNil(empty.earlierAdFindingSetting)

        let local = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: revisionID, policyDigest: recorded),
            readyRevisionID: revisionID,
            runs: [run],
            labelledDigestInForce: nil))
        XCTAssertNil(local.earlierAdFindingSetting)

        let olderEngine = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: makeOutcome(itemID: itemID, revisionID: revisionID, policyDigest: recorded),
            readyRevisionID: revisionID,
            runs: [try succeededRun(
                itemID: itemID, revisionID: revisionID,
                stamp: (appVersion: "0.7.0 (12, abc1234567)",
                        engineVersion: "podcast-preparation-v11",
                        codeRevision: nil),
                policyDigest: recorded)],
            labelledDigestInForce: other))
        XCTAssertNil(olderEngine.earlierAdFindingSetting,
                     "engine-only staleness must not show the earlier-setting line")
    }

    func testAdsLeftInAppearsOnlyWhenPreparedRunHasLabelStop() throws {
        let itemID = try makeItemID()
        let revisionID = try makeRevisionID("c")
        let outcome = makeOutcome(itemID: itemID, revisionID: revisionID)
        let sentence = "The provider did not answer in time."
        let withStop = try succeededRun(
            itemID: itemID, revisionID: revisionID,
            stamp: (appVersion: "0.7.0 (12, abc1234567)", engineVersion: "podcast-preparation-v8",
                    codeRevision: nil),
            labelStopDetail: sentence)
        let stamp = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: outcome, readyRevisionID: revisionID, runs: [withStop]))
        XCTAssertEqual(stamp.adsLeftIn, "Ads left in: \(sentence)")
        XCTAssertTrue(try XCTUnwrap(stamp.displayText).contains("Ads left in: \(sentence)"))

        let withoutStop = try succeededRun(
            itemID: itemID, revisionID: revisionID,
            stamp: (appVersion: "0.7.0 (12, abc1234567)", engineVersion: "podcast-preparation-v8",
                    codeRevision: nil))
        let plain = try XCTUnwrap(WiltedMacPreparationStamp.make(
            outcome: outcome, readyRevisionID: revisionID, runs: [withoutStop]))
        XCTAssertNil(plain.adsLeftIn)
    }

    // MARK: Episode info

    func testEpisodeInfoCarriesTheEpisodesStamp() throws {
        let itemID = try makeItemID()
        let stamp = WiltedMacPreparationStamp(
            prepared: "Prepared by Wilted 0.7.0 (12, abc1234567) · ad engine v8",
            lastFailure: nil, failureDetail: nil)
        let episode = WiltedMacEpisode(
            id: itemID.rawValue, title: "Episode", feedTitle: "Show", summary: "Summary",
            artworkURL: nil, releasedAt: when.date, publishedAt: when.date,
            sourceDurationSeconds: 1_200, durationSeconds: 1_200, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"),
            preparationStamp: stamp)

        XCTAssertEqual(WiltedMacEpisodeInfo(episode: episode).preparationStamp, stamp)
    }

    // MARK: Fixtures

    private func makeItemID() throws -> ItemID {
        try ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
    }

    private func makeRevisionID(_ hex: Character) throws -> RevisionID {
        try RevisionID(rawValue: "rev-" + String(repeating: String(hex), count: 64))
    }

    private func makeOutcome(
        itemID: ItemID, revisionID: RevisionID,
        semanticVersion: String = "podcast-preparation-v8",
        eligibility: PodcastPreparationEligibility = .current,
        policyDigest: String = "digest"
    ) -> PodcastPreparationOutcome {
        PodcastPreparationOutcome(
            episodeID: itemID, revisionID: revisionID, policyDigest: policyDigest,
            pipelineFingerprint: "fingerprint", semanticVersion: semanticVersion,
            producedAt: when, eligibility: eligibility)
    }

    private func makeEvidence(_ stamp: BuildStamp, policyDigest: String? = nil) throws -> PreparationEvidence {
        var fields = ["engineVersion": stamp.engineVersion]
        if let appVersion = stamp.appVersion { fields["appVersion"] = appVersion }
        if let codeRevision = stamp.codeRevision { fields["codeRevision"] = codeRevision }
        if let policyDigest { fields["policyDigest"] = policyDigest }
        return try PreparationEvidence(
            kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: fields)
    }

    private func succeededRun(
        itemID: ItemID, revisionID: RevisionID, stamp: BuildStamp?,
        updatedAt: Timestamp? = nil,
        policyDigest: String? = nil,
        labelStopDetail: String? = nil
    ) throws -> PreparationRunSummary {
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue + "|success"
        var entries: [PreparationJournalEntry] = []
        if let stamp {
            entries.append(PreparationJournalEntry(
                id: requestID + "|start", itemID: itemID, requestID: requestID,
                status: try PreparationStatus(
                    stage: .preparing, detail: "Starting", cancellable: true,
                    emittedAt: when, evidence: try makeEvidence(stamp, policyDigest: policyDigest))))
        }
        if let labelStopDetail {
            entries.append(PreparationJournalEntry(
                id: requestID + "|label-stop", itemID: itemID, requestID: requestID,
                status: try PreparationStatus(
                    stage: .assembling, detail: labelStopDetail, cancellable: true,
                    emittedAt: when, step: "ads.label.stop")))
        }
        entries.append(PreparationJournalEntry(
            id: requestID + "|terminal", itemID: itemID, requestID: requestID,
            status: try PreparationStatus(
                stage: .completed, detail: "Prepared.", cancellable: false,
                terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: revisionID),
                emittedAt: when)))
        return PreparationRunSummary(
            requestID: requestID, itemID: itemID, startedAt: when, updatedAt: updatedAt ?? when,
            stage: .completed, detail: "Prepared.", fraction: nil, isTerminal: true,
            outcome: .succeeded, failure: nil, entries: entries)
    }

    private func failedRun(
        itemID: ItemID, message: String, stamp: BuildStamp?,
        updatedAt: Timestamp? = nil
    ) throws -> PreparationRunSummary {
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue + "|failure"
        let failure = try ProducerError(code: .failed, message: message, retryable: true)
        var entries: [PreparationJournalEntry] = []
        if let stamp {
            entries.append(PreparationJournalEntry(
                id: requestID + "|start", itemID: itemID, requestID: requestID,
                status: try PreparationStatus(
                    stage: .preparing, detail: "Starting", cancellable: true,
                    emittedAt: when, evidence: try makeEvidence(stamp))))
        }
        entries.append(PreparationJournalEntry(
            id: requestID + "|terminal", itemID: itemID, requestID: requestID,
            status: try PreparationStatus(
                stage: .failed, detail: message, cancellable: false,
                terminalResult: PreparationTerminalResult(outcome: .failed, error: failure),
                emittedAt: updatedAt ?? when)))
        return PreparationRunSummary(
            requestID: requestID, itemID: itemID, startedAt: when, updatedAt: updatedAt ?? when,
            stage: .failed, detail: message, fraction: nil, isTerminal: true,
            outcome: .failed, failure: failure, entries: entries)
    }
}
