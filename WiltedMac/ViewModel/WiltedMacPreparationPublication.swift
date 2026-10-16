import Foundation
import ObjectiveC
import WiltedDomain
import WiltedLibrary
#if canImport(WiltedProducer)
import WiltedProducer

/// Curated display text only. Journal errors, paths and worker logs never cross this boundary.
enum WiltedMacPreparationPublication {
    struct Request: Equatable, Sendable {
        var operationID: UUID = UUID()
        var requestSequence: Int?
        var withdrawn: Bool = false
        var acknowledged: Bool = false
        var needsReconciliation: Bool = false
        var attempt: PreparationAttemptIdentity? = nil

        func acknowledging(_ ticket: WorkTicket, operationID: UUID) -> Self {
            guard self.operationID == operationID, requestSequence == ticket.requestSequence else { return self }
            var value = self
            value.acknowledged = true
            value.needsReconciliation = false
            value.attempt = try? PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
            return value
        }
    }

    private static let supportedSteps: Set<String> = [
        "pipeline.start", "pipeline.result", "pipeline.complete", "audio.publish",
        "transcript.published.fetch", "transcript.published.parse", "transcript.published.accepted",
        "transcript.published.aligned", "transcript.published.unverified", "transcript.published.unreadable",
        "transcript.published.unreachable", "transcript.published.unparseable", "transcript.published.misaligned",
        "transcript.stt.start", "transcript.stt.complete", "transcript.stt.failed", "transcript.absent", "transcript.remap",
        "transcript.glossary.terms", "transcript.glossary.progress", "transcript.glossary.complete",
        "ads.model.load", "ads.detect.start", "ads.detect.calls", "ads.detect.complete",
        "ads.cut.start", "ads.cut.complete", "ads.cut.refused", "ads.cut.empty"
    ]

    static func status(_ value: LocalLibraryStore.CurrentPreparationStatus) -> LibraryPreparationStatus? {
        let state: LibraryPreparationStatus.State
        switch value.state {
        case .pending, .deferred: state = .queued
        case .running:
            guard value.attemptCount > 0 else { return nil }
            switch value.status?.terminalResult?.outcome {
            case .failed: state = .failed
            case .cancelled: state = .cancelled
            case .succeeded: state = .active
            case nil: state = .active
            }
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        case .succeeded:
            switch value.status?.terminalResult?.outcome {
            case .failed: state = .failed
            case .cancelled: state = .cancelled
            default: state = .active
            }
        }
        let awaitingProof = state == .active
            && (value.state == .succeeded || value.status?.terminalResult?.outcome == .succeeded)
        let stage = awaitingProof ? PreparationStage.saving : (value.status?.stage ?? .preparing)
        let reportedStep = value.status?.step.flatMap { supportedSteps.contains($0) ? $0 : nil }
        var detail: String
        switch state {
        case .queued: detail = "Waiting to prepare."
        case .failed: detail = "Preparation failed. Retry from the Mac."
        case .cancelled: detail = "Preparation cancelled."
        case .active:
            detail = switch stage {
            case .fetching: "Fetching episode audio."
            case .extracting: "Transcribing and checking the episode."
            case .synthesizing: "Preparing speech."
            case .assembling: "Assembling prepared audio."
            case .saving: "Saving prepared audio."
            default: "Preparing episode."
            }
        }
        if state == .active, !awaitingProof, let status = value.status, let step = reportedStep {
            detail = WiltedMacModel.preparationLabel(for: PodcastPreparationProgress(stage: step))
            if step == "transcript.glossary.progress",
               status.detail.range(of: #"^[0-9]{1,6} of [0-9]{1,6} cues\z"#, options: .regularExpression) != nil {
                detail += " " + status.detail + "."
            } else if step == "ads.detect.calls",
                      status.detail.range(of: #"^[0-9]{1,6} requests, [0-9]{1,6} failed\z"#, options: .regularExpression) != nil {
                detail += " " + status.detail + "."
            } else if status.evidence?.kind == "worker-result",
                      let ads = status.evidence?.fields["advertisements"].flatMap(Int.init),
                      let cues = status.evidence?.fields["cues"].flatMap(Int.init),
                      (0...999_999).contains(ads), (0...999_999).contains(cues) {
                detail = "Found \(ads) advertisements and \(cues) transcript cues."
            }
        }
        if awaitingProof { detail = "Prepared output is not yet confirmed." }
        return try? LibraryPreparationStatus(
            attemptID: "generation-\(value.requestSequence)-\(value.attemptCount)",
            state: state, stage: awaitingProof ? stage.rawValue : (reportedStep ?? stage.rawValue), detail: detail,
            fraction: state == .active && !awaitingProof ? value.status?.fraction : nil, updatedAt: value.updatedAt.date
        )
    }
}

private nonisolated(unsafe) var preparationPublicationKey: UInt8 = 0
extension WiltedMacModel {
    var preparationPublicationRequests: [String: WiltedMacPreparationPublication.Request] {
        get { objc_getAssociatedObject(self, &preparationPublicationKey) as? [String: WiltedMacPreparationPublication.Request] ?? [:] }
        set { objc_setAssociatedObject(self, &preparationPublicationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
#endif
