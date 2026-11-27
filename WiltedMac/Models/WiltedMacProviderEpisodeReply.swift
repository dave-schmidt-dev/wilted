import Foundation
import WiltedProducer

/// The latest actual ad-labeller result recorded for one provider.
struct WiltedMacProviderEpisodeReply: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case reply(breakCount: Int, rejectedCount: Int)
        case failure(String)
    }

    let provider: AdLabellerProvider
    let modelID: String
    let level: String?
    let keyGeneration: Int?
    let occurredAt: Date
    let outcome: Outcome

    init(
        provider: AdLabellerProvider,
        modelID: String,
        level: String? = nil,
        keyGeneration: Int? = nil,
        occurredAt: Date,
        outcome: Outcome
    ) {
        self.provider = provider
        self.modelID = modelID
        self.level = level
        self.keyGeneration = keyGeneration
        self.occurredAt = occurredAt
        self.outcome = outcome
    }

    var detail: String {
        let result: String
        switch outcome {
        case let .reply(breakCount, rejectedCount):
            let breaks: String
            if breakCount == 0 && rejectedCount > 0 {
                breaks = "No usable ad breaks"
            } else if breakCount == 0 {
                breaks = "No ad breaks found"
            } else if breakCount == 1 {
                breaks = "Found 1 ad break"
            } else {
                breaks = "Found \(breakCount) ad breaks"
            }
            if rejectedCount == 0 {
                result = "\(breaks)."
            } else {
                let labels = rejectedCount == 1 ? "1 label" : "\(rejectedCount) labels"
                result = "\(breaks). \(labels) could not be used."
            }
        case .failure(let message):
            result = message
        }
        return "\(result) · \(modelID) · \(occurredAt.formatted(date: .numeric, time: .shortened))"
    }

    var readinessEvidence: WiltedMacProviderEpisodeEvidence? {
        guard let level else { return nil }
        let succeeded: Bool
        if case .reply = outcome {
            succeeded = true
        } else {
            succeeded = false
        }
        return WiltedMacProviderEpisodeEvidence(
            modelID: modelID,
            level: level,
            keyGeneration: keyGeneration,
            occurredAt: occurredAt,
            succeeded: succeeded
        )
    }

    /// Reads only actual episode requests and their recorded reply or failure.
    /// Manual provider checks have a different journal purpose and stay separate.
    static func latestByProvider(in runs: [PreparationRunSummary]) -> [AdLabellerProvider: Self] {
        var latest: [AdLabellerProvider: Self] = [:]
        for run in runs {
            var request: (provider: AdLabellerProvider, modelID: String, level: String?, keyGeneration: Int?)?
            for entry in run.entries {
                guard let evidence = entry.status.evidence else { continue }
                if evidence.kind == "labeller-request" {
                    guard let providerID = evidence.fields["provider"],
                          let provider = AdLabellerProvider(rawValue: providerID),
                          let modelID = evidence.fields["modelID"] else {
                        request = nil
                        continue
                    }
                    request = (
                        provider,
                        modelID,
                        evidence.fields["level"],
                        evidence.fields["keyGeneration"].flatMap(Int.init)
                    )
                    continue
                }
                guard let request else { continue }
                let outcome: Outcome?
                switch evidence.kind {
                case "labeller-result":
                    guard let breaks = evidence.fields["breaks"].flatMap(Int.init), breaks >= 0,
                          let rejected = evidence.fields["rejected"].flatMap(Int.init), rejected >= 0 else {
                        continue
                    }
                    outcome = .reply(breakCount: breaks, rejectedCount: rejected)
                case "labeller-wait":
                    outcome = evidence.fields["failureKind"].flatMap(Self.failureMessage)
                case "labeller-stop":
                    outcome = evidence.fields["kind"].flatMap(Self.failureMessage)
                default:
                    continue
                }
                guard let outcome else { continue }
                let candidate = Self(
                    provider: request.provider,
                    modelID: request.modelID,
                    level: request.level,
                    keyGeneration: request.keyGeneration,
                    occurredAt: entry.status.emittedAt.date,
                    outcome: outcome
                )
                if let previous = latest[request.provider], previous.occurredAt > candidate.occurredAt {
                    continue
                }
                latest[request.provider] = candidate
            }
        }
        return latest
    }

    private static func failureMessage(_ kind: String) -> Outcome? {
        switch kind {
        case "temporary": .failure("Service unavailable")
        case "rate-limited": .failure("Too many requests")
        case "usage-limit": .failure("Provider usage limit")
        case "key-rejected": .failure("Key rejected")
        case "model-unavailable": .failure("Model unavailable")
        case "unusable-answer": .failure("No usable response")
        case "command-line-tool-unavailable": .failure("Command-line tool unavailable")
        case "wait-limit": .failure("Provider did not answer in time")
        case "provider-paused": .failure("Provider paused")
        default: nil
        }
    }
}
