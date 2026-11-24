import Foundation
import WiltedDomain

extension PlaybackController {
    /// Loads request-scoped narration without creating podcast/article playback rows.
    public func loadListenNextStory(
        requestID: String, revision: AudioRevision, mediaURL: URL, positionSeconds: Double
    ) async throws {
        guard !requestID.isEmpty else { throw CancellationError() }
        guard positionSeconds.isFinite, positionSeconds >= 0 else {
            throw PlaybackControllerError.invalidSeek(positionSeconds)
        }
        let generation = try await loadRevision(
            revision, mediaURL: mediaURL, isPodcast: false, listenNextRequestID: requestID)
        guard loadedBackendGeneration == generation, itemID == revision.itemID,
              listenNextRequestID == requestID else {
            clearLoadedListenNextStoryIfCurrent(revision.itemID, generation: generation)
            throw CancellationError()
        }
        let target = clamp(positionSeconds)
        backend.currentTime = target
        self.positionSeconds = target
        completed = false
        intent = .progress
        speedSavingsBaselineSeconds = target
        listenNextPositionHandler?(requestID, target)
    }

    /// Removes a request-owned story after cancellation or account recovery,
    /// without stopping a newer podcast or story load.
    public func stopListenNextStory(requestID: String) {
        guard listenNextRequestID == requestID, let itemID, let generation = loadedBackendGeneration else { return }
        clearLoadedListenNextStoryIfCurrent(itemID, generation: generation)
    }

    private func clearLoadedListenNextStoryIfCurrent(_ storyID: ItemID, generation: UInt64) {
        guard loadedBackendGeneration == generation, itemID == storyID else { return }
        endOutputLossWatch()
        backend.stop()
        loadedBackendGeneration = nil
        currentRevision = nil
        itemID = nil
        revisionID = nil
        mediaURL = nil
        listenNextRequestID = nil
        loadedIsPodcastEpisode = false
        positionSeconds = 0
        durationSeconds = 0
        isPlaying = false
        completed = false
        intent = .progress
        sessionID = nil
        sequence = 1
        lastWritten = nil
        completionHandledGeneration = nil
        recoverableFault = nil
        speedSavingsBaselineSeconds = 0
        interruptionItemChanged()
        playbackDidFinishHandler?()
    }

    /// Restores the device-local story stop fence before accepting queued requests.
    public func restoreListenNextHoldEpoch(_ epoch: UInt64) {
        listenNextHoldEpoch = max(listenNextHoldEpoch, epoch)
    }

    /// A listener's explicit Play or selection releases prior stop holds.
    public func rearmListenNextQueueForExplicitStart() {
        listenNextHoldEpoch &+= 1
        listenNextRearmHandler?(listenNextHoldEpoch)
    }

    func holdListenNextQueue() {
        listenNextHoldEpoch &+= 1
        listenNextHoldHandler?(listenNextHoldEpoch)
    }

    /// Starts a selected story without rearming other queued requests.
    @discardableResult
    public func startListenNextStory() throws -> PlaybackStartOutcome {
        guard listenNextRequestID != nil, currentRevision != nil, let itemID else {
            throw PlaybackControllerError.noLoadedRevision
        }
        if backend.isPlaying {
            isPlaying = true
            meterListening()
            return .alreadyPlaying
        }
        isPlaying = backend.play()
        meterListening()
        guard isPlaying else { throw PlaybackTransportError.backendRefused(itemID) }
        recoverableFault = nil
        return .started
    }

    /// Starts the already loaded story without releasing a saved stop fence.
    @discardableResult
    public func resumeListenNextStory() throws -> PlaybackStartOutcome {
        guard listenNextRequestID != nil, currentRevision != nil, let itemID else {
            throw PlaybackControllerError.noLoadedRevision
        }
        if backend.isPlaying { return .alreadyPlaying }
        isPlaying = backend.play()
        meterListening()
        guard isPlaying else { throw PlaybackTransportError.backendRefused(itemID) }
        recoverableFault = nil
        return .started
    }

    /// Restores the durable current queue item without starting a duplicate
    /// playback session. Loading the exact revision reuses its saved session.
    public func restorePodcastQueue() async {
        guard let current = try? await store.podcastQueueState().currentEpisodeID else { return }
        do { try await loadQueuedEpisode(current, playAfterLoad: false) }
        catch PlaybackControllerError.mediaDeletionInProgress { return }
        catch { podcastStateHandler?(current, recoverableFault) }
    }

    /// Restores the saved podcast after a story reservation was superseded,
    /// but only while that request's loaded revision still owns the player.
    public func restorePodcastQueue(afterListenNextRequest requestID: String) async {
        guard listenNextRequestID == requestID, let expectedGeneration = loadedBackendGeneration else { return }
        guard let current = try? await store.podcastQueueState().currentEpisodeID,
              listenNextRequestID == requestID, loadedBackendGeneration == expectedGeneration else { return }
        do {
            try await loadQueuedEpisode(current, playAfterLoad: false, expectedGeneration: expectedGeneration)
        } catch PlaybackControllerError.mediaDeletionInProgress { return }
        catch is CancellationError { return }
        catch { podcastStateHandler?(current, recoverableFault) }
    }

}
