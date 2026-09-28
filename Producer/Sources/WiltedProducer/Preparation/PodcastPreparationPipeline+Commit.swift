import CryptoKit
import Foundation
import WiltedDomain

extension PodcastPreparationPipeline {
    // MARK: Commit

    func commit(
        _ payload: WorkerPayload,
        episode: PodcastEpisode,
        download: PodcastDownload,
        downloadedRevision: AudioRevision,
        audioURL: URL,
        policy: PodcastPreparationPolicySnapshot,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> PodcastPreparationResult {
        let sourceContribution = LifetimeStatisticContribution(
            id: LifetimeStatisticEventID.podcastAudioProcessed(
                sourceRevisionID: downloadedRevision.revisionID
            ),
            kind: .audioProcessed,
            seconds: downloadedRevision.durationSeconds
        )
        guard payload.audioChanged else {
            let transcript = try Self.transcript(from: payload, itemID: episode.itemID,
                                                 revisionID: downloadedRevision.revisionID,
                                                 updatedAt: Timestamp(now()))
            let outcome = PodcastPreparationOutcome(
                episodeID: episode.itemID, revisionID: downloadedRevision.revisionID,
                policyDigest: Self.policyDigest(policy),
                pipelineFingerprint: Self.semanticFingerprintResolution,
                semanticVersion: Self.semanticVersion, producedAt: Timestamp(now())
            )
            try await store.saveReadyRevision(downloadedRevision, mediaURL: audioURL, transcript: transcript,
                                              outcome: outcome, lifetimeStatistics: [sourceContribution])
            return finish(payload, revision: downloadedRevision, mediaURL: audioURL,
                          transcript: transcript, onStatus: onStatus)
        }

        onStatus(PodcastPreparationProgress(stage: "audio.publish", detail: "storing prepared audio"))
        let preparedURL = URL(fileURLWithPath: payload.audioPath)
        guard FileManager.default.fileExists(atPath: preparedURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: preparedURL.path),
              let byteCount = attributes[.size] as? Int64, byteCount > 0 else {
            throw PodcastPreparationError.preparedAudioUnreadable
        }
        let hash = try Self.contentHash(of: preparedURL)
        let revisionID = try await store.resolvePodcastRevision(
            itemID: episode.itemID,
            contentHash: hash
        )
        // Prefer what the worker measured on the cut file; fall back to
        // subtraction only when the probe could not run.
        let duration = payload.durationSeconds
            ?? max(0.001, downloadedRevision.durationSeconds - payload.removedSeconds)
        let finalURL = try await store.readyRevision(for: episode.itemID, revisionID: revisionID)?.mediaURL
            ?? audioURL.deletingLastPathComponent()
                .appendingPathComponent(revisionID.rawValue + "." + audioURL.pathExtension)
        if finalURL != preparedURL {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                guard try Self.contentHash(of: finalURL) == hash else {
                    throw PodcastPreparationError.preparedAudioUnreadable
                }
                try FileManager.default.removeItem(at: preparedURL)
            } else {
                try FileManager.default.moveItem(at: preparedURL, to: finalURL)
            }
        }
        let revision = try AudioRevision(itemID: episode.itemID, revisionID: revisionID,
                                         durationSeconds: duration, byteCount: byteCount,
                                         contentHash: hash, mediaType: downloadedRevision.mediaType,
                                         createdAt: Timestamp(now()), schemaVersion: 3)
        let prepared = try PodcastDownload(episodeID: episode.itemID, status: .completed,
                                           bytesReceived: byteCount, expectedByteCount: byteCount,
                                           localURL: finalURL, contentHash: hash,
                                           updatedAt: Timestamp(now()))
        let transcript = try Self.transcript(from: payload, itemID: episode.itemID, revisionID: revisionID,
                                             updatedAt: Timestamp(now()))
        let carried = try await carriedPlayback(from: downloadedRevision, to: revision,
                                                keeps: payload.keepIntervals, duration: duration)
        let outcome = PodcastPreparationOutcome(
            episodeID: episode.itemID, revisionID: revisionID,
            policyDigest: Self.policyDigest(policy),
            pipelineFingerprint: Self.semanticFingerprintResolution,
            semanticVersion: Self.semanticVersion, producedAt: Timestamp(now())
        )

        var lifetimeStatistics = [sourceContribution]
        if payload.adRemovalOutcome == "cut", payload.audioChanged,
           payload.removedSeconds.isFinite, payload.removedSeconds > 0 {
            lifetimeStatistics.append(LifetimeStatisticContribution(
                id: LifetimeStatisticEventID.podcastAdRemoved(revisionID: revision.revisionID),
                kind: .confirmedAdTimeRemoved,
                seconds: payload.removedSeconds
            ))
        }
        try await store.replaceReadyRevision(
            revision,
            mediaURL: finalURL,
            transcript: transcript,
            download: prepared,
            superseding: downloadedRevision.revisionID,
            outcome: outcome,
            carrying: carried,
            lifetimeStatistics: lifetimeStatistics
        )
        // Only now is the outcome durable, so only now is the original safe to
        // reclaim: a crash before this point leaves it in place for a retry to
        // find again, and a crash after it leaves an idempotent no-op.
        reclaimSupersededPodcastAudio(at: audioURL, keeping: finalURL)
        return finish(payload, revision: revision, mediaURL: finalURL, transcript: transcript, onStatus: onStatus)
    }

    /// Deletes a superseded episode's source audio once its replacement is
    /// durable. Safe to call more than once, and safe to call when the file
    /// was already removed by an earlier, interrupted attempt.
    private func reclaimSupersededPodcastAudio(at audioURL: URL, keeping finalURL: URL) {
        guard audioURL != finalURL, FileManager.default.fileExists(atPath: audioURL.path) else { return }
        try? FileManager.default.removeItem(at: audioURL)
    }

    private static func policyDigest(_ policy: PodcastPreparationPolicySnapshot) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(policy.transcriptPolicy.rawValue.utf8))
        hasher.update(data: Data([0, policy.removeAds ? 1 : 0]))
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Moves a saved listening position onto the prepared audio.
    ///
    /// A position inside a removed advertisement has nowhere to land, so it is
    /// dropped rather than guessed at; anything else keeps its place in the
    /// content the listener was actually hearing.
    private func carriedPlayback(
        from previous: AudioRevision,
        to revision: AudioRevision,
        keeps: [PodcastKeepInterval],
        duration: Double
    ) async throws -> PlaybackState? {
        guard let existing = try await store.playbackState(for: previous.itemID, revisionID: previous.revisionID),
              let mapped = PodcastKeepInterval.map(existing.positionSeconds, through: keeps) else { return nil }
        return try PlaybackState(
            itemID: revision.itemID, revisionID: revision.revisionID, sessionID: existing.sessionID,
            sequence: existing.sequence + 1, positionSeconds: min(mapped, duration),
            durationSeconds: duration, completed: existing.completed, intent: existing.intent,
            deviceID: existing.deviceID, updatedAt: Timestamp(now())
        )
    }

    private func finish(
        _ payload: WorkerPayload,
        revision: AudioRevision,
        mediaURL: URL,
        transcript: Transcript,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) -> PodcastPreparationResult {
        onStatus(PodcastPreparationProgress(
            stage: "pipeline.complete",
            detail: "\(payload.adSegments.count) advertisements, \(payload.cues.count) cues",
            fraction: 1
        ))
        return PodcastPreparationResult(revision: revision, mediaURL: mediaURL, transcript: transcript,
                                        adSegments: payload.adSegments, removedSeconds: payload.removedSeconds,
                                        adRemovalOutcome: payload.adRemovalOutcome)
    }

    static func resultProgress(_ payload: WorkerPayload) -> PodcastPreparationProgress {
        let evidence = try? PreparationEvidence(kind: "worker-result", fields: [
            "audioChanged": payload.audioChanged ? "true" : "false",
            "advertisements": String(payload.adSegments.count),
            "removedSeconds": String(format: "%.3f", payload.removedSeconds),
            "cues": String(payload.cues.count), "timing": payload.timing.rawValue
        ])
        return PodcastPreparationProgress(stage: "pipeline.result",
                                          detail: "audio \(payload.audioChanged ? "changed" : "unchanged") · \(payload.adSegments.count) ads · \(payload.cues.count) cues",
                                          evidence: evidence)
    }

    static func adProgress(_ ad: PodcastAdSegment, ordinal: Int) -> PodcastPreparationProgress {
        func clock(_ seconds: Double) -> String {
            // The worker result is external input. Do not trap while trying to
            // narrate a malformed timestamp in its durable audit record.
            guard seconds.isFinite, seconds >= 0, seconds <= 7 * 24 * 60 * 60 else { return "unknown" }
            let total = Int(seconds.rounded())
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        // Worker labels are external input. Keep the evidence valid and the
        // user-facing detail useful when a malformed label is unexpectedly long.
        let label: String
        if ad.label.isEmpty {
            label = "unknown label"
        } else if ad.label.count > 256 {
            label = String(ad.label.prefix(253)) + "..."
        } else {
            label = ad.label
        }
        let evidence = try? PreparationEvidence(kind: "advertisement", fields: [
            "ordinal": String(ordinal), "startSeconds": String(format: "%.3f", ad.startSeconds),
            "endSeconds": String(format: "%.3f", ad.endSeconds), "label": label,
            "confidence": String(format: "%.4f", ad.confidence), "removalKind": ad.kind
        ])
        let confidence: String
        if ad.confidence.isFinite, (0...1).contains(ad.confidence) {
            confidence = "\(Int((ad.confidence * 100).rounded()))%"
        } else {
            confidence = "unknown confidence"
        }
        return PodcastPreparationProgress(stage: "ads.detect.span.\(ordinal)",
                                          detail: "\(clock(ad.startSeconds))–\(clock(ad.endSeconds)) · \(label) · \(confidence)",
                                          evidence: evidence)
    }

    /// Builds the durable transcript, degrading rather than failing.
    ///
    /// An episode whose transcript is too large to carry is still a prepared
    /// episode with its advertisements removed; recording `oversized` says so
    /// truthfully, where throwing would discard the audio work as well.
    static func transcript(
        from payload: WorkerPayload,
        itemID: ItemID,
        revisionID: RevisionID,
        updatedAt: Timestamp
    ) throws -> Transcript {
        func unavailable(_ availability: TranscriptAvailability) throws -> Transcript {
            try Transcript(itemID: itemID, revisionID: revisionID, availability: availability,
                           languageCode: payload.languageCode, updatedAt: updatedAt)
        }
        guard let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return try unavailable(.absent)
        }
        guard text.utf8.count <= Transcript.maximumTextUTF8Bytes else { return try unavailable(.oversized) }
        let cues = payload.cues.isEmpty ? nil : payload.cues
        do {
            return try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                  text: text, languageCode: payload.languageCode,
                                  timing: cues == nil ? .none : payload.timing, cues: cues,
                                  updatedAt: updatedAt)
        } catch {
            // The text fits and the cues do not. Keeping the words and dropping
            // the timing is strictly better than keeping neither.
            return try Transcript(itemID: itemID, revisionID: revisionID, availability: .available,
                                  text: text, languageCode: payload.languageCode, updatedAt: updatedAt)
        }
    }

    func preparedAudioURL(for audioURL: URL) -> URL {
        workDirectory.appendingPathComponent("prepared-" + audioURL.lastPathComponent)
    }

    private static func contentHash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
