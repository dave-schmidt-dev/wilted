import Foundation
import WiltedDomain
import WiltedLibrary

/// What a Larder row shows and offers for one episode's audio.
enum LibraryMediaState: Equatable, Sendable {
    /// Not on the phone and not requested.
    case available
    /// The request intent is sent; the Mac has not published an offer yet.
    case requested(since: Date)
    case downloading(bytes: Int64, total: Int64, since: Date)
    case verifying
    /// Verified and cached on this phone.
    case onPhone
    case failed(String)
    /// The Mac has no ready audio for this episode.
    case notPrepared

    /// True while a request is running and can be cancelled.
    var isInFlight: Bool {
        switch self {
        case .requested, .downloading, .verifying: true
        default: false
        }
    }

    /// The moment the transfer began, for the elapsed-time readout.
    var startedAt: Date? {
        switch self {
        case let .requested(since), let .downloading(_, _, since): since
        default: nil
        }
    }

    /// Fraction received, when the total is known.
    var fraction: Double? {
        guard case let .downloading(bytes, total, _) = self, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total)))
    }

    /// Status line without color or icon, so state never depends on either. `elapsed` is seconds since start.
    func statusText(elapsed: TimeInterval = 0) -> String {
        switch self {
        case .available: "Not on phone"
        case .requested: "Requested, waiting for Mac · \(LibraryClockFormat.duration(elapsed))"
        case let .downloading(bytes, total, _):
            "Downloading \(Self.size(bytes)) of \(Self.size(total)) · \(LibraryClockFormat.duration(elapsed))\(Self.rateSuffix(bytes: bytes, total: total, elapsed: elapsed))"
        case .verifying: "Verifying"
        case .onPhone: "On phone"
        case let .failed(reason): "Failed: \(reason)"
        case .notPrepared: "Not prepared on Mac"
        }
    }

    /// Average rate and estimated time left since the transfer began; empty until there is enough
    /// data to mean something.
    static func rateSuffix(bytes: Int64, total: Int64, elapsed: TimeInterval) -> String {
        guard bytes > 0, elapsed >= 2 else { return "" }
        let rate = Double(bytes) / elapsed
        var text = " · \(size(Int64(rate)))/s"
        if total > bytes { text += " · \(LibraryClockFormat.duration(Double(total - bytes) / rate)) left" }
        return text
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// What a person can do to a row's audio.
enum LibraryMediaAction: Equatable, Sendable {
    /// Get audio, Retry after a failure, or Check again after "not prepared".
    case request
    case cancel
    case removeFromPhone
}

/// Waiting limits for one request. The download watchdog is `MediaFetcher`'s.
struct LibraryMediaTiming: Sendable {
    /// How often to look for the Mac's offer after sending the request.
    var pollInterval: Duration = .seconds(SyncCadence.tickInterval)
    /// How long to wait for the Mac to answer before failing. The Mac polls every 30 s while idle.
    var offerTimeout: Duration = .seconds(180)
    /// Longest a download may go without receiving bytes.
    var watchdog: Duration = MediaFetcher.defaultWatchdog
}

/// Identifies one request so a cancelled or replaced run can never write state for its successor.
struct LibraryMediaRun {
    let id = UUID()
    var task: Task<Void, Never>?
}

extension LibraryAppModel {
    /// The state shown for `entryID`.
    func mediaState(for entryID: ItemID) -> LibraryMediaState { media[entryID] ?? .available }

    /// Routes a row action. Fire-and-forget: progress and outcome arrive through `media`.
    func performMediaAction(_ action: LibraryMediaAction, entryID: ItemID) {
        switch action {
        case .request: startMediaRequest(entryID: entryID)
        case .cancel: cancelMediaRequest(entryID: entryID)
        case .removeFromPhone: Task { await removeFromPhone(entryID: entryID) }
        }
    }

    /// Asks the Mac for the episode's audio, then downloads, verifies and caches it. Does nothing
    /// while a request is already running or the audio is already on the phone.
    func startMediaRequest(entryID: ItemID) {
        guard mediaRuns[entryID] == nil, mediaState(for: entryID) != .onPhone else { return }
        var run = LibraryMediaRun()
        let runID = run.id
        media[entryID] = .requested(since: now())
        run.task = Task { [weak self] in
            await self?.runMediaRequest(entryID, runID: runID)
        }
        mediaRuns[entryID] = run
    }

    /// Stops a running request and returns the row to "Get audio".
    func cancelMediaRequest(entryID: ItemID) {
        guard let run = mediaRuns.removeValue(forKey: entryID) else { return }
        run.task?.cancel()
        media[entryID] = nil
    }

    /// Deletes the cached audio. The Mac's copy is untouched.
    func removeFromPhone(entryID: ItemID) async {
        guard mediaRuns[entryID] == nil else { return }
        do {
            cancelTranscript(entryID: entryID)
            try await mediaCache.remove(entryID: entryID)
            unacknowledgedMedia[entryID] = nil
            media[entryID] = nil
        } catch {
            media[entryID] = .failed("Could not remove the audio: \(error.localizedDescription)")
        }
    }

    /// Waits for the request for `entryID` to finish. For tests.
    func waitForMedia(entryID: ItemID) async {
        await mediaRuns[entryID]?.task?.value
    }

    /// Marks entries already cached as "On phone", drops "On phone" for files that are gone, and
    /// retries acknowledgements that did not reach the Mac. Never touches a running request.
    func refreshMediaFromCache() async {
        let cached = await mediaCache.cachedEntries()
        for (entryID, state) in media where state == .onPhone && cached[entryID] == nil && mediaRuns[entryID] == nil {
            media[entryID] = nil
        }
        for entryID in transcripts.keys where cached[entryID]?.revisionID != transcripts[entryID]?.revisionID {
            transcripts[entryID] = nil
        }
        for entryID in cached.keys where mediaRuns[entryID] == nil {
            switch media[entryID] {
            case .none, .some(.available), .some(.notPrepared), .some(.failed): media[entryID] = .onPhone
            default: break
            }
        }
        await sendPendingMediaAcknowledgements()
    }

    /// The account changed: audio belongs to the previous account's library.
    func discardMediaAfterAccountChange() async {
        for run in mediaRuns.values { run.task?.cancel() }
        mediaRuns = [:]
        unacknowledgedMedia = [:]
        for run in transcriptRuns.values { run.task?.cancel() }
        transcriptRuns = [:]
        transcriptRetried = [:]
        transcripts = [:]
        for entryID in await mediaCache.cachedEntries().keys { try? await mediaCache.remove(entryID: entryID) }
        media = [:]
    }

    // MARK: - Request flow

    private func runMediaRequest(_ entryID: ItemID, runID: UUID) async {
        defer { if isCurrent(entryID, runID) { mediaRuns[entryID] = nil } }
        do {
            let intent = try LibraryIntent.requestMedia(entryID: entryID, deviceID: deviceID, createdAt: now())
            try await transport.send(intent: intent)
            guard let offer = try await awaitOffer(for: entryID, runID: runID) else {
                setMedia(.failed("The Mac has not answered. Check that Wilted is running on it."), entryID, runID)
                return
            }
            guard offer.state == .ready else {
                setNotPrepared(entryID, runID)
                return
            }
            let outcome = try await download(offer, runID: runID)
            try Task.checkCancellation()
            switch outcome {
            case .cached:
                setMedia(.onPhone, entryID, runID)
                phoneStats.recordDownload(bytes: offer.byteCount)
                if let revisionID = offer.revisionID {
                    unacknowledgedMedia[entryID] = revisionID
                    await sendPendingMediaAcknowledgements()
                }
                startTranscriptLoad(entryID: entryID, fetchOnMiss: true)
            case .notReady: setNotPrepared(entryID, runID)
            case let .failed(reason): setMedia(.failed(Self.text(for: reason)), entryID, runID)
            }
        } catch is CancellationError {
            return
        } catch {
            setMedia(.failed(Self.text(for: error)), entryID, runID)
        }
    }

    /// Waits for the Mac's answer to the request until a `ready` (or `notReady`) offer for `entryID`
    /// appears, `offerTimeout` passes (nil), or the request is cancelled. An `available` offer is the
    /// Mac's standing statement that the audio is prepared, not an answer, so it keeps waiting for the
    /// upload. A failing read is retried until the timeout rather than ending the request.
    ///
    /// While the sync tick runs, its rounds read the offers (with the playback records, every round) and this
    /// only looks at what they found, so a request costs no reads of its own. Without a tick (the app is
    /// not in front) it reads the offers itself every `pollInterval`, which defaults to the tick interval.
    private func awaitOffer(for entryID: ItemID, runID: UUID) async throws -> LibraryMediaOffer? {
        let deadline = ContinuousClock.now.advanced(by: mediaTiming.offerTimeout)
        let requestedAt = now()
        while true {
            try Task.checkCancellation()
            if tickState.tick != nil {
                if let readAt = tickState.offersReadAt, readAt >= requestedAt,
                   let offer = tickState.offers[entryID], offer.state != .available { return offer }
            } else if let offers = try? await transport.mediaOffers(), let offer = offers.first(where: { $0.entryID == entryID }), offer.state != .available {
                return offer
            }
            if ContinuousClock.now >= deadline { return nil }
            // Looking at the tick's findings costs nothing, so that check is quick.
            try await Task.sleep(for: tickState.tick != nil ? min(mediaTiming.pollInterval, .milliseconds(500)) : mediaTiming.pollInterval)
        }
    }

    /// Runs the fetcher and mirrors its states into `media` in the order they happened.
    private func download(_ offer: LibraryMediaOffer, runID: UUID) async throws -> MediaFetchOutcome {
        let (states, continuation) = AsyncStream<MediaTransferState>.makeStream()
        let entryID = offer.entryID
        let mirror = Task { @MainActor [weak self] in
            for await state in states { self?.applyTransfer(state, total: offer.byteCount, entryID: entryID, runID: runID) }
        }
        let fetcher = MediaFetcher(cache: mediaCache, watchdog: mediaTiming.watchdog)
        do {
            let outcome = try await fetcher.fetch(offer, from: transport) { continuation.yield($0) }
            continuation.finish()
            await mirror.value
            return outcome
        } catch {
            continuation.finish()
            await mirror.value
            throw error
        }
    }

    private func applyTransfer(_ state: MediaTransferState, total: Int64, entryID: ItemID, runID: UUID) {
        // Elapsed time counts the download only, not the wait for the Mac's offer.
        var started = now()
        if case let .downloading(_, _, since) = media[entryID] ?? .available { started = since }
        switch state {
        case .requested: break
        case .awaiting: setMedia(.downloading(bytes: 0, total: total, since: started), entryID, runID)
        case let .downloading(bytes, total): setMedia(.downloading(bytes: bytes, total: total, since: started), entryID, runID)
        case .verifying: setMedia(.verifying, entryID, runID)
        case .cached, .failed, .notReady: break // the final state is set from the fetch outcome
        }
    }

    private func sendPendingMediaAcknowledgements() async {
        for (entryID, revisionID) in unacknowledgedMedia {
            guard let intent = try? LibraryIntent.mediaCached(
                entryID: entryID, revisionID: revisionID, deviceID: deviceID, createdAt: now()) else { continue }
            if (try? await transport.send(intent: intent)) != nil, unacknowledgedMedia[entryID] == revisionID {
                unacknowledgedMedia[entryID] = nil
            }
        }
    }

    private func isCurrent(_ entryID: ItemID, _ runID: UUID) -> Bool { mediaRuns[entryID]?.id == runID }

    /// The Mac answered that it has no ready audio. The Larder lists only what the Mac reports ready, so
    /// the row leaves at once instead of waiting for the next refresh to withdraw it, and returns when
    /// a later refresh sees the Mac offer it again.
    private func setNotPrepared(_ entryID: ItemID, _ runID: UUID) {
        guard isCurrent(entryID, runID) else { return }
        media[entryID] = .notPrepared
        dropOffer(entryID)
    }

    private func setMedia(_ state: LibraryMediaState, _ entryID: ItemID, _ runID: UUID) {
        guard isCurrent(entryID, runID) else { return }
        media[entryID] = state
    }

    // MARK: - Wording

    static func text(for reason: MediaFailureReason) -> String {
        switch reason {
        case .timedOut: "The download stalled."
        case .byteCountMismatch: "The file was the wrong size."
        case .hashMismatch: "The file did not match the Mac's copy."
        case let .deliveryFailed(detail): "The download failed. \(detail)"
        case let .cacheFailed(detail): "The audio could not be saved. \(detail)"
        }
    }

    static func text(for error: Error) -> String {
        switch error {
        case LibraryTransportError.transport(let text): text
        case LibraryTransportError.superseded: "iCloud account changed."
        default: error.localizedDescription
        }
    }
}
