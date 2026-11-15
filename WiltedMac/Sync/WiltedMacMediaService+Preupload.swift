import Foundation
import OSLog
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

private let preuploadLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacMedia")

/// A pre-upload target held by the Mac media service.
struct WiltedMacPreuploadTarget: Sendable, Equatable {
    var entryID: ItemID
    var audio: WiltedMacReadyAudio
}

extension WiltedMacMediaService {
    /// Recomputes `preuploadTargets` from the prepared queued entries in queue order, and forgets the
    /// delivered mark of an entry that has left the Larder. A mark outlives a loss of prepared audio, so
    /// audio a device acknowledged is not uploaded again while its entry stays on the Larder.
    func updatePreuploadTargets() async throws {
        guard preuploadLimit > 0 else {
            preuploadTargets = []
            return
        }
        let queued = try await source.preparedQueued()
        let larder = Set(queued.larderIDs.map(\.rawValue))
        delivered = delivered.filter { larder.contains($0.key) }
        preuploadSkippedUntil = preuploadSkippedUntil.filter { larder.contains($0.key.entryID) }
        let eligible = queued.entries.filter { entryID, audio in
            audio.byteCount <= Self.maximumByteCount
                && Self.fileSize(audio.fileURL) == audio.byteCount
                && delivered[entryID.rawValue] != audio.revisionID.rawValue
        }
        let targets = eligible.prefix(preuploadLimit).map { WiltedMacPreuploadTarget(entryID: $0.0, audio: $0.1) }
        // A round every 30 s must not write a line every 30 s: only a changed list is logged.
        if targets != preuploadTargets {
            preuploadLog.notice("Pre-upload targets changed: \(targets.count, privacy: .public) entries")
        }
        preuploadTargets = targets
    }

    /// Kicks the pump task after a successful reconcile, unless it is already running, paused or stopped.
    func kickPreuploadPump() {
        guard preuploadLimit > 0 else { return }
        guard !preuploadStopped else { return }
        guard preuploadTask == nil else { return }
        guard !isPreuploadPaused else { return }
        preuploadTask = Task {
            await self.runPreuploadPump()
        }
    }

    /// Clears the stopped mark `drainEndingThrottleWaits()` sets, so the next successful reconcile
    /// kicks the pump again. Starts no upload itself. Call it only after that shutdown has finished:
    /// while the mark is set, a step chained before shutdown starts no upload.
    func resumePreupload() {
        guard preuploadStopped else { return }
        preuploadStopped = false
        if preuploadLimit > 0 {
            preuploadLog.notice("Pre-upload resumed: sync started again")
        }
    }

    /// True while the pump is paused for a retry delay or quota wait. A pure read: the pump itself
    /// clears the mark when its wait ends.
    var isPreuploadPaused: Bool {
        guard let pausedUntil = preuploadPausedUntil else { return false }
        return now() < pausedUntil
    }

    /// Uploads missing pre-upload targets one at a time, re-reading targets after each step.
    func runPreuploadPump() async {
        defer { preuploadTask = nil }
        // Targets a step left unpublished without an error: the audio changed or went away after the
        // reconcile that listed them. This run leaves them alone, so it cannot spin on one; the next
        // reconcile re-reads the Larder and kicks the pump again.
        var stale: Set<AssetKey> = []
        while !preuploadStopped {
            guard let target = nextPreuploadTarget(excluding: stale) else { return }
            do {
                try await chainedThrowing {
                    try await self.performPreupload(target)
                }.value
                preuploadConsecutiveTransients = 0
                if preuploadStopped { return }
                if published[target.entryID.rawValue] != target.audio.revisionID.rawValue {
                    stale.insert(AssetKey(entryID: target.entryID.rawValue, revisionID: target.audio.revisionID.rawValue))
                }
            } catch {
                if preuploadStopped { return }
                if error is WiltedMacLibraryAccountError || (error as? LibraryTransportError) == .superseded {
                    return
                }
                if isQuotaExceeded(error) {
                    preuploadLog.error("Pre-upload paused for 6 hours: iCloud quota exceeded: \(String(describing: error), privacy: .public)")
                    let duration: Duration = .seconds(6 * 3600)
                    preuploadPausedUntil = now().addingTimeInterval(6 * 3600)
                    let waited = await waitPreupload(duration)
                    preuploadPausedUntil = nil
                    if !waited || preuploadStopped { return }
                    continue
                }
                if error is TransportThrottled || MediaFetchErrorClassifier.isTransient(error) {
                    let duration: Duration
                    let resumeAt: Date
                    if let throttled = error as? TransportThrottled {
                        let seconds = max(throttled.retryAt.timeIntervalSince(now()), 1)
                        duration = .seconds(seconds)
                        resumeAt = throttled.retryAt
                    } else {
                        preuploadConsecutiveTransients += 1
                        let exponent = min(preuploadConsecutiveTransients - 1, 10)
                        let seconds = min(5 * (1 << exponent), 15 * 60)
                        duration = .seconds(seconds)
                        resumeAt = now().addingTimeInterval(Double(seconds))
                    }
                    preuploadPausedUntil = resumeAt
                    let waited = await waitPreupload(duration)
                    preuploadPausedUntil = nil
                    if !waited || preuploadStopped { return }
                    continue
                }
                let key = AssetKey(entryID: target.entryID.rawValue, revisionID: target.audio.revisionID.rawValue)
                preuploadSkippedUntil[key] = now().addingTimeInterval(6 * 3600)
                continue
            }
        }
    }

    /// Finds the first pre-upload target whose revision is not currently published on the transport,
    /// not skipped, and not in `excluding`.
    func nextPreuploadTarget(excluding: Set<AssetKey> = []) -> WiltedMacPreuploadTarget? {
        guard let targets = preuploadTargets else { return nil }
        let currentTime = now()
        for target in targets {
            let key = AssetKey(entryID: target.entryID.rawValue, revisionID: target.audio.revisionID.rawValue)
            if published[target.entryID.rawValue] == target.audio.revisionID.rawValue {
                continue
            }
            if let skipUntil = preuploadSkippedUntil[key], currentTime < skipUntil {
                continue
            }
            if excluding.contains(key) { continue }
            return target
        }
        return nil
    }

    /// Re-reads the ready audio for a target and uploads it without requesters.
    func performPreupload(_ target: WiltedMacPreuploadTarget) async throws {
        // A step chained before shutdown began must not start an upload after it.
        guard !preuploadStopped else { return }
        guard let ready = try await source.readyAudio(for: target.entryID) else { return }
        guard ready.revisionID == target.audio.revisionID else { return }
        guard ready.byteCount <= Self.maximumByteCount else { return }
        guard Self.fileSize(ready.fileURL) == ready.byteCount else { return }
        try await uploadAndBook(entryID: target.entryID, ready: ready, requester: nil)
    }

    /// Sleeps off the chain through the injected sleep closure. False when cancelled.
    private func waitPreupload(_ duration: Duration) async -> Bool {
        let sleep = self.sleep
        let waitTask = Task { try await sleep(duration) }
        preuploadWaitTask = waitTask
        defer { preuploadWaitTask = nil }
        if preuploadStopped { waitTask.cancel() }
        do {
            try await waitTask.value
            return !preuploadStopped
        } catch {
            return false
        }
    }

    /// Awaits the active pre-upload pump task, if any, until it settles.
    func waitForPreuploadPump() async {
        while let task = preuploadTask {
            await task.value
        }
    }

    /// Uploads audio and records the published offer and asset record, shared between `serve` and pre-upload.
    @discardableResult
    func uploadAndBook(
        entryID: ItemID,
        ready: WiltedMacReadyAudio,
        requester: String? = nil,
        onUploading: (@Sendable () async -> Void)? = nil
    ) async throws -> Bool {
        let offer = try LibraryMediaOffer(
            entryID: entryID, revisionID: ready.revisionID, contentHash: ready.contentHash,
            byteCount: ready.byteCount, mediaType: ready.mediaType, durationSeconds: ready.durationSeconds,
            preparation: ready.preparation
        )
        let key = AssetKey(entryID: entryID.rawValue, revisionID: ready.revisionID.rawValue)
        try? await seedOffers()
        if published[entryID.rawValue] == key.revisionID, offered[entryID.rawValue] == offer,
           var existing = records[key] {
            if let requester {
                existing.requesters.insert(requester)
                existing.acked.remove(requester)
                existing.touchedAt = now()
                records[key] = existing
                try persist()
                await publishTranscript(for: entryID, revisionID: ready.revisionID)
                preuploadLog.notice("Audio for \(entryID.rawValue, privacy: .public) is already offered; added a requester")
            }
            return false
        }
        await onUploading?()
        if requester == nil {
            preuploadLog.notice("Uploading audio for \(entryID.rawValue, privacy: .public)")
        } else {
            preuploadLog.notice("Uploading \(ready.byteCount, privacy: .public) bytes of audio for \(entryID.rawValue, privacy: .public)")
        }
        let started = Date()
        try await transport.publishMedia(offer: offer, fileURL: ready.fileURL)
        if requester == nil {
            preuploadLog.notice("Pre-uploaded audio for \(entryID.rawValue, privacy: .public)")
        } else {
            preuploadLog.notice("Uploaded audio for \(entryID.rawValue, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public) s")
        }
        var record = records[key] ?? AssetRecord(key: key, requesters: [], acked: [], touchedAt: now())
        if let requester {
            record.requesters.insert(requester)
            record.acked.remove(requester)
        }
        record.touchedAt = now()
        records[key] = record
        published[entryID.rawValue] = key.revisionID
        offered[entryID.rawValue] = offer
        try persist()
        await publishTranscript(for: entryID, revisionID: ready.revisionID)
        lastFailure = nil
        return true
    }
}

private func isQuotaExceeded(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == "CKErrorDomain" && nsError.code == 25 {
        return true
    }
    // The shape the iCloud adapter throws: `CKError.Code.quotaExceeded` is 25.
    if case .cloudKit(code: 25, _) = error as? CloudKitSyncError { return true }
    return false
}
