import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let jobLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryMediaJob")

/// What one pass of a media job did.
private enum MediaJobStep {
    /// The job is settled (cached, failed for a terminal cause, dropped or cancelled): stop.
    case finished
    /// Go round again at once.
    case again
    /// A passing cause: the job stays pending and tries again at `until`.
    case wait(until: Date, onMac: Bool)
}

/// A media request as a durable job: it is saved before it starts, a passing cause (iCloud busy,
/// rate-limited or offline, the Mac asleep or silent) keeps it pending with a visible retry time and the
/// same intent id across relaunch, and only a terminal cause ends it: not prepared, too large, or the
/// same verification mismatch twice. The person can always cancel (D8).
extension LibraryAppModel {
    /// The store persisting active media jobs.
    var mediaJobStore: LibraryMediaJobStore {
        if let url = mediaTiming.jobStoreURL { return LibraryMediaJobStore(url: url) }
        if let url = outboxState.outbox.url {
            return LibraryMediaJobStore(url: url.deletingLastPathComponent().appendingPathComponent("media-jobs.json"))
        }
        return LibraryMediaJobStore(url: nil)
    }

    /// Wording for a job waiting for the Mac, which has not answered.
    func macWaitNotice(checkingAt due: Date) -> String {
        "Waiting for the Mac, checking again at \(clockFormat.clock(due))"
    }

    /// Asks the Mac for the episode's audio, then downloads, verifies and caches it, as a durable job.
    /// Does nothing while a request is already running or the audio is already on the phone.
    func startMediaRequest(entryID: ItemID) {
        guard mediaRuns[entryID] == nil, mediaState(for: entryID) != .onPhone else { return }
        guard !accountQuarantined, !mediaRevocations.contains(entryID) else { return }
        launchMediaJob(LibraryMediaJob(entryID: entryID, intentID: UUID().uuidString, createdAt: now()), persisting: true)
    }

    /// Saves `job` when asked, shows its row and starts its run.
    func launchMediaJob(_ job: LibraryMediaJob, persisting: Bool) {
        var run = LibraryMediaRun()
        let runID = run.id
        if persisting { mediaJobStore.saveJob(job, ownerToken: outboxState.ownerToken) }
        media[job.entryID] = waitingRow(job, until: job.nextAttempt) ?? .requested(since: job.requestedSince, stage: job.stage.requestStage)
        run.task = Task { [weak self] in await self?.runMediaJob(job, runID: runID) }
        mediaRuns[job.entryID] = run
    }

    /// Brings back the jobs a relaunch interrupted. Called once from the launch's local read; a job whose
    /// run exists is left alone, and a job from another account, a revoked entry or audio already on the
    /// phone is dropped.
    func restoreMediaJobs(context: LibraryMediaContext) {
        guard case let .saved(saved) = mediaJobStore.load() else { return }
        if let owner = saved.ownerToken, owner != context.ownerToken {
            mediaJobStore.removeAll(ownerToken: outboxState.ownerToken)
            return
        }
        for job in saved.jobs where mediaRuns[job.entryID] == nil {
            if mediaRevocations.contains(job.entryID) || media[job.entryID] == .onPhone {
                mediaJobStore.removeJob(entryID: job.entryID, ownerToken: outboxState.ownerToken)
                continue
            }
            launchMediaJob(job, persisting: false)
        }
    }

    /// A held (quarantined) account owns no requests: every job stops and leaves the file (W-INV-021).
    func dropMediaJobsForHeldAccount() {
        for job in mediaJobStore.loadJobs() { cancelMediaRequest(entryID: job.entryID) }
        mediaJobStore.removeAll(ownerToken: outboxState.ownerToken)
    }

    /// Stops a request and returns the row to "Get audio". Its job leaves the file and nothing more is
    /// sent for it.
    func cancelMediaRequest(entryID: ItemID) {
        mediaJobStore.removeJob(entryID: entryID, ownerToken: outboxState.ownerToken)
        guard let run = mediaRuns.removeValue(forKey: entryID) else { return }
        run.task?.cancel()
        media[entryID] = nil
    }

    /// Runs one media job until it is cached or a terminal cause ends it. Cancelling the task leaves the
    /// job in the file, so a relaunch resumes it; the person's Cancel removes it first.
    func runMediaJob(_ initial: LibraryMediaJob, runID: UUID) async {
        let entryID = initial.entryID
        defer { if isCurrent(entryID, runID) { mediaRuns[entryID] = nil } }
        var job = initial
        do {
            if !localStateLoaded { await loadLocalState() }
            while isCurrent(entryID, runID) {
                try Task.checkCancellation()
                if let due = job.nextAttempt, due > now() { try await waitOut(&job, until: due, runID: runID) }
                reissueStaleIntent(&job, runID: runID)
                switch try await mediaJobPass(&job, runID: runID) {
                case .finished: return
                case .again: continue
                case let .wait(due, onMac):
                    job.waitsOnMac = onMac
                    try await waitOut(&job, until: due, runID: runID)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            let entry = entryID.rawValue, detail = MediaFetchErrorClassifier.logDescription(error)
            jobLog.error("Media request for \(entry, privacy: .public) failed: \(detail, privacy: .public)")
            endMediaJob(job, runID: runID, row: .failed(Self.mediaText(for: error)))
        }
    }

    // MARK: - One pass

    /// One try at the whole request. A passing cause becomes a wait; anything else that throws is terminal.
    private func mediaJobPass(_ job: inout LibraryMediaJob, runID: UUID) async throws -> MediaJobStep {
        let entry = job.entryID.rawValue
        do {
            return try await attemptMediaJob(&job, runID: runID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let throttled as TransportThrottled {
            jobLog.notice("Media request for \(entry, privacy: .public) waits for iCloud until \(throttled.retryAt, privacy: .public)")
            return transientWait(&job, notBefore: throttled.retryAt)
        } catch where MediaFetchErrorClassifier.isTransient(error) {
            jobLog.notice("Media request for \(entry, privacy: .public) waits: \(MediaFetchErrorClassifier.logDescription(error), privacy: .public)")
            return transientWait(&job)
        }
    }

    private func attemptMediaJob(_ job: inout LibraryMediaJob, runID: UUID) async throws -> MediaJobStep {
        let entryID = job.entryID
        guard isCurrent(entryID, runID) else { return .finished }
        setMedia(.requested(since: job.requestedSince, stage: job.stage.requestStage), entryID, runID)
        guard let context = await mediaContext(live: true) else {
            let saved = await mediaStoreState()
            if accountQuarantined || saved.reviewHold {
                dropMediaJobsForHeldAccount()
                return .finished
            }
            guard saved.ownerToken?.isEmpty == false else {
                endMediaJob(job, runID: runID, row: .failed("The saved library account is not verified for downloading."))
                return .finished
            }
            return transientWait(&job) // a saved account that cannot be verified right now: offline
        }
        guard isCurrent(entryID, runID), await mediaContextIsCurrent(context, entryID: entryID, live: true) else {
            endMediaJob(job, runID: runID, row: nil) // the entry left the queue or was revoked
            return .finished
        }

        if !job.requestSent {
            let intent = try LibraryIntent.requestMedia(
                entryID: entryID, deviceID: deviceID, createdAt: job.intentCreatedAt, id: job.intentID)
            try await transport.send(intent: intent)
            guard persist(job: &job, runID: runID, { $0.requestSent = true; $0.waits = 0 }) else { return .finished }
        }

        let offer: LibraryMediaOffer
        switch try await awaitAnswer(for: entryID, intentID: job.intentID, runID: runID, context: context) {
        case let .offer(found): offer = found
        case .macNotAnswering:
            jobLog.notice("No answer from the Mac for \(entryID.rawValue, privacy: .public)")
            return .wait(until: now().addingTimeInterval(mediaTiming.macRecheckDelay.timeInterval), onMac: true)
        case let .failed(reason):
            jobLog.notice("The Mac could not send \(entryID.rawValue, privacy: .public)")
            endMediaJob(job, runID: runID, row: .failed(reason))
            return .finished
        }

        guard isCurrent(entryID, runID), await mediaContextIsCurrent(context, entryID: entryID, live: true) else { return .finished }
        guard offer.state == .ready, offer.isPrepared else {
            setNotPrepared(entryID, runID)
            endMediaJob(job, runID: runID, row: media[entryID])
            return .finished
        }
        guard persist(job: &job, runID: runID, { $0.revisionID = offer.revisionID; $0.stage = .downloading; $0.waits = 0 }),
              let admission = await mediaCache.admission(entryID: entryID, ownerToken: context.ownerToken,
                libraryScope: Self.mediaLibraryScope, transportGeneration: context.generation),
              isCurrent(entryID, runID), await mediaContextIsCurrent(context, entryID: entryID, live: true) else { return .finished }

        let outcome = try await download(offer, runID: runID, admission: admission)
        guard await mediaCache.permits(admission, for: offer),
              await mediaContextIsCurrent(context, entryID: entryID, live: true), isCurrent(entryID, runID) else {
            endMediaJob(job, runID: runID, row: .failed("The saved library account changed during downloading."))
            return .finished
        }
        try Task.checkCancellation()
        switch outcome {
        case .cached:
            endMediaJob(job, runID: runID, row: .onPhone)
            phoneStats.recordDownload(bytes: offer.byteCount)
            if let revisionID = offer.revisionID, let ack = try? LibraryIntent.mediaCached(
                entryID: entryID, revisionID: revisionID, deviceID: deviceID, createdAt: now()) {
                unacknowledgedMedia[entryID] = ack
                await sendPendingMediaAcknowledgements()
            }
            startTranscriptLoad(entryID: entryID, fetchOnMiss: true)
            return .finished
        case .notReady:
            setNotPrepared(entryID, runID)
            endMediaJob(job, runID: runID, row: media[entryID])
            return .finished
        case let .failed(reason):
            return stepAfterFailure(reason, offer: offer, job: &job, runID: runID)
        }
    }

    /// A delivered file failed: a stall waits and tries again, a mismatch gets one immediate retry and
    /// ends the job the second time it is the same, the Mac's copy being missing is a wait for the Mac,
    /// and anything else (too large, not savable) ends it.
    private func stepAfterFailure(
        _ reason: MediaFailureReason, offer: LibraryMediaOffer, job: inout LibraryMediaJob, runID: UUID
    ) -> MediaJobStep {
        let mismatchKey: String
        switch reason {
        case .timedOut:
            return transientWait(&job)
        case .hashMismatch:
            mismatchKey = "hash-\(offer.contentHash)"
        case let .byteCountMismatch(_, actual):
            mismatchKey = "size-\(offer.contentHash)-\(actual)"
        case .deliveryFailed, .cacheFailed:
            if reason.fetchFailure == .macNotAnswering {
                return .wait(until: now().addingTimeInterval(mediaTiming.macRecheckDelay.timeInterval), onMac: true)
            }
            endMediaJob(job, runID: runID, row: .failed(Self.text(for: reason)))
            return .finished
        }
        job.mismatchCount = job.mismatchKey == mismatchKey ? job.mismatchCount + 1 : 1
        job.mismatchKey = mismatchKey
        guard job.mismatchCount < 2 else {
            endMediaJob(job, runID: runID, row: .failed(Self.text(for: reason)))
            return .finished
        }
        let entry = job.entryID.rawValue
        jobLog.notice("Media for \(entry, privacy: .public) did not verify; trying once more")
        return persist(job: &job, runID: runID, { _ in }) ? .again : .finished
    }

    // MARK: - Waiting and persistence

    /// A passing cause: wait the next backoff step, or until `notBefore` when iCloud said when it reopens,
    /// whichever is later, so a gate that answers with a time already past cannot make the job spin.
    private func transientWait(_ job: inout LibraryMediaJob, notBefore: Date? = nil) -> MediaJobStep {
        let steps = mediaTiming.waitDelays
        let step = steps.isEmpty ? 10 : steps[min(job.waits, steps.count - 1)].timeInterval
        job.waits += 1
        return .wait(until: max(now().addingTimeInterval(step), notBefore ?? .distantPast), onMac: false)
    }

    /// Shows the wait on the row with its time, keeps it in the file, sleeps, and clears it. Cancel, a
    /// revoked entry or a held account end the wait.
    private func waitOut(_ job: inout LibraryMediaJob, until due: Date, runID: UUID) async throws {
        let entryID = job.entryID
        guard persist(job: &job, runID: runID, { $0.nextAttempt = due }) else { throw CancellationError() }
        setMedia(waitingRow(job, until: due) ?? .requested(since: job.requestedSince, stage: job.stage.requestStage), entryID, runID)
        try await mediaTiming.retrySleep(.seconds(max(0, due.timeIntervalSince(now()))))
        try Task.checkCancellation()
        guard isCurrent(entryID, runID) else { throw CancellationError() }
        guard !accountQuarantined, !mediaRevocations.contains(entryID) else {
            endMediaJob(job, runID: runID, row: nil)
            throw CancellationError()
        }
        guard persist(job: &job, runID: runID, { $0.nextAttempt = nil }) else { throw CancellationError() }
    }

    /// The row for a job waiting until `due`, with the time in its words; nil when it is not waiting.
    private func waitingRow(_ job: LibraryMediaJob, until due: Date?) -> LibraryMediaState? {
        guard let due, due > now() else { return nil }
        let notice = job.waitsOnMac ? macWaitNotice(checkingAt: due) : throttleNotice(retryingAt: due)
        return .requested(since: job.requestedSince, retry: LibraryMediaRetry(notice: notice), stage: job.stage.requestStage)
    }

    /// An intent six days old is replaced by a fresh one (one in flight per job) before it can pass the
    /// Mac's `maximumIntentAge`. The new id is saved before it is sent.
    private func reissueStaleIntent(_ job: inout LibraryMediaJob, runID: UUID) {
        guard job.stage != .downloading,
              now().timeIntervalSince(job.intentCreatedAt) >= LibraryMediaJob.intentReissueAge else { return }
        let createdAt = now()
        _ = persist(job: &job, runID: runID) {
            $0.intentID = UUID().uuidString
            $0.intentCreatedAt = createdAt
            $0.requestSent = false
        }
    }

    /// Changes `job` and saves it, unless this run is no longer the entry's (cancelled or replaced), in
    /// which case it saves nothing.
    private func persist(job: inout LibraryMediaJob, runID: UUID, _ change: (inout LibraryMediaJob) -> Void) -> Bool {
        change(&job)
        guard isCurrent(job.entryID, runID) else { return false }
        mediaJobStore.saveJob(job, ownerToken: outboxState.ownerToken)
        return true
    }

    /// Ends a job: the row takes `row` and the job leaves the file. A run that is no longer the entry's
    /// does neither, so a cancelled run cannot remove its successor's job.
    private func endMediaJob(_ job: LibraryMediaJob, runID: UUID, row: LibraryMediaState?) {
        guard isCurrent(job.entryID, runID) else { return }
        mediaJobStore.removeJob(entryID: job.entryID, ownerToken: outboxState.ownerToken)
        media[job.entryID] = row
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
