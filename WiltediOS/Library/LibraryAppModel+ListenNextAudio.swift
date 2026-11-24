import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let listenNextAudioLog = Logger(subsystem: "com.zerodelta.wilted", category: "ListenNextAudio")

extension LibraryAppModel {
    /// Applies local playback phases only when the caller still owns the stored request snapshot.
    /// Remote preparation status remains the Mac's responsibility.
    func setListenNextStatus(
        _ snapshot: LibraryListenNextRequestSnapshot,
        to status: LibraryListenNextRequestSnapshot.Status,
        failure: LibraryListenNextStatus.Failure? = nil
    ) async -> LibraryListenNextRequestSnapshot? {
        guard snapshot.requesterDeviceID == deviceID,
              let context = await liveListenNextContext(),
              context.ownerToken == snapshot.ownerToken,
              context.generation == snapshot.operationGeneration,
              let index = listenNextState.entries.firstIndex(where: { $0.id == snapshot.requestID }),
              listenNextState.entries[index].snapshot == snapshot else { return nil }

        let allowedTransition: Bool
        switch (snapshot.status, status) {
        case (.ready, .selected), (.selected, .ready), (.selected, .playing), (.playing, .completed),
             (.selected, .failed), (.playing, .failed):
            allowedTransition = true
        default:
            allowedTransition = false
        }
        guard allowedTransition, snapshot.statusRevision < UInt64.max else { return nil }

        let nextFailure = status == .failed ? (failure ?? snapshot.failure ?? .transferFailed) : nil
        let keepsOffer = status == .ready || status == .selected || status == .playing || status == .completed
        guard let updated = try? LibraryListenNextRequestSnapshot(
            requestID: snapshot.requestID, story: snapshot.story,
            requesterDeviceID: snapshot.requesterDeviceID, ownerToken: snapshot.ownerToken,
            operationGeneration: snapshot.operationGeneration, anchorID: snapshot.anchorID,
            createdAt: snapshot.createdAt, statusUpdatedAt: now(), status: status,
            statusRevision: snapshot.statusRevision + 1,
            audioOffer: keepsOffer ? snapshot.audioOffer : nil,
            voiceID: snapshot.voiceID, voiceRevision: snapshot.voiceRevision, failure: nextFailure
        ) else { return nil }

        let previous = listenNextState.entries[index]
        listenNextState.entries[index].snapshot = updated
        do {
            try persistListenNext()
            return updated
        } catch {
            listenNextState.entries[index] = previous
            publishListenNextRows()
            return nil
        }
    }

    /// Resolves only an exact, already cached offer for this verified phone and account.
    func listenNextAudioURL(for snapshot: LibraryListenNextRequestSnapshot) async -> URL? {
        guard let context = await liveListenNextContext(),
              snapshot.requesterDeviceID == deviceID, snapshot.ownerToken == context.ownerToken,
              snapshot.operationGeneration == context.generation,
              snapshot.status == .ready || snapshot.status == .selected || snapshot.status == .playing,
              let offer = snapshot.audioOffer,
              let entry = listenNextState.entries.first(where: { $0.id == snapshot.requestID }),
              hasExactCachedStory(entry, matching: snapshot) else { return nil }
        guard let expectedURL = listenNextState.audioCache.url(for: offer, ownerToken: snapshot.ownerToken),
              let fileURL = storyPlaybackAudioURL(for: snapshot),
              fileURL.standardizedFileURL == expectedURL.standardizedFileURL,
              fileURL.isFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == offer.byteCount,
                  try await Task.detached(priority: .utility) { try MediaHash.sha256(fileAt: fileURL) }.value == offer.contentHash,
                  await mediaContextIsCurrent(context, live: true),
                  listenNextState.entries.first(where: { $0.id == snapshot.requestID })
                    .map({ hasExactCachedStory($0, matching: snapshot) }) == true else {
                return nil
            }
            return fileURL
        } catch {
            listenNextAudioLog.error("Cached story audio failed its local identity check for \(snapshot.requestID, privacy: .public).")
            return nil
        }
    }

    /// Removes completed request audio after the completion snapshot is durable.
    func discardCompletedListenNextAudio(_ snapshot: LibraryListenNextRequestSnapshot) async {
        guard let context = await liveListenNextContext() else { return }
        discardCompletedListenNextAudio(snapshot, context: context)
    }

    /// Repairs a committed local completion whose request status or cache deletion was interrupted.
    func reconcileCompletedListenNextAudio(context: LibraryMediaContext) async {
        let candidates = listenNextState.entries.map(\.snapshot).filter {
            ($0.status == .playing || $0.status == .completed)
                && $0.requesterDeviceID == deviceID && $0.ownerToken == context.ownerToken
                && $0.operationGeneration == context.generation
        }
        for var snapshot in candidates {
            guard await mediaContextIsCurrent(context, live: true) else { return }
            if snapshot.status == .playing {
                guard let store = storyPlaybackLedgerStore(for: snapshot),
                      let completed = store.load().entries.first(where: {
                          $0.requestID == snapshot.requestID && $0.phase == .completed
                      }),
                      completed.requesterDeviceID == deviceID,
                      completed.ownerToken == snapshot.ownerToken,
                      completed.operationGeneration == snapshot.operationGeneration,
                      let updated = await setListenNextStatus(snapshot, to: .completed),
                      updated.status == .completed,
                      await mediaContextIsCurrent(context, live: true) else { continue }
                snapshot = updated
            }
            discardCompletedListenNextAudio(snapshot, context: context)
        }
    }

    /// The caller holds a verified current context and runs this on the main actor without suspension.
    func discardCompletedListenNextAudio(
        _ snapshot: LibraryListenNextRequestSnapshot, context: LibraryMediaContext
    ) {
        guard snapshot.status == .completed, snapshot.requesterDeviceID == deviceID,
              snapshot.ownerToken == context.ownerToken,
              snapshot.operationGeneration == context.generation,
              let index = listenNextState.entries.firstIndex(where: {
                  $0.id == snapshot.requestID && $0.snapshot == snapshot
              }) else { return }
        do {
            try listenNextState.audioCache.removeAudio(
                for: snapshot.requestID, ownerToken: snapshot.ownerToken)
        } catch {
            listenNextAudioLog.error("Completed story audio cleanup failed for \(snapshot.requestID, privacy: .public).")
            return
        }
        guard listenNextState.entries[index].audioCached else { return }
        let previous = listenNextState.entries[index]
        listenNextState.entries[index].audioCached = false
        do { try persistListenNext() }
        catch {
            listenNextState.entries[index] = previous
            publishListenNextRows()
            listenNextAudioLog.error("Completed story cache state could not be saved for \(snapshot.requestID, privacy: .public).")
        }
    }

    private func hasExactCachedStory(
        _ entry: LibraryListenNextPhoneEntry,
        matching snapshot: LibraryListenNextRequestSnapshot
    ) -> Bool {
        let saved = entry.snapshot
        let allowed: Set<LibraryListenNextRequestSnapshot.Status> = [.ready, .selected, .playing]
        return entry.audioCached && allowed.contains(saved.status) && allowed.contains(snapshot.status)
            && saved.requestID == snapshot.requestID && saved.story == snapshot.story
            && saved.requesterDeviceID == snapshot.requesterDeviceID && saved.ownerToken == snapshot.ownerToken
            && saved.operationGeneration == snapshot.operationGeneration && saved.anchorID == snapshot.anchorID
            && saved.createdAt == snapshot.createdAt && saved.audioOffer == snapshot.audioOffer
            && saved.voiceID == snapshot.voiceID && saved.voiceRevision == snapshot.voiceRevision
    }

    func refreshListenNextStatuses(context: LibraryMediaContext) async {
        guard let storyAudioTransport, await mediaContextIsCurrent(context, live: true) else { return }
        let active = Set(listenNextState.entries.filter {
            $0.requestSent && $0.snapshot.requesterDeviceID == deviceID && $0.snapshot.ownerToken == context.ownerToken
                && $0.snapshot.status != .cancelled && $0.snapshot.status != .completed
        }.map(\.id))
        guard !active.isEmpty else { return }
        do {
            let statuses = try await storyAudioTransport.listenNextStatuses(requestIDs: active, expectedOwner: context.ownerToken)
            guard await mediaContextIsCurrent(context, live: true) else { return }
            for status in statuses {
                guard status.requesterDeviceID == deviceID,
                      let index = listenNextState.entries.firstIndex(where: {
                          $0.id == status.requestID && $0.snapshot.ownerToken == context.ownerToken
                      }), listenNextState.entries[index].snapshot.status != .cancelled,
                      status.storyID == listenNextState.entries[index].snapshot.storyID,
                      status.statusRevision >= listenNextState.entries[index].remoteStatusRevision else { continue }
                let entry = listenNextState.entries[index]
                let state: LibraryListenNextRequestSnapshot.Status
                if entry.snapshot.status == .selected || entry.snapshot.status == .playing {
                    state = entry.snapshot.status
                } else if entry.snapshot.status == .failed, status.phase == .ready {
                    state = .failed
                } else {
                    switch status.phase {
                    case .preparing: state = .preparing
                    case .ready: state = .ready
                    case .failed: state = .failed
                    case .cancelled: state = .cancelled
                    }
                }
                if entry.snapshot.status == .completed { continue }
                let localPlaybackState = state == .selected || state == .playing
                    || (state == .failed && entry.snapshot.status == .failed && status.phase == .ready)
                let localPlaybackOffer = localPlaybackState ? entry.snapshot.audioOffer : nil
                let localPlaybackVoiceID = localPlaybackState ? entry.snapshot.voiceID : nil
                let localPlaybackVoiceRevision = localPlaybackState ? entry.snapshot.voiceRevision : nil
                let statusUpdatedAt = localPlaybackState ? entry.snapshot.statusUpdatedAt : status.updatedAt
                let statusRevision = localPlaybackState ? entry.snapshot.statusRevision : status.statusRevision
                let failure = state == .failed
                    ? (localPlaybackState ? entry.snapshot.failure : status.failure)
                    : nil
                let refreshed: LibraryListenNextRequestSnapshot
                do {
                    refreshed = try LibraryListenNextRequestSnapshot(
                        requestID: entry.id, story: entry.snapshot.story, requesterDeviceID: deviceID,
                        ownerToken: entry.snapshot.ownerToken, operationGeneration: context.generation,
                        anchorID: entry.snapshot.anchorID, createdAt: entry.snapshot.createdAt,
                        statusUpdatedAt: statusUpdatedAt, status: state,
                        statusRevision: statusRevision,
                        audioOffer: state == .failed ? nil : (localPlaybackOffer ?? status.audioOffer),
                        voiceID: localPlaybackVoiceID ?? status.voiceID,
                        voiceRevision: localPlaybackVoiceRevision ?? status.voiceRevision,
                        failure: failure
                    )
                } catch {
                    reportListenNextError(Self.listenNextErrorText(error))
                    continue
                }
                let changed = entry.remoteStatusRevision != status.statusRevision || entry.snapshot != refreshed
                if changed {
                    listenNextState.entries[index].remoteStatusRevision = status.statusRevision
                    listenNextState.entries[index].snapshot = refreshed
                    do {
                        try persistListenNext()
                        if state == .cancelled {
                            try storyRequestCancelled(refreshed)
                            try listenNextState.audioCache.removeAudio(
                                for: refreshed.requestID, ownerToken: refreshed.ownerToken)
                            if listenNextState.entries[index].audioCached {
                                listenNextState.entries[index].audioCached = false
                                try persistListenNext()
                            }
                        } else if state == .failed {
                            try storyRequestFailed(refreshed)
                        }
                    } catch {
                        reportListenNextError(Self.listenNextErrorText(error))
                        continue
                    }
                }
                if state == .ready { startListenNextAudioDownload(requestID: status.requestID, context: context) }
            }
        } catch {
            listenNextAudioLog.notice("Status refresh deferred for \(active.count, privacy: .public) stories.")
        }
    }

    private func startListenNextAudioDownload(requestID: String, context: LibraryMediaContext) {
        guard let storyAudioTransport,
              !listenNextState.downloadingRequests.contains(requestID),
              let entry = listenNextState.entries.first(where: {
                  $0.id == requestID && $0.snapshot.status == .ready && $0.snapshot.requesterDeviceID == deviceID
                      && $0.snapshot.ownerToken == context.ownerToken && !$0.audioCached
              }), let offer = entry.snapshot.audioOffer else { return }
        let runID = UUID()
        listenNextState.downloadingRequests.insert(requestID)
        listenNextState.downloadRunIDs[requestID] = runID
        setListenNextDownloadProgress(0, requestID: requestID)
        listenNextState.downloadTasks[requestID] = Task { @MainActor [weak self] in
            await self?.performListenNextAudioDownload(
                requestID: requestID, offer: offer, context: context, runID: runID,
                storyAudioTransport: storyAudioTransport
            )
        }
    }

    private func performListenNextAudioDownload(
        requestID: String,
        offer: LibraryStoryAudioOffer,
        context: LibraryMediaContext,
        runID: UUID,
        storyAudioTransport: any LibraryStoryAudioTransport
    ) async {
        defer {
            if listenNextState.downloadRunIDs[requestID] == runID {
                listenNextState.downloadTasks[requestID] = nil
                listenNextState.downloadRunIDs[requestID] = nil
                listenNextState.downloadingRequests.remove(requestID)
                setListenNextDownloadProgress(nil, requestID: requestID)
            }
        }
        do {
            guard !Task.isCancelled, await mediaContextIsCurrent(context, live: true) else { return }
            let fileURL = try await storyAudioTransport.fetchStoryAudio(offer, expectedOwner: context.ownerToken) { [weak self] bytes in
                Task { @MainActor in
                    guard let self,
                          self.listenNextState.downloadRunIDs[requestID] == runID,
                          self.listenNextState.entries.contains(where: {
                              $0.id == requestID && $0.snapshot.status == .ready && $0.snapshot.audioOffer == offer
                          }) else { return }
                    self.setListenNextDownloadProgress(bytes, requestID: requestID)
                }
            }
            defer { try? FileManager.default.removeItem(at: fileURL) }
            guard !Task.isCancelled, await mediaContextIsCurrent(context, live: true),
                  let current = listenNextState.entries.first(where: {
                      $0.id == requestID && $0.snapshot.status == .ready && $0.snapshot.audioOffer == offer
                          && $0.snapshot.requesterDeviceID == deviceID
                  }) else { return }
            let cache = listenNextState.audioCache
            let cachedURL = try await Task.detached(priority: .utility) {
                try cache.store(fileURL, for: offer, ownerToken: context.ownerToken)
            }.value
            guard !Task.isCancelled, await mediaContextIsCurrent(context, live: true),
                  let current = listenNextState.entries.first(where: {
                      $0.id == requestID && $0.snapshot.status == .ready && $0.snapshot.audioOffer == offer
                          && $0.snapshot.requesterDeviceID == deviceID
                  }) else {
                try? cache.removeAudio(for: requestID, ownerToken: context.ownerToken)
                return
            }
            guard let readyIndex = listenNextState.entries.firstIndex(where: { $0.id == requestID }) else { return }
            listenNextState.entries[readyIndex].audioCached = true
            try persistListenNext()
            do {
                // Playback can start as soon as the queue stores this path, so persist cache admission first.
                try storyAudioBecameReady(current.snapshot, fileURL: cachedURL)
            } catch {
                if let rollbackIndex = listenNextState.entries.firstIndex(where: { $0.id == requestID }) {
                    listenNextState.entries[rollbackIndex].audioCached = false
                    try? persistListenNext()
                }
                throw error
            }
            guard !Task.isCancelled, await mediaContextIsCurrent(context, live: true) else { return }
        } catch {
            if Task.isCancelled { return }
            listenNextAudioLog.notice("Audio download deferred for \(requestID, privacy: .public).")
        }
    }

    func cancelListenNextDownloads(requestID: String? = nil) {
        let requestIDs = requestID.map { [$0] } ?? Array(listenNextState.downloadTasks.keys)
        for id in requestIDs {
            listenNextState.downloadTasks[id]?.cancel()
            listenNextState.downloadTasks[id] = nil
            listenNextState.downloadRunIDs[id] = nil
            listenNextState.downloadingRequests.remove(id)
            setListenNextDownloadProgress(nil, requestID: id)
        }
    }
}
