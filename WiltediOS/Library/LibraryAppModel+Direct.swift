import Foundation
import Network
import OSLog
import WiltedDomain
import WiltedLibrary

private let directLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryDirect")

/// How the direct attempt for one media job ended.
enum LibraryDirectResult: Equatable {
    /// The direct path did not apply; the job goes on exactly as it did before it existed.
    case notTried
    /// It started and gave up for a typed cause; the job goes on with the normal iCloud request.
    case fellBack
    /// A verified file was adopted and the job is done.
    case cached
    /// The job ended or was superseded while trying.
    case ended
}

private enum LibraryDirectPlan {
    /// No environment, or this job already gave up on this file: nothing to say.
    case off
    case skip(LibraryDirectFallback)
    case attempt(offer: LibraryMediaOffer, peer: LANTLSPeer, environment: LibraryDirectEnvironment)
}

/// The phone's direct path: fetch a prepared revision from the Mac over the local network before asking
/// iCloud, and fall back to the normal request for every cause in `LibraryDirectFallback`. It is
/// attempted only with the switch on, the Mac's key, a cached prepared offer with a certified hash, and a
/// launch-verified owner (D5). A direct success makes no iCloud call: its `mediaCached` acknowledgement
/// waits in the outbox for the next round.
extension LibraryAppModel {
    // MARK: - What the phone remembers

    var directStore: LibraryDirectStore {
        LibraryDirectStore(url: mediaJobStore.url?.deletingLastPathComponent().appendingPathComponent("media-direct.json"))
    }

    /// What was learned under `owner`, read from the file on first use; nothing for another owner.
    func directSaved(owner: String) -> LibraryDirectSaved? {
        if !directState.loaded {
            directState.loaded = true
            directState.saved = directStore.load()
        }
        guard let saved = directState.saved, saved.ownerToken == owner else { return nil }
        return saved
    }

    private func updateDirectCache(owner: String?, _ change: (inout LibraryDirectSaved) -> Void) {
        guard directState.environment != nil, let owner, !owner.isEmpty else { return }
        var next = directSaved(owner: owner) ?? LibraryDirectSaved(ownerToken: owner, macKey: nil, macDeviceID: nil, offers: [])
        change(&next)
        if let macID = lastObservedPublication?.writerDeviceID, next.macDeviceID != macID { next.macDeviceID = macID }
        guard next != directState.saved else { return }
        directState.saved = next
        directStore.save(next)
    }

    /// Keeps the offers a round read, so a launch without signal still knows what the Mac prepared.
    func rememberDirectOffers(_ offers: [LibraryMediaOffer]) {
        let sorted = offers.sorted { $0.entryID.rawValue < $1.entryID.rawValue }
        updateDirectCache(owner: outboxState.ownerToken) { $0.offers = sorted }
    }

    /// Keeps the Mac's key from its link. A link without one (the Mac stopped serving this phone) clears it.
    func rememberDirectLink(_ link: LibraryDeviceLink, owner: String?) {
        updateDirectCache(owner: owner) { $0.macKey = link.lanPublicKey }
    }

    /// The account changed: the Mac, its key and its offers belonged to the previous library.
    func forgetDirectCache() {
        directState.saved = nil
        directState.loaded = true
        directState.suspended = []
        directStore.remove()
    }

    // MARK: - Eligibility

    private func directPlan(entryID: ItemID, owner: String, job: LibraryMediaJob) -> LibraryDirectPlan {
        guard let environment = directState.environment else { return .off }
        // Nothing touches the local network until the person has answered the one-time step (3.3).
        guard LibrarySettingsStore.directDownloadsEnabled(in: preferences),
              LibrarySettingsStore.directDownloadsOnboardingShown(in: preferences) else { return .skip(.switchOff) }
        if directState.localNetworkDenied { return .skip(.localNetworkDenied) }
        guard let saved = directSaved(owner: owner), let macKey = saved.macKey, !macKey.isEmpty,
              let macID = saved.macDeviceID ?? lastObservedPublication?.writerDeviceID else { return .skip(.noMacKey) }
        guard let offer = saved.offers.first(where: { $0.entryID == entryID }) else { return .skip(.noOffer) }
        guard offer.isPrepared else {
            return .skip(offer.state == .available && offer.contentHash.isEmpty ? .hashlessOffer : .offerNotPrepared)
        }
        if job.directFailedFor == offer.contentHash { return .off }
        guard let phoneKey = environment.phoneKey() else { return .skip(.noPhoneKey) }
        guard let peer = LibraryDirectPairing.peer(
            phoneKey: phoneKey, macPublicKey: macKey, ownerToken: owner, macDeviceID: macID, phoneDeviceID: deviceID)
        else { return .skip(.noMacKey) }
        return .attempt(offer: offer, peer: peer, environment: environment)
    }

    /// True when `job` would go direct if its saved account were verified (fallback rule 1a).
    func directPathWaitsOnOwner(_ job: LibraryMediaJob, savedOwner: String?) async -> Bool {
        guard let savedOwner, case .attempt = directPlan(entryID: job.entryID, owner: savedOwner, job: job) else { return false }
        return true
    }

    // MARK: - The attempt

    /// Tries the direct path for `job` once, after the owner is verified and before any iCloud request.
    func attemptDirectDownload(
        _ job: inout LibraryMediaJob, runID: UUID, context: LibraryMediaContext
    ) async throws -> LibraryDirectResult {
        let entryID = job.entryID
        let plan = directPlan(entryID: entryID, owner: context.ownerToken, job: job)
        guard case let .attempt(offer, peer, environment) = plan else {
            if case let .skip(cause) = plan { directState.record(cause, entryID: entryID) }
            return .notTried
        }
        guard let directory = mediaCache.partialDirectory(for: entryID),
              let admission = await mediaCache.admission(entryID: entryID, ownerToken: context.ownerToken,
                libraryScope: Self.mediaLibraryScope, transportGeneration: context.generation) else {
            directState.record(.unexpected, entryID: entryID)
            return .notTried
        }

        let transfers = directTransfers(environment)
        transfers?.join(entryID: entryID, bytes: LANPartialFile.resumeOffset(in: directory, for: offer), total: offer.byteCount)
        directState.running[entryID] = runID
        var adopted = false
        defer {
            transfers?.leave(entryID: entryID, finished: adopted)
            if directState.running[entryID] == runID { directState.running[entryID] = nil }
        }
        let since = media[entryID]?.startedAt ?? job.requestedSince
        setMedia(.requested(since: since, stage: .lookingForMac), entryID, runID)

        let search = await environment.locator.locate(within: environment.browseBudget)
        try Task.checkCancellation()
        guard isCurrent(entryID, runID) else { return .ended }
        guard await mediaContextIsCurrent(context, entryID: entryID, live: true) else {
            endMediaJob(job, runID: runID, row: nil) // the entry left the queue or was revoked
            return .ended
        }
        let endpoints: [NWEndpoint]
        switch search {
        case .none: return fellBack(.macNotFound, &job, offer: offer, runID: runID)
        case .denied:
            directState.localNetworkDenied = true
            return fellBack(.localNetworkDenied, &job, offer: offer, runID: runID)
        case let .found(found): endpoints = found
        }

        let source = environment.makeSource(.init(endpoints: endpoints, peer: peer, partialDirectory: directory) { [weak self] phase in
            if phase == .verifying { Task { @MainActor in self?.directVerifying(entryID: entryID, runID: runID) } }
        })
        var busyRetried = false
        while true {
            do {
                let resumeAt = LANPartialFile.resumeOffset(in: directory, for: offer)
                let file = try await source.fetch(offer, from: resumeAt) { [weak self] bytes in
                    Task { @MainActor in self?.directProgress(bytes, offer: offer, since: since, runID: runID) }
                }
                try Task.checkCancellation()
                guard isCurrent(entryID, runID) else { return .ended }
                let outcome = try await acceptDirectFile(file, offer: offer, admission: admission, runID: runID)
                guard await mediaCache.permits(admission, for: offer),
                      await mediaContextIsCurrent(context, entryID: entryID, live: true), isCurrent(entryID, runID) else {
                    endMediaJob(job, runID: runID, row: .failed("The saved library account changed during downloading."))
                    return .ended
                }
                switch outcome {
                case .cached:
                    adopted = true
                    finishDirectJob(job, offer: offer, runID: runID)
                    return .cached
                case let .failed(reason):
                    switch reason {
                    case .hashMismatch, .byteCountMismatch: return fellBack(.mismatch, &job, offer: offer, runID: runID)
                    default: return fellBack(.unexpected, &job, offer: offer, runID: runID)
                    }
                case .notReady:
                    return fellBack(.unexpected, &job, offer: offer, runID: runID)
                }
            } catch let error as LANMediaError {
                if case .busy = error, !busyRetried {
                    busyRetried = true
                    directState.record(.macBusy, entryID: entryID)
                    try await mediaTiming.retrySleep(environment.busyRetryDelay)
                    try Task.checkCancellation()
                    guard isCurrent(entryID, runID) else { return .ended }
                    continue
                }
                return fellBack(LibraryDirectFallback(error), &job, offer: offer, runID: runID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let detail = MediaFetchErrorClassifier.logDescription(error)
                directLog.error("A direct download failed outside the LAN client: \(detail, privacy: .public)")
                return fellBack(.unexpected, &job, offer: offer, runID: runID)
            }
        }
    }

    /// Verifies a delivered file against the offer and moves it into the cache. The phone trusts nothing
    /// the source already checked: the fetcher counts the bytes and hashes the file itself (W-INV-007).
    private func acceptDirectFile(
        _ file: URL, offer: LibraryMediaOffer, admission: MediaCacheAdmission, runID: UUID
    ) async throws -> MediaFetchOutcome {
        let fetcher = MediaFetcher(cache: mediaCache, watchdog: mediaTiming.watchdog,
                                   retryDelays: mediaTiming.retryDelays, sleep: mediaTiming.retrySleep)
        return try await fetcher.acceptDirect(deliveredFile: file, for: offer, admission: admission, transport: transport)
    }

    /// A direct download is cached. No iCloud call is made: the acknowledgement is queued for the next round,
    /// and the transcript is read when the episode is opened.
    private func finishDirectJob(_ job: LibraryMediaJob, offer: LibraryMediaOffer, runID: UUID) {
        let entryID = job.entryID
        endMediaJob(job, runID: runID, row: .onPhone)
        phoneStats.recordDownload(bytes: offer.byteCount)
        if let revisionID = offer.revisionID, let ack = try? LibraryIntent.mediaCached(
            entryID: entryID, revisionID: revisionID, deviceID: deviceID, createdAt: now()) {
            unacknowledgedMedia[entryID] = ack
        }
        startTranscriptLoad(entryID: entryID, fetchOnMiss: false)
    }

    /// Gives up the direct path for this file in this job, says why, and goes back to the iCloud request.
    private func fellBack(
        _ cause: LibraryDirectFallback, _ job: inout LibraryMediaJob, offer: LibraryMediaOffer, runID: UUID
    ) -> LibraryDirectResult {
        directState.record(cause, entryID: job.entryID)
        let hash = offer.contentHash
        guard persist(job: &job, runID: runID, { $0.directFailedFor = hash }) else { return .ended }
        setMedia(.requested(since: job.requestedSince, stage: job.stage.requestStage), job.entryID, runID)
        return .fellBack
    }

    private func directProgress(_ bytes: Int64, offer: LibraryMediaOffer, since: Date, runID: UUID) {
        let entryID = offer.entryID
        guard isCurrent(entryID, runID) else { return }
        switch media[entryID] {
        case .requested?, .downloadingFromMac?: break
        default: return
        }
        if case let .downloadingFromMac(old, _, _)? = media[entryID], old > bytes { return }
        media[entryID] = .downloadingFromMac(bytes: bytes, total: offer.byteCount, since: since)
        directState.transfers?.progress(entryID: entryID, bytes: bytes)
    }

    private func directVerifying(entryID: ItemID, runID: UUID) {
        setMedia(.verifying, entryID, runID)
    }

    // MARK: - Background time

    private func directTransfers(_ environment: LibraryDirectEnvironment) -> LibraryDirectTransferCoordinator? {
        if let existing = directState.transfers { return existing }
        guard let scheduler = environment.scheduler else { return nil }
        let coordinator = LibraryDirectTransferCoordinator(scheduler: scheduler) { [weak self] in self?.suspendDirectRuns() }
        directState.transfers = coordinator
        return coordinator
    }

    /// The system ended the background task: every direct run stops where it is. The partial files and the
    /// jobs stay, and the rows say so; the next time the app is in front they start again.
    func suspendDirectRuns() {
        for entryID in Array(directState.running.keys) {
            guard let run = mediaRuns.removeValue(forKey: entryID) else { continue }
            run.task?.cancel()
            directState.suspended.insert(entryID)
            let since = media[entryID]?.startedAt ?? now()
            media[entryID] = .requested(since: since, retry: LibraryMediaRetry(notice: "Paused. Open Wilted to continue."),
                                        stage: .lookingForMac)
        }
    }

    /// The app is in front: direct downloads the system paused start again from their partial files, and a
    /// Local Network refusal is looked at afresh (changing it means leaving the app).
    func resumeSuspendedDirectRuns() {
        directState.localNetworkDenied = false
        let entries = directState.suspended
        directState.suspended = []
        guard !entries.isEmpty else { return }
        let jobs = mediaJobStore.loadJobs()
        for entryID in entries where mediaRuns[entryID] == nil {
            guard let job = jobs.first(where: { $0.entryID == entryID }) else { continue }
            launchMediaJob(job, persisting: false)
        }
    }

    // MARK: - Partial files

    /// Drops partial files that can no longer be resumed: an older revision of an offered entry, and
    /// everything for an entry the Mac says is not ready.
    func discardStalePartials(for offers: [LibraryMediaOffer]) async {
        for offer in offers {
            await mediaCache.discardPartials(entryID: offer.entryID, keeping: offer.isPrepared ? offer : nil)
        }
    }

    /// Partial files untouched for a week are deleted.
    func purgeOldPartials() async {
        await mediaCache.purgePartials(olderThan: now().addingTimeInterval(-FileMediaCache.partialLifetime))
    }
}
