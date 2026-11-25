import Foundation
import WiltedDomain

extension PodcastPreparationPipeline {
    /// The worker request fields for one source file.
    func workerRequestFields(
        episode: PodcastEpisode, audioURL: URL, preparedURL: URL, sourceHash: String,
        policy: PodcastPreparationPolicySnapshot,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> [String: Any] {
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
        // The worker echoes this back into the result it stores. Sending
        // the sentinel would persist it one layer further out.
        if let fingerprint = Self.semanticFingerprintResolution {
            request["pipelineFingerprint"] = fingerprint
        }
        // Sent only when on, so every other feed's request is unchanged.
        if policy.removeSelfPromotion { request["removeSelfPromotion"] = true }
        if policy.evenOutVoiceLoudness { request["evenOutVoiceLoudness"] = true }
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
        return request
    }

    /// The worker request for one source file, serialized.
    func workerRequest(
        episode: PodcastEpisode, audioURL: URL, preparedURL: URL, sourceHash: String,
        policy: PodcastPreparationPolicySnapshot,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> Data {
        try JSONSerialization.data(withJSONObject: try await workerRequestFields(
            episode: episode, audioURL: audioURL, preparedURL: preparedURL, sourceHash: sourceHash,
            policy: policy,
            onStatus: onStatus))
    }
}
