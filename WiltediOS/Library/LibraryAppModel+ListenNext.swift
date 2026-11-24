import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let listenNextLog = Logger(subsystem: "com.zerodelta.wilted", category: "ListenNext")

extension LibraryAppModel {
    private var supportedListenNextActions: Set<String> { ["listenNext", "cancelListenNext"] }

    var listenNextStoryStatuses: [String: String] {
        Dictionary(listenNextRequests.map { request in
            let label: String
            if let received = listenNextDownloadProgress[request.requestID],
               let total = request.audioOffer?.byteCount, total > 0 {
                let percentage = min(100, max(0, Int((Double(received) / Double(total)) * 100)))
                label = "Downloading audio (\(percentage)%)"
            } else {
                label = Self.listenNextLabel(for: request.status)
            }
            return (request.requestID, label)
        }, uniquingKeysWith: { _, latest in latest })
    }

    var listenNextStoryMessages: [String: String] {
        Dictionary(listenNextRequests.compactMap { request in
            Self.listenNextFailureText(request.failure).map { (request.requestID, $0) }
        }, uniquingKeysWith: { _, latest in latest })
    }

    var hasListenNextSyncWork: Bool {
        listenNextState.entries.contains { entry in
            entry.requestIntent != nil || entry.cancellationIntent != nil
                || entry.snapshot.status == .pending || entry.snapshot.status == .sent
                || entry.snapshot.status == .preparing
                || (entry.snapshot.status == .ready && !entry.audioCached)
        }
    }

    private static func listenNextFailureText(_ failure: LibraryListenNextStatus.Failure?) -> String? {
        switch failure {
        case .unsafeArticle: "This link could not be opened safely. Read story is still available."
        case .unavailableStory: "The article could not be fetched. Retry the original story link."
        case .missingVoice: "Your selected reading voice is unavailable on the Mac."
        case .narrationFailed: "The article could not be narrated. Retry when the Mac is ready."
        case .transferFailed: "The audio could not play on this phone. Retry the story."
        case nil: nil
        }
    }

    static func listenNextLabel(for status: LibraryListenNextRequestSnapshot.Status) -> String {
        switch status {
        case .pending: "Waiting to send"
        case .sent: "Sent to Mac"
        case .preparing: "Preparing audio"
        case .ready: "Up next"
        case .failed: "Could not prepare"
        case .cancelled: "Cancelled"
        case .selected: "Up next"
        case .playing: "Playing story"
        case .completed: "Played"
        }
    }

    func verifyListenNextOutboxOwner(_ owner: String?) {
        guard listenNextState.isRestored else { return }
        guard let savedOwner = listenNextState.ownerToken else {
            listenNextState.ownerToken = owner
            return
        }
        guard savedOwner == owner else {
            cancelListenNextDownloads()
            listenNextState.heldForAccountReview = true
            listenNextLog.error("Held \(self.listenNextState.entries.count, privacy: .public) story requests from another library owner.")
            return
        }
        listenNextState.heldForAccountReview = false
    }

    func restoreListenNextOutbox() {
        guard !listenNextState.isRestored else { return }
        listenNextState.isRestored = true
        switch listenNextState.outbox.load() {
        case .empty:
            return
        case .unreadable:
            listenNextState.writable = false
            reportListenNextError("A saved story request could not be read. It was held and will not be sent.")
        case let .saved(saved):
            listenNextState.ownerToken = saved.ownerToken
            listenNextState.entries = saved.entries
            publishListenNextRows()
        }
    }

    /// Drops requests from the old account after the owner explicitly recovers to a new library.
    /// The queue ledger is independently owner and generation scoped, so old playback stays inert.
    func discardListenNextAfterAccountChange() {
        cancelListenNextDownloads()
        let oldRequestIDs = listenNextState.entries.map(\.id)
        let oldOwner = listenNextState.ownerToken
        listenNextState.inFlightRequests.removeAll()
        listenNextState.entries.removeAll()
        listenNextState.ownerToken = nil
        listenNextState.heldForAccountReview = false
        do { try persistListenNext() }
        catch { reportListenNextError("Saved story requests could not be cleared after the account change.") }
        for requestID in oldRequestIDs {
            do {
                if let oldOwner { try listenNextState.audioCache.removeAudio(for: requestID, ownerToken: oldOwner) }
            }
            catch { listenNextLog.error("Could not remove old story audio for \(requestID, privacy: .public).") }
        }
        discardStoryPlaybackLedgerAfterAccountChange()
    }

    /// Current-device requests for queue admission, scoped to the verified live account and generation.
    func listenNextSnapshots() async -> [LibraryListenNextRequestSnapshot] {
        guard let context = await liveListenNextContext() else { return [] }
        return listenNextState.entries.map(\.snapshot).filter {
            $0.requesterDeviceID == deviceID && $0.ownerToken == context.ownerToken
                && $0.operationGeneration == context.generation
        }
    }

    func persistListenNext() throws {
        try listenNextState.persist()
        publishListenNextRows()
    }

    func liveListenNextContext() async -> LibraryMediaContext? {
        guard !accountQuarantined, !listenNextState.heldForAccountReview else {
            cancelListenNextDownloads()
            return nil
        }
        let saved = await mediaStoreState()
        guard let context = await mediaContext(live: true),
              saved.ownerToken == context.ownerToken,
              listenNextState.ownerToken == nil || listenNextState.ownerToken == context.ownerToken else {
            cancelListenNextDownloads()
            return nil
        }
        let staleGenerationDownloads = listenNextState.entries.compactMap { entry -> String? in
            guard listenNextState.downloadTasks[entry.id] != nil,
                  entry.snapshot.requesterDeviceID == deviceID,
                  entry.snapshot.ownerToken == context.ownerToken,
                  entry.snapshot.operationGeneration != context.generation else { return nil }
            return entry.id
        }
        for requestID in staleGenerationDownloads {
            cancelListenNextDownloads(requestID: requestID)
        }
        if listenNextState.ownerToken == nil {
            listenNextState.ownerToken = context.ownerToken
            do { try persistListenNext() } catch { return nil }
        }
        return context
    }

    /// Creates the phone-side request before sending it. The separate v1 file keeps these newer
    /// action cases from making an older LibraryIntentOutbox unreadable.
    func listenNext(_ story: LibraryHeadlineStory, anchorID: ItemID? = nil) async {
        let storyID = story.id
        guard !listenNextState.requestingStoryIDs.contains(storyID),
              !listenNextState.entries.contains(where: {
                  $0.snapshot.storyID == storyID && !$0.snapshot.isTerminal
              }) else { return }
        listenNextState.requestingStoryIDs.insert(storyID)
        defer { listenNextState.requestingStoryIDs.remove(storyID) }

        guard let link = story.link, link.scheme?.lowercased() == "https", link.host?.isEmpty == false,
              link.user == nil, link.password == nil else {
            reportListenNextError("This story link cannot be prepared safely. You can still open it.")
            return
        }
        guard listenNextState.outbox.url != nil else {
            reportListenNextError("The story request could not be saved on this phone.")
            return
        }
        guard storyAudioTransport != nil else {
            reportListenNextError("Story listening is unavailable on this phone build.")
            return
        }
        guard let context = await liveListenNextContext() else {
            reportListenNextError("Connect to the library before queuing this story.")
            return
        }
        if macAddActions == nil || macAddCheckFailed { await loadAddCapability() }
        let macSupportsListenNext = macAddActions?.isSuperset(of: supportedListenNextActions) == true

        let playbackAnchor = anchorID ?? handoffState.reportedEntry
        do {
            let requestedAt = now()
            let intent = try LibraryIntent.listenNext(
                story: story, anchorID: playbackAnchor, deviceID: deviceID, createdAt: requestedAt
            )
            let snapshot = try LibraryListenNextRequestSnapshot(
                requestID: intent.id, story: story, requesterDeviceID: deviceID, ownerToken: context.ownerToken,
                operationGeneration: context.generation, anchorID: playbackAnchor, createdAt: requestedAt, status: .pending
            )
            listenNextState.entries.append(.init(snapshot: snapshot, requestIntent: intent,
                                                  cancellationIntent: nil, requestSent: false, audioCached: false, remoteStatusRevision: 0))
            do {
                // The persistent request and its owner fence must land before the transport call.
                try persistListenNext()
                rearmStoryQueueForExplicitListenNext()
                try recordStoryListenNext(
                    snapshot, holdEpoch: handoffState.player?.storyAutoStartEpoch
                        ?? (preferences.object(forKey: Self.listenNextPlaybackHoldKey) as? UInt64 ?? 0))
                publishListenNextRows()
            } catch {
                listenNextState.entries.removeAll { $0.id == intent.id }
                try? persistListenNext()
                throw error
            }
            if macSupportsListenNext {
                await flushListenNextCommands(context: context)
            } else {
                reportListenNextError("Saved on this phone. Update Wilted on your Mac to send it.")
            }
        } catch {
            reportListenNextError(Self.listenNextErrorText(error))
        }
    }

    /// Writes the cancellation tombstone before it reaches CloudKit or the playback queue.
    func undoListenNext(requestID: String) async {
        guard let index = listenNextState.entries.firstIndex(where: { $0.id == requestID }) else { return }
        let previous = listenNextState.entries[index]
        guard !previous.snapshot.isTerminal, previous.snapshot.status != .playing else { return }
        do {
            let inFlight = listenNextState.inFlightRequests.contains(requestID)
            var updated = previous
            updated.snapshot = try Self.listenNextSnapshot(previous.snapshot, status: .cancelled)
            if previous.requestSent || previous.requestAttempted || inFlight {
                updated.cancellationIntent = try .cancelListenNext(
                    requestID: requestID, deviceID: deviceID, createdAt: now()
                )
            } else {
                // A request that never entered transport is withdrawn locally. If it is in flight,
                // the matching tombstone is retained and sent immediately after request acceptance.
                updated.requestIntent = nil
                updated.cancellationIntent = nil
            }
            listenNextState.entries[index] = updated
            try persistListenNext()
        } catch {
            listenNextState.entries[index] = previous
            publishListenNextRows()
            reportListenNextError(Self.listenNextErrorText(error))
            return
        }
        do {
            try storyRequestCancelled(listenNextState.entries[index].snapshot)
        } catch {
            listenNextLog.notice("Queue cancellation recovery deferred for \(requestID, privacy: .public).")
        }
        cancelListenNextDownloads(requestID: requestID)
        do {
            try listenNextState.audioCache.removeAudio(for: requestID, ownerToken: previous.snapshot.ownerToken)
            if let currentIndex = listenNextState.entries.firstIndex(where: { $0.id == requestID }) {
                listenNextState.entries[currentIndex].audioCached = false
                try persistListenNext()
            }
        } catch {
            listenNextLog.error("Could not remove cancelled story audio for \(requestID, privacy: .public).")
        }
        guard let context = await liveListenNextContext() else { return }
        if macAddActions == nil || macAddCheckFailed { await loadAddCapability() }
        await flushListenNextCommands(context: context)
    }

    /// Retries the same original URL as a new idempotent request, preserving the failed row for context.
    func retryListenNext(requestID: String) async {
        guard let failed = listenNextState.entries.first(where: {
            $0.id == requestID && $0.snapshot.status == .failed
        }) else { return }
        await listenNext(failed.snapshot.story, anchorID: failed.snapshot.anchorID)
    }

    /// Called with sync rounds and immediately after a user action. Command persistence precedes send,
    /// and cancellation is sent only after the original request was accepted.
    func syncListenNextRequests() async {
        guard let context = await liveListenNextContext() else { return }
        await flushListenNextCommands(context: context)
        await refreshListenNextStatuses(context: context)
        guard await mediaContextIsCurrent(context, live: true) else { return }
        await reconcileCompletedListenNextAudio(context: context)
    }

    private func flushListenNextCommands(context: LibraryMediaContext) async {
        guard await mediaContextIsCurrent(context, live: true),
              macAddActions?.isSuperset(of: supportedListenNextActions) == true,
              !macAddCheckFailed else { return }
        for requestID in listenNextState.entries.map(\.id) {
            guard await mediaContextIsCurrent(context, live: true),
                  let index = listenNextState.entries.firstIndex(where: { $0.id == requestID }) else { return }
            var entry = listenNextState.entries[index]
            if let intent = entry.requestIntent,
               (entry.snapshot.status != .cancelled || entry.cancellationIntent != nil),
               !listenNextState.inFlightRequests.contains(requestID) {
                listenNextState.inFlightRequests.insert(requestID)
                do {
                    if !entry.requestAttempted {
                        entry.requestAttempted = true
                        listenNextState.entries[index] = entry
                        try persistListenNext()
                    }
                    try await transport.send(intent: intent)
                    guard await mediaContextIsCurrent(context, live: true),
                          let currentIndex = listenNextState.entries.firstIndex(where: { $0.id == requestID }) else {
                        listenNextState.inFlightRequests.remove(requestID)
                        return
                    }
                    entry = listenNextState.entries[currentIndex]
                    entry.requestIntent = nil
                    entry.requestSent = true
                    if entry.snapshot.status == .pending {
                        entry.snapshot = try Self.listenNextSnapshot(entry.snapshot, status: .sent)
                    }
                    listenNextState.entries[currentIndex] = entry
                    try persistListenNext()
                } catch {
                    listenNextLog.notice("Request send deferred for \(requestID, privacy: .public).")
                }
                listenNextState.inFlightRequests.remove(requestID)
            }

            guard let currentIndex = listenNextState.entries.firstIndex(where: { $0.id == requestID }) else { continue }
            entry = listenNextState.entries[currentIndex]
            if let intent = entry.cancellationIntent, entry.requestSent {
                do {
                    try await transport.send(intent: intent)
                    guard await mediaContextIsCurrent(context, live: true),
                          let finalIndex = listenNextState.entries.firstIndex(where: { $0.id == requestID }) else { return }
                    listenNextState.entries[finalIndex].cancellationIntent = nil
                    try persistListenNext()
                } catch {
                    listenNextLog.notice("Cancellation send deferred for \(requestID, privacy: .public).")
                }
            }
        }
    }

    private static func listenNextSnapshot(
        _ prior: LibraryListenNextRequestSnapshot,
        status: LibraryListenNextRequestSnapshot.Status
    ) throws -> LibraryListenNextRequestSnapshot {
        try LibraryListenNextRequestSnapshot(
            requestID: prior.requestID, story: prior.story, requesterDeviceID: prior.requesterDeviceID,
            ownerToken: prior.ownerToken, operationGeneration: prior.operationGeneration, anchorID: prior.anchorID,
            createdAt: prior.createdAt, statusUpdatedAt: prior.statusUpdatedAt,
            status: status, statusRevision: prior.statusRevision,
            audioOffer: status == .selected || status == .playing ? prior.audioOffer : nil,
            voiceID: status == .selected || status == .playing ? prior.voiceID : nil,
            voiceRevision: status == .selected || status == .playing ? prior.voiceRevision : nil
        )
    }

    static func listenNextErrorText(_ error: Error) -> String {
        if let failure = error as? LibraryListenNextError {
            return switch failure {
            case .unavailable: "Connect to the library before queuing this story."
            case .notDurable: "The story request could not be saved on this phone."
            case .unsupportedMac: "Update Wilted on your Mac to queue stories from this phone."
            case .unsafeLink: "This story link cannot be prepared safely. You can still open it."
            case .missingRequest: "This story request is no longer available."
            }
        }
        return "The story request is still saved on this phone and will retry when the library is available."
    }
}
