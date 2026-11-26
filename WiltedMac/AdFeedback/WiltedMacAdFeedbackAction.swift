import CryptoKit
import Foundation
import WiltedLibrary

/// A request written by the local tuning tool and consumed only by the Mac app.
struct WiltedMacAdFeedbackActionEnvelope: Codable, Sendable {
    let actionID: String
    let payloadSHA256: String
    let payload: Data

    var computedPayloadSHA256: String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

/// The request's exact link from a report to the case and replay that cleared it.
struct WiltedMacAdFeedbackActionPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let candidateCommit: String
    let candidateBranch: String
    let intakeSnapshotSHA256: String
    let replayReportSHA256: String
    let entries: [Entry]

    struct Entry: Codable, Equatable, Sendable {
        let identity: Identity
        let caseID: String
        let sourceHash: String
        let replay: Replay
    }

    struct Identity: Codable, Equatable, Sendable {
        let id: String
        let kind: AdFeedbackKind
        let itemID: String
        let revisionID: String
        let playedSeconds: Double
        let originalSeconds: Double?
        let mapping: WiltedMacAdFeedbackEntry.Mapping
        let nearestCut: WiltedMacAdFeedbackEntry.NearestCut?
        let engineVersion: String?
        let pipelineFingerprint: String?
        let createdAt: Date
        let deviceID: String
        let source: WiltedMacAdFeedbackEntry.Source
        let showTitle: String?
        let episodeTitle: String?
        let review: WiltedMacAdFeedbackEntry.Review
        let label: WiltedMacAdFeedbackEntry.CorpusLabel?
        let reviewedAt: Date?

        init(_ entry: WiltedMacAdFeedbackEntry) {
            id = entry.id
            kind = entry.kind
            itemID = entry.itemID
            revisionID = entry.revisionID
            playedSeconds = entry.playedSeconds
            originalSeconds = entry.originalSeconds
            mapping = entry.mapping
            nearestCut = entry.nearestCut
            engineVersion = entry.engineVersion
            pipelineFingerprint = entry.pipelineFingerprint
            createdAt = entry.createdAt
            deviceID = entry.deviceID
            source = entry.source
            showTitle = entry.showTitle
            episodeTitle = entry.episodeTitle
            review = entry.review
            label = entry.label
            reviewedAt = entry.reviewedAt
        }

        func matches(_ entry: WiltedMacAdFeedbackEntry) -> Bool { self == Identity(entry) }
    }

    struct Replay: Codable, Equatable, Sendable {
        let candidateCommit: String
        let reportSHA256: String
        let fixtureID: String
        let replayCommand: String
        let passed: Bool
        let clean: Bool
        let skipped: Bool
        let coverageComplete: Bool
        let localEvidence: LocalEvidence

        var isClean: Bool { passed && clean && !skipped && coverageComplete }

        struct LocalEvidence: Codable, Equatable, Sendable {
            let label: String
            let startSeconds: Double
            let endSeconds: Double
            let reportedPositionSeconds: Double
            let localVerdictPassed: Bool
            let reportedPositionWasCut: Bool
            let nearestCutFullyCut: Bool?
            let nearestCutAnyCut: Bool?
        }
    }
}

/// The durable receipt that makes a queued action safe to replay after a crash.
struct WiltedMacAdFeedbackActionReceipt: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case applied
        case alreadyHandled
        case rejectedStale
    }

    let actionID: String
    let payloadSHA256: String
    let candidateCommit: String
    let replayReportSHA256: String
    let outcome: Outcome
    let links: [EvidenceLink]
    let reason: String?
    let processedAt: Date

    struct EvidenceLink: Codable, Equatable, Sendable {
        let feedbackID: String
        let itemID: String
        let revisionID: String
        let caseID: String
        let sourceHash: String
        let fixtureID: String
        let replayCommand: String
        let reviewedLabel: String
        let reviewedStartSeconds: Double
        let reviewedEndSeconds: Double
        let reportedPositionSeconds: Double
        let localVerdictPassed: Bool
        let reportedPositionWasCut: Bool
        let nearestCutFullyCut: Bool?
        let nearestCutAnyCut: Bool?
    }
}

struct WiltedMacAdFeedbackActionProcessingResult: Sendable {
    let receipts: [WiltedMacAdFeedbackActionReceipt]
    let failure: String?
}

enum WiltedMacAdFeedbackActionValidationError: Error, LocalizedError {
    case invalidEnvelope
    case invalidPayload
    case conflictingReplay

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope: "The queued ad-feedback action was invalid."
        case .invalidPayload: "The queued ad-feedback action did not include a clean exact-case replay."
        case .conflictingReplay: "The queued action ID was reused with different evidence."
        }
    }
}
