import Foundation
import WiltedDomain

extension PodcastPreparationPipeline {
    /// The worker request for one source file, serialized.
    func workerRequest(
        episode: PodcastEpisode, audioURL: URL, preparedURL: URL, sourceHash: String,
        policy: PodcastPreparationPolicySnapshot,
        profileSnapshot: PodcastAdProfileSnapshot?,
        emitLabellerCues: Bool = false,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        var request: [String: Any] = [
            "protocolVersion": 2,
            "feedID": episode.feedID.rawValue,
            "episodeID": episode.itemID.rawValue,
            "audioPath": audioURL.path,
            "outputPath": preparedURL.path,
            "workDir": workDirectory.path,
            "transcriptPolicy": policy.transcriptPolicy.rawValue,
            "removeAds": policy.removeAds,
            "allowSpeechToText": policy.transcriptPolicy != .noLocalSTT,
            "sourceHash": sourceHash,
            "alignedTranscriptModel": Self.alignedTranscriptModel,
        ]
        if let envelope = profileSnapshot?.envelope,
           envelope.validatedPayload(expectedFeedID: episode.feedID.rawValue) != nil {
            request["adProfile"] = ["payload": envelope.payload, "digest": envelope.digest]
        }
        // The worker echoes this back into the result it stores. Sending
        // the sentinel would persist it one layer further out.
        if let fingerprint = Self.semanticFingerprintResolution {
            request["pipelineFingerprint"] = fingerprint
        }
        // Sent only when on, so every other feed's request is unchanged.
        if policy.removeSelfPromotion { request["removeSelfPromotion"] = true }
        if emitLabellerCues { request["emitLabellerCues"] = true }
        if !policy.removeAds, policy.transcriptPolicy != .alwaysTranscribe,
           let published = await fetchPublishedTranscript(for: episode, onStatus: onStatus) {
            request["publishedTranscript"] = published
        }
        // The feed's show notes name the hosts, guests, stories, products,
        // and sponsors: the worker's glossary for the words speech-to-text
        // got wrong.
        if let notes = episode.notes {
            request["episodeNotes"] = notes
        }
        request["episodeTitle"] = episode.title
        return try JSONSerialization.data(withJSONObject: request)
    }


    func captureAdProfileSnapshot(
        for feedID: ItemID,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async -> PodcastAdProfileSnapshot? {
        do {
            return try await store.adPlacementProfileSnapshot(for: feedID)
        } catch {
            onStatus(PodcastPreparationProgress(stage: "ad-profile.snapshot-unavailable",
                                                detail: "Feed placement profile unavailable; using generic analysis"))
            return nil
        }
    }

    func validateAdProfileHandshake(_ payload: inout WorkerPayload, snapshot: PodcastAdProfileSnapshot?) {
        let expectedDigest = snapshot?.envelope?.digest
        let echoedDigest = payload.adProfileRequestedDigest
        // Provenance names the frozen request, even when the worker's echo is absent or wrong.
        payload.adProfileRequestedDigest = expectedDigest
        if let expectedDigest {
            guard echoedDigest == expectedDigest else {
                payload.adProfileStatus = "invalid"
                payload.adProfileAppliedDigest = nil
                return
            }
            switch payload.adProfileStatus {
            case "applied" where payload.adProfileAppliedDigest == expectedDigest:
                break
            case "absent", "invalid" where payload.adProfileAppliedDigest == nil:
                break
            default:
                payload.adProfileStatus = "invalid"
                payload.adProfileAppliedDigest = nil
            }
        } else if payload.adProfileStatus == "applied" || echoedDigest != nil
                    || payload.adProfileAppliedDigest != nil {
            payload.adProfileStatus = "invalid"
            payload.adProfileAppliedDigest = nil
        }
    }

    func adProfileRequestProgress(_ snapshot: PodcastAdProfileSnapshot?, enabled: Bool) -> PodcastPreparationProgress {
        var fields = ["status": enabled ? (snapshot?.envelope == nil ? "absent" : "not-observed") : "not-requested"]
        if let digest = snapshot?.envelope?.digest { fields["requestedDigest"] = digest }
        let detail = enabled ? (snapshot?.envelope == nil
            ? "No feed placement profile supplied" : "Feed placement profile supplied")
            : "Ad removal is disabled for this attempt"
        return PodcastPreparationProgress(stage: "ad-profile.requested", detail: detail,
            evidence: try? PreparationEvidence(kind: "ad-profile-request", fields: fields))
    }

    func adProfileResultProgress(_ payload: WorkerPayload) -> PodcastPreparationProgress {
        var fields = ["status": payload.adProfileStatus]
        if let digest = payload.adProfileRequestedDigest { fields["requestedDigest"] = digest }
        if let digest = payload.adProfileAppliedDigest { fields["appliedDigest"] = digest }
        return PodcastPreparationProgress(stage: "ad-profile.result", detail: "Feed placement profile result recorded",
            evidence: try? PreparationEvidence(kind: "ad-profile-result", fields: fields))
    }

    func persistAdProfileObservation(
        _ observation: PodcastAdProfileObservation?, feedID: ItemID, episodeID: ItemID,
        sourceHash: String, snapshot: PodcastAdProfileSnapshot?,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async {
        guard !Task.isCancelled, let observation, let snapshot,
              sourceHash.hasPrefix("sha256:"),
              observation.isValid(feedID: feedID.rawValue, episodeID: episodeID.rawValue,
                                  sourceHash: String(sourceHash.dropFirst("sha256:".count))) else { return }
        do {
            let added = try await store.recordAdPlacementObservation(observation,
                expectedSubscriptionEpoch: snapshot.subscriptionEpoch)
            if added {
                onStatus(PodcastPreparationProgress(stage: "ad-profile.observation-saved",
                                                    detail: "Independent feed placement evidence saved"))
            }
        } catch {
            onStatus(PodcastPreparationProgress(stage: "ad-profile.observation-unavailable",
                                                detail: "Feed placement evidence could not be saved"))
        }
    }

    static func decodeAdProfileResult(from object: [String: Any]) -> (
        observation: PodcastAdProfileObservation?, status: String,
        requestedDigest: String?, appliedDigest: String?
    ) {
        func digest(_ key: String) -> String? {
            guard let value = object[key] as? String,
                  value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { return nil }
            return value
        }
        let requested = digest("adProfileRequestedDigest")
        let applied = digest("adProfileAppliedDigest")
        let rawStatus = object["adProfileStatus"] as? String ?? "absent"
        guard ["absent", "invalid", "applied"].contains(rawStatus) else {
            return (nil, "invalid", requested, nil)
        }
        if rawStatus == "applied" {
            guard let requested, requested == applied else { return (nil, "invalid", requested, nil) }
        } else if applied != nil {
            return (nil, "invalid", requested, nil)
        }
        guard let raw = object["adProfileObservation"], !(raw is NSNull) else {
            return (nil, rawStatus, requested, applied)
        }
        guard let value = raw as? [String: Any],
              Set(value.keys) == Set(["schemaVersion", "feedID", "episodeID", "sourceHash", "slots"]),
              PodcastAdProfileValidation.jsonInteger(value["schemaVersion"]) == 1,
              let feedID = value["feedID"] as? String, (1...256).contains(feedID.unicodeScalars.count),
              let episodeID = value["episodeID"] as? String, (1...256).contains(episodeID.unicodeScalars.count),
              let sourceHash = value["sourceHash"] as? String,
              sourceHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let slots = value["slots"] as? [[String: Any]],
              slots.count <= PodcastAdProfileValidation.maximumSlots,
              slots.allSatisfy(PodcastAdProfileValidation.validSlotObject),
              let encoded = try? JSONSerialization.data(withJSONObject: value),
              let observation = try? JSONDecoder().decode(PodcastAdProfileObservation.self, from: encoded),
              observation.isValid(feedID: feedID, episodeID: episodeID, sourceHash: sourceHash) else {
            return (nil, "invalid", requested, nil)
        }
        return (observation, rawStatus, requested, applied)
    }


}
