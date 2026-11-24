import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

struct WiltedMacListenNextNowPlaying: Equatable {
    let requestID: String
    let storyID: String
    let title: String
    let publisherName: String
}

extension WiltedMacModel {
    static let listenNextPlaybackLedgerKey = "wilted.listenNext.playback.v1"
    static let listenNextPlaybackHoldKey = "wilted.listenNext.playback.hold.v1"
    static let listenNextPlaybackHeldKey = "wilted.listenNext.playback.held.v1"

    /// Registers the request locally before its first network send.
    func recordStoryListenNext(_ snapshot: LibraryListenNextRequestSnapshot, holdEpoch: UInt64) throws {
        guard snapshot.requesterDeviceID == libraryDeviceID(),
              let storyID = try? ItemID(rawValue: snapshot.storyID) else { return }
        rearmStoryQueueForExplicitListenNext()
        let admissionEpoch = playback?.listenNextHoldEpoch
            ?? (preferences.object(forKey: Self.listenNextPlaybackHoldKey) as? UInt64 ?? holdEpoch)
        var ledger = storyPlaybackLedger(for: snapshot)
        ledger.record(
            requestID: snapshot.requestID, storyID: storyID, requesterDeviceID: snapshot.requesterDeviceID,
            ownerToken: snapshot.ownerToken, operationGeneration: snapshot.operationGeneration,
            anchorID: snapshot.anchorID, createdAt: snapshot.createdAt, holdEpoch: admissionEpoch,
            phase: queuePhase(for: snapshot.status))
        if let playback, playback.completed, playback.listenNextRequestID == nil,
           let anchorID = playback.itemID {
            let boundary: (id: String, continuation: ListenNextContinuation)
            if playlistSessionIsCurrent, let session = playlists.session,
               session.currentEntryID == anchorID.rawValue {
                boundary = (
                    "playlist:\(session.playlistID):\(playback.listenNextNaturalBoundarySerial)",
                    ListenNextContinuation(
                        kind: .macPlaylist, anchorID: anchorID,
                        entryIDs: session.entryIDs.compactMap { try? ItemID(rawValue: $0) },
                        nextIndex: session.index + 1, playlistID: session.playlistID))
            } else {
                let continuation = larderContinuation(after: anchorID)
                boundary = ("\(anchorID.rawValue):\(playback.listenNextNaturalBoundarySerial)", continuation)
            }
            ledger.recordNaturalBoundary(
                boundaryID: boundary.id, continuation: boundary.continuation,
                holdEpoch: playback.listenNextHoldEpoch)
        }
        try storyPlaybackLedgerStore(for: snapshot)?.save(ledger)
    }

    /// Merges request preparation state without replacing an already selected player entry.
    func refreshListenNextSnapshots(_ snapshots: [LibraryListenNextRequestSnapshot]) async {
        let localDeviceID = libraryDeviceID()
        for snapshot in snapshots where snapshot.requesterDeviceID == localDeviceID {
            guard let storyID = try? ItemID(rawValue: snapshot.storyID),
                  let store = storyPlaybackLedgerStore(for: snapshot) else { continue }
            var ledger = store.load()
            if !ledger.entries.contains(where: { $0.requestID == snapshot.requestID }) {
                guard snapshot.status != .selected, snapshot.status != .playing,
                      snapshot.status != .completed else { continue }
                ledger.record(
                    requestID: snapshot.requestID, storyID: storyID,
                    requesterDeviceID: snapshot.requesterDeviceID, ownerToken: snapshot.ownerToken,
                    operationGeneration: snapshot.operationGeneration, anchorID: snapshot.anchorID,
                    createdAt: snapshot.createdAt,
                    holdEpoch: storyRequestHoldEpoch(), phase: queuePhase(for: snapshot.status))
            } else {
                ledger.updateRequestPhase(requestID: snapshot.requestID, phase: queuePhase(for: snapshot.status))
            }
            if snapshot.status == .ready, let url = await listenNextAudioURL(for: snapshot) {
                ledger.setReadyMedia(
                    requestID: snapshot.requestID, fileURL: url,
                    audioOfferIdentity: audioOfferIdentity(for: snapshot))
            }
            try? store.save(ledger)
        }
    }

    /// Persists only a verified, durable request-owned audio path.
    func storyAudioBecameReady(_ snapshot: LibraryListenNextRequestSnapshot, fileURL: URL) async throws {
        guard snapshot.requesterDeviceID == libraryDeviceID(), snapshot.status == .ready,
              snapshot.audioOffer != nil, fileURL.isFileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let store = storyPlaybackLedgerStore(for: snapshot) else { return }
        var ledger = store.load()
        ledger.setReadyMedia(
            requestID: snapshot.requestID, fileURL: fileURL,
            audioOfferIdentity: audioOfferIdentity(for: snapshot))
        try store.save(ledger)
        await startStoryAtSavedBoundaryIfEligible(snapshot: snapshot)
    }

    func storyRequestCancelled(_ snapshot: LibraryListenNextRequestSnapshot) throws {
        updateStoryRequest(snapshot, phase: .cancelled)
        playback?.stopListenNextStory(requestID: snapshot.requestID)
    }

    func storyRequestFailed(_ snapshot: LibraryListenNextRequestSnapshot) throws {
        updateStoryRequest(snapshot, phase: .failed)
    }

    func failMacStoryPlayback(requestID: String) async {
        guard let (_, store) = storyPlaybackEntry(requestID: requestID) else { return }
        var ledger = store.load()
        ledger.markFailed(requestID: requestID)
        try? store.save(ledger)
        if let snapshot = (await listenNextSnapshots()).first(where: { $0.requestID == requestID }) {
            _ = await setListenNextStatus(snapshot, to: .failed)
        }
        if playback?.listenNextRequestID == requestID {
            currentListenNextStory = nil
            isPlaying = false
            isNowPlaying = false
            refreshPlaybackReadout()
        }
    }

    func hasWaitingListenNextRequest() async -> Bool {
        let snapshots = await listenNextSnapshots()
        await refreshListenNextSnapshots(snapshots)
        return snapshots.contains { snapshot in
            guard snapshot.requesterDeviceID == libraryDeviceID() else { return false }
            switch snapshot.status {
            case .pending, .sent, .preparing, .ready, .selected, .playing: return true
            case .failed, .cancelled, .completed: return false
            }
        }
    }

    func saveStoryPlaybackPosition(requestID: String, positionSeconds: Double) {
        guard let (entry, store) = storyPlaybackEntry(requestID: requestID) else { return }
        var ledger = store.load()
        ledger.savePosition(requestID: requestID, positionSeconds: positionSeconds)
        try? store.save(ledger)
        _ = entry
    }

    /// Captures the exact ordinary suffix at the podcast's natural boundary before selecting a story.
    func startStoryAtNaturalBoundary(
        after endedID: String, continuation: ListenNextContinuation,
        advance: WiltedMacAutomaticAdvance, holdEpochAtEnd: UInt64
    ) async -> Bool {
        guard let playback, playback.itemID?.rawValue == endedID,
              playback.completed, !playback.liveIsPlaying else { return false }
        let snapshots = await listenNextSnapshots()
        await refreshListenNextSnapshots(snapshots)
        guard let identity = snapshots.first(where: { $0.requesterDeviceID == libraryDeviceID() }),
              let store = storyPlaybackLedgerStore(for: identity) else { return false }
        var ledger = store.load()
        let boundaryID = "\(endedID):\(playback.listenNextNaturalBoundarySerial)"
        let holdEpoch = holdEpochAtEnd
        ledger.recordNaturalBoundary(boundaryID: boundaryID, continuation: continuation, holdEpoch: holdEpoch)
        guard playback.listenNextHoldEpoch == holdEpoch else {
            try? store.save(ledger)
            return false
        }
        guard let selected = ledger.selectAtNaturalBoundary(
            boundaryID: boundaryID, continuation: continuation, currentHoldEpoch: holdEpoch) else {
            try? store.save(ledger)
            return false
        }
        guard let snapshot = snapshots.first(where: { $0.requestID == selected.requestID }),
              snapshot.status == .ready,
              let url = await verifiedStoryURL(snapshot),
              automaticAdvanceClaim(advance) == .owns,
              playback.listenNextHoldEpoch == holdEpoch else {
            ledger.markFailed(requestID: selected.requestID)
            try? store.save(ledger)
            return false
        }
        let started = await startSelectedMacStory(
            snapshot: snapshot, fileURL: url, selected: selected, ledger: ledger,
            continuation: continuation, holdEpoch: holdEpoch,
            canStart: { [weak self, weak playback] in
                guard let self, let playback else { return false }
                return self.automaticAdvanceClaim(advance) == .owns
                    && playback.listenNextHoldEpoch == holdEpoch
            }, store: store)
        if started { _ = claimAutomaticAdvance(advance) }
        return started
    }

    /// Gives an already playing playlist a queued story at the natural boundary before its next entry.
    func startStoryAtPlaylistBoundary(
        after endedID: ItemID, holdEpochAtEnd: UInt64, boundarySerial: UInt64
    ) async -> Bool {
        guard let playback, playlistSessionIsCurrent,
              let session = playlists.session,
              session.currentEntryID == endedID.rawValue,
              playback.itemID == endedID, playback.completed else { return false }
        let continuation = ListenNextContinuation(
            kind: .macPlaylist, anchorID: endedID,
            entryIDs: session.entryIDs.compactMap { try? ItemID(rawValue: $0) },
            nextIndex: session.index + 1, playlistID: session.playlistID)
        let snapshots = await listenNextSnapshots()
        await refreshListenNextSnapshots(snapshots)
        guard let identity = snapshots.first(where: { $0.requesterDeviceID == libraryDeviceID() }),
              let store = storyPlaybackLedgerStore(for: identity) else {
            return playback.listenNextHoldEpoch != holdEpochAtEnd
        }
        var ledger = store.load()
        let boundaryID = "playlist:\(session.playlistID):\(boundarySerial)"
        ledger.recordNaturalBoundary(
            boundaryID: boundaryID, continuation: continuation, holdEpoch: holdEpochAtEnd)
        guard playback.listenNextHoldEpoch == holdEpochAtEnd else {
            try? store.save(ledger)
            return true
        }
        guard let selected = ledger.selectAtNaturalBoundary(
            boundaryID: boundaryID, continuation: continuation,
            currentHoldEpoch: holdEpochAtEnd) else {
            try? store.save(ledger)
            return playback.listenNextHoldEpoch != holdEpochAtEnd
        }
        guard let snapshot = snapshots.first(where: { $0.requestID == selected.requestID }),
              snapshot.status == .ready, let url = await verifiedStoryURL(snapshot) else {
            ledger.markFailed(requestID: selected.requestID)
            try? store.save(ledger)
            return playback.listenNextHoldEpoch != holdEpochAtEnd
        }
        let started = await startSelectedMacStory(
            snapshot: snapshot, fileURL: url, selected: selected, ledger: ledger,
            continuation: continuation, holdEpoch: holdEpochAtEnd,
            canStart: { [weak self, weak playback] in
                guard let self, let playback else { return false }
                return self.playlistSessionIsCurrent && playback.itemID == endedID
                    && playback.completed && playback.listenNextHoldEpoch == holdEpochAtEnd
            }, store: store)
        return started || playback.listenNextHoldEpoch != holdEpochAtEnd
    }

    /// Explicit account recovery drops only the local handoff metadata. The request cache owns its audio files.
    func discardStoryPlaybackLedgerAfterAccountChange() {
        if let requestID = playback?.listenNextRequestID {
            playback?.stopListenNextStory(requestID: requestID)
        }
        preferences.removeObject(forKey: Self.listenNextPlaybackLedgerKey)
        preferences.removeObject(forKey: Self.listenNextPlaybackHoldKey)
        preferences.removeObject(forKey: Self.listenNextPlaybackHeldKey)
    }

    func persistStoryQueueHold(at holdEpoch: UInt64) {
        preferences.set(holdEpoch, forKey: Self.listenNextPlaybackHoldKey)
        preferences.set(true, forKey: Self.listenNextPlaybackHeldKey)
    }

    func rearmStoryQueueAfterExplicitStart(at holdEpoch: UInt64) {
        preferences.set(holdEpoch, forKey: Self.listenNextPlaybackHoldKey)
        preferences.set(false, forKey: Self.listenNextPlaybackHeldKey)
        guard let data = preferences.data(forKey: Self.listenNextPlaybackLedgerKey),
              let decoded = try? JSONDecoder().decode(ListenNextPlaybackLedger.self, from: data),
              decoded.requesterDeviceID == libraryDeviceID() else { return }
        let store = ListenNextPlaybackLedgerStore(
            defaults: preferences, key: Self.listenNextPlaybackLedgerKey,
            requesterDeviceID: decoded.requesterDeviceID, ownerToken: decoded.ownerToken,
            operationGeneration: decoded.operationGeneration)
        var ledger = store.load()
        ledger.releaseHold(onExplicitStartAt: holdEpoch)
        try? store.save(ledger)
    }

    /// A committed Listen next request is explicit intent to release a prior stop hold.
    func rearmStoryQueueForExplicitListenNext() {
        guard preferences.bool(forKey: Self.listenNextPlaybackHeldKey) else { return }
        if let playback {
            playback.rearmListenNextQueueForExplicitStart()
        } else {
            let storedEpoch = preferences.object(forKey: Self.listenNextPlaybackHoldKey) as? UInt64 ?? 0
            rearmStoryQueueAfterExplicitStart(at: storedEpoch &+ 1)
        }
    }

    func finishMacStoryPlayback(requestID: String) async {
        guard let (entry, store) = storyPlaybackEntry(requestID: requestID),
              let playback, playback.listenNextRequestID == requestID else { return }
        var ledger = store.load()
        ledger.markCompleted(requestID: requestID)
        try? store.save(ledger)
        if let snapshot = (await listenNextSnapshots()).first(where: { $0.requestID == requestID }) {
            _ = await setListenNextStatus(snapshot, to: .completed)
        }
        currentListenNextStory = nil
        isPlaying = false
        refreshPlaybackReadout()
        guard playback.listenNextHoldEpoch == entry.holdEpoch,
              let continuation = ledger.continuationAfterCompletion(requestID: requestID) else { return }
        let boundaryHoldEpoch = playback.listenNextHoldEpoch
        let nextBoundaryContinuation = ListenNextContinuation(
            kind: continuation.kind, anchorID: entry.storyID, entryIDs: continuation.entryIDs,
            nextIndex: continuation.nextIndex, playlistID: continuation.playlistID)
        let boundaryID = "story:\(requestID):\(playback.listenNextNaturalBoundarySerial)"
        ledger.recordNaturalBoundary(boundaryID: boundaryID, continuation: nextBoundaryContinuation,
                                     holdEpoch: playback.listenNextHoldEpoch)
        guard let selected = ledger.selectAtNaturalBoundary(
            boundaryID: boundaryID, continuation: nextBoundaryContinuation,
            currentHoldEpoch: playback.listenNextHoldEpoch) else {
            try? store.save(ledger)
            await resumeMacContinuation(continuation, playback: playback)
            return
        }
        guard let snapshot = (await listenNextSnapshots()).first(where: { $0.requestID == selected.requestID }),
              snapshot.status == .ready, let url = await verifiedStoryURL(snapshot) else {
            ledger.markFailed(requestID: selected.requestID)
            try? store.save(ledger)
            await resumeMacContinuation(continuation, playback: playback)
            return
        }
        let started = await startSelectedMacStory(
            snapshot: snapshot, fileURL: url, selected: selected, ledger: ledger,
            continuation: continuation, holdEpoch: boundaryHoldEpoch,
            canStart: { [weak playback] in
                playback?.completed == true && playback?.listenNextHoldEpoch == boundaryHoldEpoch
            }, store: store)
        if !started {
            await resumeMacContinuation(continuation, playback: playback,
                                        expectedHoldEpoch: boundaryHoldEpoch)
        }
    }

    func storyPlaybackLedgerStore(
        for snapshot: LibraryListenNextRequestSnapshot
    ) -> ListenNextPlaybackLedgerStore? {
        guard snapshot.requesterDeviceID == libraryDeviceID() else { return nil }
        return ListenNextPlaybackLedgerStore(
            defaults: preferences, key: Self.listenNextPlaybackLedgerKey,
            requesterDeviceID: snapshot.requesterDeviceID, ownerToken: snapshot.ownerToken,
            operationGeneration: snapshot.operationGeneration)
    }

    private func storyPlaybackLedger(for snapshot: LibraryListenNextRequestSnapshot) -> ListenNextPlaybackLedger {
        storyPlaybackLedgerStore(for: snapshot)?.load()
            ?? ListenNextPlaybackLedger(requesterDeviceID: snapshot.requesterDeviceID,
                                        ownerToken: snapshot.ownerToken,
                                        operationGeneration: snapshot.operationGeneration)
    }

    private func storyPlaybackEntry(
        requestID: String
    ) -> (ListenNextPlaybackLedger.Entry, ListenNextPlaybackLedgerStore)? {
        guard let data = preferences.data(forKey: Self.listenNextPlaybackLedgerKey),
              let ledger = try? JSONDecoder().decode(ListenNextPlaybackLedger.self, from: data),
              ledger.requesterDeviceID == libraryDeviceID(),
              let entry = ledger.entries.first(where: { $0.requestID == requestID }) else { return nil }
        let store = ListenNextPlaybackLedgerStore(
            defaults: preferences, key: Self.listenNextPlaybackLedgerKey,
            requesterDeviceID: entry.requesterDeviceID, ownerToken: entry.ownerToken,
            operationGeneration: entry.operationGeneration)
        return (entry, store)
    }

    private func updateStoryRequest(_ snapshot: LibraryListenNextRequestSnapshot, phase: ListenNextPlaybackPhase) {
        guard let store = storyPlaybackLedgerStore(for: snapshot) else { return }
        var ledger = store.load()
        if phase == .cancelled { ledger.markCancelled(requestID: snapshot.requestID) }
        else { ledger.markFailed(requestID: snapshot.requestID) }
        try? store.save(ledger)
    }

    func queuePhase(for status: LibraryListenNextRequestSnapshot.Status) -> ListenNextPlaybackPhase {
        switch status {
        case .pending: .pending
        case .sent: .sent
        case .preparing: .preparing
        case .ready: .ready
        case .selected: .selected
        case .playing: .playing
        case .failed: .failed
        case .cancelled: .cancelled
        case .completed: .completed
        }
    }

    func storyRequestHoldEpoch() -> UInt64 {
        let epoch = playback?.listenNextHoldEpoch
            ?? (preferences.object(forKey: Self.listenNextPlaybackHoldKey) as? UInt64 ?? 0)
        return preferences.bool(forKey: Self.listenNextPlaybackHeldKey) ? epoch &- 1 : epoch
    }

    func verifiedStoryURL(_ snapshot: LibraryListenNextRequestSnapshot) async -> URL? {
        guard snapshot.requesterDeviceID == libraryDeviceID(),
              let identity = audioOfferIdentity(for: snapshot),
              let store = storyPlaybackLedgerStore(for: snapshot),
              let entry = store.load().entries.first(where: { $0.requestID == snapshot.requestID }),
              entry.storyID.rawValue == snapshot.storyID,
              entry.audioOfferIdentity == identity,
              entry.ownerToken == snapshot.ownerToken,
              entry.operationGeneration == snapshot.operationGeneration,
              entry.phase == .ready || entry.phase == .selected || entry.phase == .starting || entry.phase == .playing,
              let path = entry.mediaFilePath,
              let verified = await listenNextAudioURL(for: snapshot),
              verified.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path else { return nil }
        return verified
    }

    func audioOfferIdentity(
        for snapshot: LibraryListenNextRequestSnapshot
    ) -> ListenNextAudioOfferIdentity? {
        guard let offer = snapshot.audioOffer else { return nil }
        return ListenNextAudioOfferIdentity(
            audioRevisionID: offer.audioRevision.rawValue, contentHash: offer.contentHash,
            byteCount: offer.byteCount, mediaType: offer.mediaType,
            durationSeconds: offer.durationSeconds)
    }

    func audioRevision(for snapshot: LibraryListenNextRequestSnapshot) -> AudioRevision? {
        guard let offer = snapshot.audioOffer,
              let storyID = try? ItemID(rawValue: snapshot.storyID) else { return nil }
        return try? AudioRevision(
            itemID: storyID, revisionID: offer.audioRevision, durationSeconds: offer.durationSeconds,
            byteCount: offer.byteCount, contentHash: offer.contentHash, mediaType: offer.mediaType,
            createdAt: Timestamp(snapshot.createdAt), schemaVersion: 1)
    }

    private func larderContinuation(after anchorID: ItemID) -> ListenNextContinuation {
        let candidates = larderUnfilteredEpisodes(in: .playable).filter {
            $0.id != anchorID.rawValue && !$0.isAudiobook && !hiddenEpisodeIDs.contains($0.id)
                && $0.retiredAt == nil && !$0.isPlayed && canPlayEpisode($0)
        }
        return ListenNextContinuation(
            kind: .macReadyLarder, anchorID: anchorID,
            entryIDs: candidates.compactMap { try? ItemID(rawValue: $0.id) })
    }
}
