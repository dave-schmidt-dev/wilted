import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let mediaLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryMedia")

/// An automatic retry of a download that failed for a passing reason: attempt `attempt` of `attempts`.
struct LibraryMediaRetry: Equatable, Sendable {
    var attempt: Int
    var attempts: Int
}

/// How far the Mac has got with a request the phone sent, as the row says it.
enum LibraryMediaRequestStage: Equatable, Sendable {
    /// The Mac has not said anything yet.
    case sent
    /// The Mac read the request and has it in line behind earlier uploads.
    case queued
    /// The Mac is uploading the audio.
    case sending

    var text: String {
        switch self {
        case .sent: "Sent to Mac"
        case .queued: "Queued on Mac"
        case .sending: "Mac is sending"
        }
    }
}

/// What a Larder row shows and offers for one episode's audio.
enum LibraryMediaState: Equatable, Sendable {
    /// Not on the phone and not requested.
    case available
    /// The request intent is sent; the Mac has not published an offer yet, and `stage` says how far it
    /// has got. With `retry`, a download failed for a passing reason and the next attempt starts after a
    /// short wait.
    case requested(since: Date, retry: LibraryMediaRetry? = nil, stage: LibraryMediaRequestStage = .sent)
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
        case let .requested(since, _, _), let .downloading(_, _, since): since
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
        case .available: "Not downloaded"
        case let .requested(_, retry?, _): "Retrying (\(retry.attempt) of \(retry.attempts))"
        case let .requested(_, _, stage): "\(stage.text) · \(LibraryClockFormat.duration(elapsed))"
        case let .downloading(bytes, total, _):
            "Downloading \(Self.size(bytes)) of \(Self.size(total)) · \(LibraryClockFormat.duration(elapsed))\(Self.rateSuffix(bytes: bytes, total: total, elapsed: elapsed))"
        case .verifying: "Verifying"
        case .onPhone: "Downloaded"
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
///
/// The Mac reports each request's stage (`LibraryDeviceLink`), and the limit depends on the stage it
/// last reported: a request can wait a long time in line behind other uploads, so only silence is
/// short. Every limit restarts when the stage changes.
struct LibraryMediaTiming: Sendable {
    /// How often to look for the Mac's offer after sending the request.
    var pollInterval: Duration = .seconds(SyncCadence.tickInterval)
    /// How long the Mac may say nothing about a request before it is failed. The Mac reads requests
    /// at its next 30 s round, but while iCloud refuses it the Mac holds its rounds for up to
    /// `SyncCadence.backoffCap`, so a running Mac is given that hold plus two rounds.
    var offerTimeout: Duration = .seconds(SyncCadence.backoffCap + 2 * SyncCadence.tickInterval)
    /// How long a request the Mac has read may sit in line without its upload starting.
    var queuedTimeout: Duration = .seconds(30 * 60)
    /// How long an upload that started may go without the Mac answering.
    var sendingTimeout: Duration = .seconds(15 * 60)
    /// How long to wait for the offer to show once the Mac says it answered, before reading it directly.
    var answeredTimeout: Duration = .seconds(120)
    /// Longest a download may go without receiving bytes.
    var watchdog: Duration = MediaFetcher.defaultWatchdog
    /// The waits before each automatic retry of a download that failed for a passing reason.
    var retryDelays: [Duration] = MediaFetcher.defaultRetryDelays
    /// The waits before each new try at sending the request itself when iCloud refuses it for a passing
    /// reason (busy, rate-limited, offline, or the shared retry wait), so a tap during an iCloud hold is
    /// sent once the hold lifts instead of failing at once.
    var sendRetryDelays: [Duration] = [.seconds(10), .seconds(30), .seconds(60)]
    /// How a retry waits. Tests replace it so a retry costs no real time.
    var retrySleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// Identifies one request so a cancelled or replaced run can never write state for its successor.
struct LibraryMediaRun {
    let id = UUID()
    var task: Task<Void, Never>?
}

extension LibraryAppModel {
    /// The state shown for `entryID`.
    func mediaState(for entryID: ItemID) -> LibraryMediaState { media[backingEntryID(for: entryID)] ?? .available }

    /// True when a row may ask the Mac for audio: the Mac has linked this device and the check of the audio
    /// already on the phone has ended. Until then a row whose audio is not known yet offers no download and
    /// no Play, so it never asks the Mac again for audio the phone holds (W-INV-040).
    var canRequestAudio: Bool { deviceLinked && localStateLoaded }

    /// Routes a row action. Fire-and-forget: progress and outcome arrive through `media`.
    func performMediaAction(_ action: LibraryMediaAction, entryID: ItemID) {
        let entryID = backingEntryID(for: entryID)
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

    /// Deletes the cached audio. The Mac's copy is untouched. The row clears before the delete starts
    /// (W-INV-040), and the delete holds the entry's one media run, so no request or cache refresh touches
    /// the entry until it ends. A delete that fails puts the existing error on the row; a later cache
    /// refresh shows "On phone" again if the audio is still playable.
    func removeFromPhone(entryID: ItemID) async {
        guard mediaRuns[entryID] == nil else { return }
        let run = LibraryMediaRun()
        mediaRuns[entryID] = run
        defer { if isCurrent(entryID, run.id) { mediaRuns[entryID] = nil } }
        cancelTranscript(entryID: entryID)
        media[entryID] = nil
        do {
            try await mediaCache.remove(entryID: entryID)
            if isCurrent(entryID, run.id) { unacknowledgedMedia[entryID] = nil }
        } catch {
            setMedia(.failed("Could not remove the audio: \(error.localizedDescription)"), entryID, run.id)
        }
    }

    /// Waits for the request for `entryID` to finish. For tests.
    func waitForMedia(entryID: ItemID) async {
        await mediaRuns[entryID]?.task?.value
    }

    /// Marks entries already cached as "On phone", drops "On phone" for files that are gone, and
    /// retries acknowledgements that did not reach the Mac. Never touches a running request. The launch's
    /// local read passes `acknowledging: false`: an acknowledgement is network work, so it waits in the
    /// outbox for the sync round instead of holding up the Larder or a play (W-INV-040, W-INV-039).
    func refreshMediaFromCache(acknowledging: Bool = true) async {
        guard let context = await bindMediaOwner() else {
            guard !Task.isCancelled else { return }
            media = media.filter { $0.value != .onPhone }
            handoffState.player?.invalidateLoadedItem()
            return
        }
        // Audio that can never play again (no proof, or revoked) is deleted so Storage only
        // counts what the phone can use; requests, revocations and the loaded item are spared.
        let spared = Set(mediaRuns.keys).union(mediaRevocations)
            .union([handoffState.player?.item?.entryID].compactMap { $0 })
        let reclaimed = await mediaCache.reclaimUnplayableAudio(keeping: spared)
        if !reclaimed.isEmpty {
            mediaLog.notice("Deleted unplayable audio for \(reclaimed.count, privacy: .public) episodes")
        }
        let inventory = await mediaCache.cachedEntries()
        guard await mediaContextIsCurrent(context) else { return }
        var cached: [ItemID: CachedMedia] = [:]
        for (entryID, candidate) in inventory {
            guard await cachedPreparationIsCurrent(candidate, entryID: entryID, context: context),
                  await mediaContextIsCurrent(context, entryID: entryID) else { continue }
            cached[entryID] = candidate
        }
        guard await mediaContextIsCurrent(context) else { return }
        cached = cached.filter { entryID, _ in !mediaRevocations.contains(entryID) && queued.contains { $0.id == entryID } }
        for (entryID, state) in media where state == .onPhone && cached[entryID] == nil && mediaRuns[entryID] == nil {
            media[entryID] = nil
        }
        for entryID in transcripts.keys where cached[entryID]?.revisionID != transcripts[entryID]?.revisionID {
            transcripts[entryID] = nil
        }
        for entryID in cached.keys where mediaRuns[entryID] == nil {
            switch media[entryID] {
            case .none, .some(.available), .some(.failed): media[entryID] = .onPhone
            default: break
            }
        }
        if acknowledging { await sendPendingMediaAcknowledgements() }
    }

    /// The account changed: audio belongs to the previous account's library.
    func discardMediaAfterAccountChange() async {
        try? await mediaCache.bindOwner(ownerToken: nil, libraryScope: Self.mediaLibraryScope, held: true)
        handoffState.player?.invalidateLoadedItem()
        for run in mediaRuns.values { run.task?.cancel() }
        mediaRuns = [:]
        mediaRevocations = []
        unacknowledgedMedia = [:]
        for run in transcriptRuns.values { run.task?.cancel() }
        transcriptRuns = [:]
        transcriptRetried = [:]
        transcripts = [:]
        media = [:]
        for entryID in await mediaCache.storedAudioByteCounts().keys {
            await removeFromPhone(entryID: entryID)
        }
    }

    // MARK: - Request flow

    private func runMediaRequest(_ entryID: ItemID, runID: UUID) async {
        defer { if isCurrent(entryID, runID) { mediaRuns[entryID] = nil } }
        do {
            await loadLocalState()
            guard isCurrent(entryID, runID), let context = await mediaContext(live: true),
                  await mediaContextIsCurrent(context, entryID: entryID, live: true) else {
                setMedia(.failed("The saved library account is not verified for downloading."), entryID, runID)
                return
            }
            let intent = try LibraryIntent.requestMedia(entryID: entryID, deviceID: deviceID, createdAt: now())
            try await sendRequest(intent, entryID: entryID, runID: runID)
            let offer: LibraryMediaOffer
            switch try await awaitAnswer(for: entryID, intentID: intent.id, runID: runID, context: context) {
            case let .offer(found): offer = found
            case .macNotAnswering:
                let entry = entryID.rawValue
                mediaLog.notice("No answer from the Mac for \(entry, privacy: .public)")
                setMedia(.failed(Self.text(for: MediaFetchFailure.macNotAnswering)), entryID, runID)
                return
            case let .failed(reason):
                let entry = entryID.rawValue
                mediaLog.notice("The Mac could not send \(entry, privacy: .public)")
                setMedia(.failed(reason), entryID, runID)
                return
            }
            guard isCurrent(entryID, runID), await mediaContextIsCurrent(context, entryID: entryID, live: true) else { return }
            guard offer.state == .ready, offer.isPrepared else {
                setNotPrepared(entryID, runID)
                return
            }
            guard let admission = await mediaCache.admission(entryID: entryID, ownerToken: context.ownerToken,
                libraryScope: Self.mediaLibraryScope, transportGeneration: context.generation),
                isCurrent(entryID, runID), await mediaContextIsCurrent(context, entryID: entryID, live: true) else { return }
            let outcome = try await download(offer, runID: runID, admission: admission)
            guard await mediaCache.permits(admission, for: offer),
                  await mediaContextIsCurrent(context, entryID: entryID, live: true), isCurrent(entryID, runID) else {
                setMedia(.failed("The saved library account changed during downloading."), entryID, runID)
                return
            }
            try Task.checkCancellation()
            switch outcome {
            case .cached:
                setMedia(.onPhone, entryID, runID)
                phoneStats.recordDownload(bytes: offer.byteCount)
                if let revisionID = offer.revisionID, let intent = try? LibraryIntent.mediaCached(
                    entryID: entryID, revisionID: revisionID, deviceID: deviceID, createdAt: now()) {
                    unacknowledgedMedia[entryID] = intent
                    await sendPendingMediaAcknowledgements()
                }
                startTranscriptLoad(entryID: entryID, fetchOnMiss: true)
            case .notReady: setNotPrepared(entryID, runID)
            case let .failed(reason): setMedia(.failed(Self.text(for: reason)), entryID, runID)
            }
        } catch is CancellationError {
            return
        } catch {
            let entry = entryID.rawValue, detail = MediaFetchErrorClassifier.logDescription(error)
            mediaLog.error("Media request for \(entry, privacy: .public) failed: \(detail, privacy: .public)")
            setMedia(.failed(Self.mediaText(for: error)), entryID, runID)
        }
    }

    /// One read of the offers: the Mac's answer for `entryID`, or nil when there is none yet or the read
    /// failed, so the caller keeps waiting.
    func readOffer(for entryID: ItemID, context: LibraryMediaContext) async throws -> LibraryMediaOffer? {
        guard let offers = try? await transport.mediaOffers() else { return nil }
        // A request's notReady response settles this run after durable revocation; it must
        // not cancel its own result while applying the response.
        guard await mediaContextIsCurrent(context, entryID: entryID, live: true) else { throw LibraryTransportError.superseded }
        guard let offer = offers.first(where: { $0.entryID == entryID }), offer.state != .available else { return nil }
        if offer.state == .notReady {
            try await mediaCache.revokePreparation(entryID: entryID)
        } else if offer.isPrepared {
            let old = await mediaCache.cachedEntries()[entryID]?.preparation?.offer
            if let old, !Self.samePreparedIdentity(old, offer) { try await mediaCache.revokePreparation(entryID: entryID) }
        }
        guard await mediaContextIsCurrent(context, entryID: entryID, live: true) else { throw LibraryTransportError.superseded }
        return offer
    }

    /// Runs the fetcher and mirrors its states and automatic retries into `media` in the order they happened.
    private func download(_ offer: LibraryMediaOffer, runID: UUID, admission: MediaCacheAdmission) async throws -> MediaFetchOutcome {
        let (events, continuation) = AsyncStream<MediaFetchEvent>.makeStream()
        let entryID = offer.entryID
        let mirror = Task { @MainActor [weak self] in
            for await event in events {
                switch event {
                case let .transfer(state): self?.applyTransfer(state, total: offer.byteCount, entryID: entryID, runID: runID)
                case let .retry(retry): self?.applyRetry(retry, entryID: entryID, runID: runID)
                }
            }
        }
        let fetcher = MediaFetcher(cache: mediaCache, watchdog: mediaTiming.watchdog,
                                   retryDelays: mediaTiming.retryDelays, sleep: mediaTiming.retrySleep)
        do {
            let outcome = try await fetcher.fetch(offer, from: transport, admission: admission,
                onState: { continuation.yield(.transfer($0)) }, onRetry: { continuation.yield(.retry($0)) })
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

    /// Sends the request, trying again after each of `sendRetryDelays` while iCloud refuses it for a passing
    /// reason. Every try sends the same intent id, so a Mac that read an earlier try sees one request. A wait
    /// is at least iCloud's own retry time (capped at two minutes), and the row shows the try it is on.
    private func sendRequest(_ intent: LibraryIntent, entryID: ItemID, runID: UUID) async throws {
        let delays = mediaTiming.sendRetryDelays
        var attempt = 1
        while true {
            do {
                try await transport.send(intent: intent)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt <= delays.count, MediaFetchErrorClassifier.isTransient(error) else { throw error }
                var delay = delays[attempt - 1]
                if let throttled = error as? TransportThrottled {
                    delay = max(delay, .seconds(min(max(throttled.retryAt.timeIntervalSince(now()), 0), 120)))
                }
                attempt += 1
                let entry = entryID.rawValue, detail = MediaFetchErrorClassifier.logDescription(error)
                mediaLog.notice("Request for \(entry, privacy: .public) not sent; try \(attempt, privacy: .public) in \(delay, privacy: .public): \(detail, privacy: .public)")
                setMedia(.requested(since: now(), retry: LibraryMediaRetry(attempt: attempt, attempts: delays.count + 1)), entryID, runID)
                try await mediaTiming.retrySleep(delay)
                try Task.checkCancellation()
                guard isCurrent(entryID, runID) else { throw CancellationError() }
            }
        }
    }

    /// The download failed for a passing reason and the fetcher waits before trying again.
    private func applyRetry(_ retry: MediaFetchRetry, entryID: ItemID, runID: UUID) {
        setMedia(.requested(since: now(), retry: LibraryMediaRetry(attempt: retry.attempt, attempts: retry.attempts)), entryID, runID)
    }

    /// Sends each saved acknowledgement with its own intent id, so a retry, or a replay after a relaunch,
    /// is the same request to the Mac. An entry that is not current now is skipped and kept.
    private func sendPendingMediaAcknowledgements() async {
        guard let context = await mediaContext(live: true) else { return }
        for (entryID, intent) in unacknowledgedMedia {
            guard await mediaContextIsCurrent(context, entryID: entryID, live: true) else {
                guard await mediaContextIsCurrent(context, live: true) else { return }
                continue
            }
            if (try? await transport.send(intent: intent)) != nil,
               await mediaContextIsCurrent(context, entryID: entryID, live: true), unacknowledgedMedia[entryID]?.id == intent.id {
                unacknowledgedMedia[entryID] = nil
            }
        }
    }

    func isCurrent(_ entryID: ItemID, _ runID: UUID) -> Bool { mediaRuns[entryID]?.id == runID }

    /// The Mac answered that it has no ready audio. The Larder lists only what the Mac reports ready, so
    /// the row leaves at once instead of waiting for the next refresh to withdraw it, and returns when
    /// a later refresh sees the Mac offer it again.
    private func setNotPrepared(_ entryID: ItemID, _ runID: UUID) {
        guard isCurrent(entryID, runID) else { return }
        media[entryID] = .notPrepared
        if handoffState.player?.item?.entryID == entryID { handoffState.player?.invalidateLoadedItem() }
        dropOffer(entryID)
    }

    func setMedia(_ state: LibraryMediaState, _ entryID: ItemID, _ runID: UUID) {
        guard isCurrent(entryID, runID) else { return }
        media[entryID] = state
    }

    // MARK: - Wording

    /// One plain sentence per typed cause. A reason's payload is never shown: the fetcher keeps the
    /// transport's own text in the log.
    static func text(for reason: MediaFailureReason) -> String {
        switch reason {
        case .timedOut: "The download stalled. Try again."
        case .byteCountMismatch: "The file was the wrong size."
        case .hashMismatch: text(for: MediaFetchFailure.mismatch)
        case .deliveryFailed: text(for: reason.fetchFailure ?? .other)
        case .cacheFailed: "The audio could not be saved."
        }
    }

    static func text(for failure: MediaFetchFailure) -> String {
        switch failure {
        case .offline: "Could not reach iCloud. Check the connection and try again."
        case .macNotAnswering: "The Mac did not send this episode. Open Wilted on the Mac and try again."
        case .mismatch: "The file did not match the Mac's copy."
        case .tooLarge: "The episode is too large to download."
        case .other: "The download failed. Try again."
        }
    }

    /// The row's sentence for an error that ended a media request outside the fetch, such as the
    /// request intent failing to send. Never the error's own text.
    static func mediaText(for error: Error) -> String {
        if case LibraryTransportError.superseded = error { return "iCloud account changed." }
        return text(for: MediaFetchErrorClassifier.failure(for: error))
    }

    static func text(for error: Error) -> String {
        switch error {
        case LibraryTransportError.transport(let text): text
        case LibraryTransportError.superseded: "iCloud account changed."
        default: error.localizedDescription
        }
    }
}

/// What the fetcher reports, in the order it happened: a transfer step or an automatic retry.
private enum MediaFetchEvent: Sendable {
    case transfer(MediaTransferState)
    case retry(MediaFetchRetry)
}
