import Foundation
import WiltedDomain

/// Why preparing a cut episode again was declined, and left the cut as it was.
public enum PodcastPrepareAgainRefusal: Equatable, Sendable {
    /// The listener has a place in the cut, and the original the publisher
    /// serves now is not the one that cut was made from, so the old cut's
    /// timeline cannot say where that place is in it.
    case publisherFileChanged
    /// The listener has a place in the cut, and nothing records what the cut
    /// removed, so the place cannot be walked back to the original.
    case noRecordOfRemovals

    /// Plain words for the row: it names the cause and not the mechanism.
    public var message: String {
        switch self {
        case .publisherFileChanged: "The publisher's file changed, so your place could not be carried"
        case .noRecordOfRemovals: "This episode's old cut has no record of what was removed"
        }
    }
}

/// What one prepare-again run ended with.
public enum PodcastPrepareAgainOutcome: Sendable {
    /// The old cut was replaced.
    case prepared(PodcastPreparationResult)
    /// The current engine could not tell advertising from programme, so the old
    /// cut stays: it is the better of the two files.
    case keptExisting(String)
    /// Declined before replacing anything. See `PodcastPrepareAgainRefusal`.
    case refused(PodcastPrepareAgainRefusal)
}

/// Thrown inside a run when a refusal is only discovered at commit.
private struct PrepareAgainRefused: Error { let reason: PodcastPrepareAgainRefusal }

extension PodcastPreparationPipeline {
    /// Prepares a cut episode again from its original, with the current engine.
    ///
    /// A cut cannot be fed back to the pipeline: ads are found in the original's
    /// transcript, and the original was reclaimed when the cut replaced it. So
    /// the original is fetched into a staging file by `stage`, and the old cut
    /// stays the ready revision, and playable, until a successor commits. Any
    /// failure, cancel, refusal or kept result leaves the library as it was;
    /// the staged file is deleted on every path out.
    ///
    /// The listener's place is the one thing that cannot be recovered by
    /// running again, so it gates the run. With no saved place (or one at the
    /// start) the run proceeds whatever the bytes are. With one, it proceeds
    /// only when the old cut's timeline is on record and the original just
    /// fetched hashes to the one that timeline was made from: then the place
    /// walks back to the original exactly, and forward onto the new cut. A run
    /// that is declined is still recorded as an attempt of the current engine,
    /// because running again would be refused the same way.
    ///
    /// Staging that fails is journalled without engine evidence, so it does
    /// not count as a try: nothing was decided, and the episode stays offered.
    /// `mayReplace` is asked just before the swap; false ends the run as
    /// cancelled (the Mac says no while the cut is loaded in its player).
    public func prepareAgain(
        candidate: PodcastPrepareAgainCandidate,
        stage: @escaping @Sendable () async throws -> StagedPodcastAudio,
        policy: PodcastPreparationPolicySnapshot? = nil,
        attempt: PreparationAttemptIdentity? = nil,
        mayReplace: @escaping @Sendable () async -> Bool = { true },
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void = { _ in },
        onJournaled: @escaping @Sendable () async -> Void = {}
    ) async throws -> PodcastPrepareAgainOutcome {
        let policy = policy ?? defaultPolicy
        let episodeID = candidate.episodeID
        let requestID = Self.requestID(for: episodeID)
        // The same one-attempt-deep rule as `prepare`.
        if attempt == nil { try? await store.clearPreparationJournal(for: requestID) }
        let writes = JournalWrites()
        let report = reporter(writes: writes, episodeID: episodeID, requestID: requestID, attempt: attempt,
                              onStatus: onStatus, onJournaled: onJournaled)
        let fingerprint = Self.semanticFingerprintResolution

        guard let episode = try await store.podcastEpisode(for: episodeID),
              let old = try await store.readyRevision(for: episodeID),
              old.revision.revisionID == candidate.readyRevision.revision.revisionID,
              FileManager.default.fileExists(atPath: old.mediaURL.path) else {
            await journalTerminal(episodeID: episodeID, requestID: requestID, attempt: attempt,
                                  error: PodcastPreparationError.readyAudioChanged, revisionID: nil)
            await onJournaled()
            throw PodcastPreparationError.readyAudioChanged
        }
        let codeRevision = await runner.codeRevision()

        /// Records a run that changed nothing: one provenance row naming the
        /// engine (so it counts as tried), a marker row saying nothing changed,
        /// and a success naming the ready revision.
        func recordUnchanged(_ summary: String, provenanceOf source: AudioRevision) async {
            report(PodcastPreparationProgress(
                stage: "pipeline.start", detail: episode.title,
                evidence: provenanceEvidence(sourceRevisionID: source.revisionID, sourceHash: source.contentHash,
                                             codeRevision: codeRevision)))
            let marker = try? PreparationEvidence(kind: LocalLibraryStore.keptExistingAudioEvidenceKind,
                                                  fields: ["reason": String(summary.prefix(200))])
            report(PodcastPreparationProgress(stage: "prepare-again.kept", detail: summary, evidence: marker))
            await writes.drain()
            await journalTerminal(episodeID: episodeID, requestID: requestID, attempt: attempt, error: nil,
                                  revisionID: old.revision.revisionID, summary: summary, fingerprint: fingerprint,
                                  sourceRevisionID: source.revisionID, sourceHash: source.contentHash,
                                  sourceURL: candidate.enclosureURL, codeRevision: codeRevision)
            await onJournaled()
        }

        // The saved place, read before the download so a run that cannot carry
        // it is refused without spending the transfer.
        let position = try await store.playbackState(for: episodeID, revisionID: old.revision.revisionID)?
            .positionSeconds ?? 0
        let kept = candidate.keptTimeline.map { $0.kept.map { PodcastKeepInterval($0) } }
        if position > 0, kept == nil || candidate.sourceHash == nil {
            await recordUnchanged(PodcastPrepareAgainRefusal.noRecordOfRemovals.message, provenanceOf: old.revision)
            return .refused(.noRecordOfRemovals)
        }

        let staged: StagedPodcastAudio
        do {
            staged = try await stage()
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
                || (error as? PodcastDownloadCoordinatorError) == .cancelled
            let recorded: any Error = cancelled ? CancellationError() : error
            await writes.drain()
            await journalTerminal(episodeID: episodeID, requestID: requestID, attempt: attempt,
                                  error: recorded, revisionID: nil)
            await onJournaled()
            throw cancelled ? PodcastPreparationError.cancelled : error
        }
        defer { staged.discard(in: store) }

        let exact = kept != nil && candidate.sourceHash == staged.contentHash
        if position > 0, !exact {
            await recordUnchanged(PodcastPrepareAgainRefusal.publisherFileChanged.message,
                                  provenanceOf: old.revision)
            return .refused(.publisherFileChanged)
        }

        let stagedRevisionID = try await store.resolvePodcastRevision(itemID: episodeID,
                                                                      contentHash: staged.contentHash)
        let stagedRevision = try AudioRevision(
            itemID: episodeID, revisionID: stagedRevisionID, durationSeconds: staged.durationSeconds,
            byteCount: staged.byteCount, contentHash: staged.contentHash, mediaType: staged.mediaType,
            createdAt: Timestamp(now()), schemaVersion: 3)
        report(PodcastPreparationProgress(
            stage: "pipeline.start", detail: episode.title,
            evidence: provenanceEvidence(sourceRevisionID: stagedRevisionID, sourceHash: staged.contentHash,
                                         codeRevision: codeRevision)))
        do {
            let preparedURL = preparedAudioURL(for: staged.url)
            store.inFlightMedia.begin(preparedURL)
            defer { store.inFlightMedia.end(preparedURL) }
            let request = try await workerRequest(episode: episode, audioURL: staged.url, preparedURL: preparedURL,
                                                  sourceHash: staged.contentHash, policy: policy, onStatus: report)
            let response = try await runner.run(request: request, onProgress: report)
            let payload = try Self.decode(response)
            if payload.droppedCueCount > 0 {
                let totalCues = payload.cues.count + payload.droppedCueCount
                report(PodcastPreparationProgress(
                    stage: "transcript.cues.dropped",
                    detail: "\(payload.droppedCueCount) of \(totalCues) transcript cues were malformed and left out"))
            }
            report(Self.resultProgress(payload))
            for (index, ad) in payload.adSegments.enumerated() { report(Self.adProgress(ad, ordinal: index + 1)) }

            if payload.adRemovalOutcome == "uncertain" {
                guard URL(fileURLWithPath: payload.audioPath).resolvingSymlinksInPath().standardizedFileURL
                        == staged.url.resolvingSymlinksInPath().standardizedFileURL else {
                    throw PodcastPreparationError.malformedWorkerResponse("uncertain result changed the original audio path")
                }
                let summary = "Kept the existing cut: the current engine could not tell which parts were ads"
                await recordUnchanged(summary, provenanceOf: stagedRevision)
                return .keptExisting(summary)
            }
            let result = try await commitAgain(payload, episode: episode, staged: staged,
                                               stagedRevision: stagedRevision, old: old, kept: kept,
                                               exact: exact, policy: policy, mayReplace: mayReplace,
                                               onStatus: report)
            await writes.drain()
            await journalTerminal(episodeID: episodeID, requestID: requestID, attempt: attempt, error: nil,
                                  revisionID: result.revision.revisionID, summary: result.summary,
                                  fingerprint: fingerprint, sourceRevisionID: stagedRevisionID,
                                  sourceHash: staged.contentHash, sourceURL: candidate.enclosureURL,
                                  timeline: payload.timeline, codeRevision: codeRevision)
            await onJournaled()
            return .prepared(result)
        } catch let refused as PrepareAgainRefused {
            await recordUnchanged(refused.reason.message, provenanceOf: old.revision)
            return .refused(refused.reason)
        } catch {
            await writes.drain()
            await journalTerminal(episodeID: episodeID, requestID: requestID, attempt: attempt, error: error,
                                  revisionID: nil, fingerprint: fingerprint, sourceRevisionID: stagedRevisionID,
                                  sourceHash: staged.contentHash, sourceURL: candidate.enclosureURL,
                                  codeRevision: codeRevision)
            await onJournaled()
            throw error
        }
    }

    // MARK: Commit

    /// Publishes the new audio next to the old cut and swaps them in one save.
    ///
    /// Unlike the first commit there is a previous revision whose playback has
    /// to move, a file that is not in the library yet whichever way the run
    /// went, and a cut that must stop existing: its records go in the same save
    /// as the new revision (`replaceReadyRevision`), and its file only after.
    /// Nothing is moved into the library until the place has been carried, so
    /// a refusal found here leaves no stray file behind.
    private func commitAgain(
        _ payload: WorkerPayload,
        episode: PodcastEpisode,
        staged: StagedPodcastAudio,
        stagedRevision: AudioRevision,
        old: StoredAudioRevision,
        kept: [PodcastKeepInterval]?,
        exact: Bool,
        policy: PodcastPreparationPolicySnapshot,
        mayReplace: @escaping @Sendable () async -> Bool,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> PodcastPreparationResult {
        let itemID = episode.itemID
        let source: URL
        let hash: String
        let byteCount: Int64
        let revisionID: RevisionID
        let duration: Double
        if payload.audioChanged {
            onStatus(PodcastPreparationProgress(stage: "audio.publish", detail: "storing prepared audio"))
            source = URL(fileURLWithPath: payload.audioPath)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
                  let size = attributes[.size] as? Int64, size > 0 else {
                throw PodcastPreparationError.preparedAudioUnreadable
            }
            byteCount = size
            hash = try Self.contentHash(of: source)
            revisionID = try await store.resolvePodcastRevision(itemID: itemID, contentHash: hash)
            duration = payload.durationSeconds
                ?? max(0.001, stagedRevision.durationSeconds - payload.removedSeconds)
        } else {
            // Nothing to cut: the original is the prepared audio.
            source = staged.url
            hash = staged.contentHash
            byteCount = staged.byteCount
            revisionID = stagedRevision.revisionID
            duration = staged.durationSeconds
        }
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: duration,
                                         byteCount: byteCount, contentHash: hash, mediaType: stagedRevision.mediaType,
                                         createdAt: Timestamp(now()), schemaVersion: 3)
        // The same bytes as the cut already in the library: the revision is the
        // ready one, so there is nothing to supersede and the place is where it was.
        let isSameAsCut = revisionID == old.revision.revisionID
        let forward = payload.audioChanged ? (keeps: payload.keepIntervals, silence: payload.silenceTrims) : nil
        // Carried once before anything moves, so a place that cannot be carried
        // is refused with no file placed in the library.
        var carry = CarriedPlace(carried: nil, from: nil)
        if !isSameAsCut {
            carry = try await carriedPlaybackAgain(from: old.revision, to: revision, kept: kept, exact: exact,
                                                   forward: forward)
        }

        let finalURL: URL
        if let existing = try await store.readyRevision(for: itemID, revisionID: revisionID)?.mediaURL {
            finalURL = existing
        } else {
            finalURL = old.mediaURL.deletingLastPathComponent()
                .appendingPathComponent(revisionID.rawValue + "." + staged.url.pathExtension)
        }
        // The final file exists before its revision record does; see `commit`.
        store.inFlightMedia.begin(finalURL)
        var placed = false
        let transcript: Transcript
        do {
            if finalURL != source {
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    guard try Self.contentHash(of: finalURL) == hash else {
                        throw PodcastPreparationError.preparedAudioUnreadable
                    }
                    try FileManager.default.removeItem(at: source)
                } else {
                    try FileManager.default.moveItem(at: source, to: finalURL)
                    placed = true
                }
            }
            // The worker only renames its output, and the cut is deleted once
            // the save lands: a power loss must not take back the file the
            // new record names.
            try DurableFile.persist(finalURL)

            transcript = try Self.transcript(from: payload, itemID: itemID, revisionID: revisionID,
                                             updatedAt: Timestamp(now()))
            let outcome = PodcastPreparationOutcome(
                episodeID: itemID, revisionID: revisionID, policyDigest: Self.policyDigest(policy),
                pipelineFingerprint: Self.semanticFingerprintResolution,
                semanticVersion: Self.semanticVersion, producedAt: Timestamp(now()))
            var lifetimeStatistics = [LifetimeStatisticContribution(
                id: LifetimeStatisticEventID.podcastAudioProcessed(sourceRevisionID: stagedRevision.revisionID),
                kind: .audioProcessed, seconds: stagedRevision.durationSeconds)]
            if payload.adRemovalOutcome == "cut", payload.audioChanged,
               payload.removedSeconds.isFinite, payload.removedSeconds > 0 {
                lifetimeStatistics.append(LifetimeStatisticContribution(
                    id: LifetimeStatisticEventID.podcastAdRemoved(revisionID: revisionID),
                    kind: .confirmedAdTimeRemoved, seconds: payload.removedSeconds))
            }
            if isSameAsCut {
                try await store.saveReadyRevision(revision, mediaURL: finalURL, transcript: transcript,
                                                  outcome: outcome, lifetimeStatistics: lifetimeStatistics)
            } else {
                let download = try PodcastDownload(episodeID: itemID, status: .completed, bytesReceived: byteCount,
                                                   expectedByteCount: byteCount, localURL: finalURL, contentHash: hash,
                                                   updatedAt: Timestamp(now()))
                // The save deletes the cut's place. One the phone synced since
                // the carry was read is carried again rather than lost.
                var retries = 0
                while true {
                    // Stop, or the cut being loaded into the player, wins up to
                    // the save itself.
                    try Task.checkCancellation()
                    guard await mayReplace() else { throw CancellationError() }
                    do {
                        try await store.replaceReadyRevision(
                            revision, mediaURL: finalURL, transcript: transcript, download: download,
                            superseding: old.revision.revisionID, outcome: outcome, carrying: carry.carried,
                            expectingSupersededPlayback: .unchanged(carry.from),
                            lifetimeStatistics: lifetimeStatistics)
                        break
                    } catch is LocalLibraryStore.SupersededPlaybackMoved where retries < 2 {
                        retries += 1
                        carry = try await carriedPlaybackAgain(from: old.revision, to: revision, kept: kept,
                                                               exact: exact, forward: forward)
                    }
                }
            }
            store.inFlightMedia.end(finalURL)
        } catch {
            store.inFlightMedia.end(finalURL)
            // A file placed for a save that never landed belongs to nothing.
            if placed { await store.deleteMediaIfUnreferenced([finalURL]) }
            throw error
        }
        if !isSameAsCut {
            // Only now is the successor durable, so only now may the cut go: a
            // crash before this leaves the cut in place to be swept as an
            // orphan or reused, never a ready revision without a file.
            await store.deleteMediaIfUnreferenced([old.mediaURL])
        }
        return finish(payload, revision: revision, mediaURL: finalURL, transcript: transcript, onStatus: onStatus)
    }

    /// The listener's place on the old cut, moved onto the new audio (nil
    /// when there is none to move), with the place it was read from.
    ///
    /// Read again here rather than taken from the start of the run: the phone
    /// can sync a new place while the original downloads. A place past the start
    /// is carried only through the old timeline (`exact`), because any other
    /// route is a guess at where the listener was.
    private func carriedPlaybackAgain(
        from previous: AudioRevision,
        to revision: AudioRevision,
        kept: [PodcastKeepInterval]?,
        exact: Bool,
        forward: (keeps: [PodcastKeepInterval], silence: [Range<Double>])?
    ) async throws -> CarriedPlace {
        guard let existing = try await store.playbackState(for: previous.itemID, revisionID: previous.revisionID) else {
            return CarriedPlace(carried: nil, from: nil)
        }
        var position = 0.0
        if existing.positionSeconds > 0 {
            guard exact, let kept,
                  let original = PodcastKeepInterval.unmap(existing.positionSeconds, through: kept) else {
                throw PrepareAgainRefused(reason: .publisherFileChanged)
            }
            if let forward {
                // Past the new cut's last kept audio is its end: the listener
                // was in a closing break, and their place stays at the end.
                position = PodcastKeepInterval.mapSnapping(original, through: forward.keeps, silence: forward.silence)
                    ?? revision.durationSeconds
            } else {
                position = original
            }
        }
        let carried = try PlaybackState(
            itemID: revision.itemID, revisionID: revision.revisionID, sessionID: existing.sessionID,
            sequence: existing.sequence + 1, positionSeconds: min(position, revision.durationSeconds),
            durationSeconds: revision.durationSeconds, completed: existing.completed, intent: existing.intent,
            deviceID: existing.deviceID, updatedAt: Timestamp(now()))
        return CarriedPlace(carried: carried, from: existing)
    }
}

/// A place moved onto new audio, and the saved place it was computed from,
/// which the save checks is still the one on record.
private struct CarriedPlace {
    let carried: PlaybackState?
    let from: PlaybackState?
}
