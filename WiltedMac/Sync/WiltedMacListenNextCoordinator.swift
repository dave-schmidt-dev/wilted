import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

enum WiltedMacListenNextError: Error, Equatable {
    case missingVoice
    case unavailableStory
    case unavailableTransport
}

/// Owns one Mac's durable Listen next admission and its request-scoped audio output.
@MainActor
final class WiltedMacListenNextCoordinator {
    typealias NarrationOperation = @Sendable (
        ArticleNarrationRequest,
        URL,
        @escaping @Sendable (ArticleNarrationProgress) -> Void
    ) async throws -> ArticleNarrationResult

    private struct Context: Equatable {
        let ownerToken: String
        let generation: UInt64
    }

    private enum WorkStage: Equatable {
        case narration
        case transfer
    }

    private struct RunningTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct StatusKey: Hashable {
        let ownerToken: String
        let deviceID: String
        let requestID: String
    }

    private weak var model: WiltedMacModel?
    private let store: WiltedMacListenNextStore
    private let transport: (any LibraryTransport)?
    private let audioTransport: (any LibraryStoryAudioTransport)?
    private let directory: URL
    private let staging: WiltedMacListenNextStaging
    private let deviceID: String
    private let narrate: NarrationOperation
    private var context: Context?
    private var sweptStagingOwners = Set<String>()
    private var tasks: [String: RunningTask] = [:]
    private var publishedStatusRevisions: [StatusKey: UInt64] = [:]
    private var pendingStatusRevisions: [StatusKey: UInt64] = [:]

    init(
        model: WiltedMacModel,
        transport: (any LibraryTransport)?,
        directory: URL,
        deviceID: String,
        store: WiltedMacListenNextStore? = nil,
        narrate: @escaping NarrationOperation = { request, outputURL, progress in
            try await ArticleNarrationCoordinator().narrate(request, outputURL: outputURL, progress: progress)
        }
    ) throws {
        let audioTransport = transport as? any LibraryStoryAudioTransport
        if case (.some, .none) = (transport, audioTransport) {
            throw WiltedMacListenNextError.unavailableTransport
        }
        self.model = model
        self.store = store ?? model.listenNextRequestStore
        self.transport = transport
        self.audioTransport = audioTransport
        self.directory = directory
        self.staging = WiltedMacListenNextStaging(directory: directory, coordinatorDeviceID: deviceID)
        self.deviceID = deviceID
        self.narrate = narrate
    }

    /// Persists admission before the applier stores the accepted intent outcome.
    func handle(
        _ intent: LibraryIntent,
        afterAdmission: (@MainActor (LibraryListenNextRequestSnapshot) async throws -> Void)? = nil
    ) async throws -> IntentOutcome {
        guard intent.deviceID == deviceID || transport != nil else {
            throw WiltedMacListenNextError.unavailableTransport
        }
        let current = try await activate()
        switch intent.action {
        case let .listenNext(story, anchorID):
            guard let canonical = try validatedStory(story) else {
                return try .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: Date())
            }
            let voice = selectedVoice()
            let canonicalIntent = try LibraryIntent.listenNext(
                story: canonical, anchorID: anchorID, deviceID: intent.deviceID,
                createdAt: intent.createdAt, id: intent.id)
            let snapshot = try await store.admit(
                canonicalIntent, ownerToken: current.ownerToken, operationGeneration: current.generation,
                voiceID: voice?.rawValue, voiceRevision: voice.map(ArticleNarrationCoordinator.voiceRevision(for:)))
            guard snapshot.status != .cancelled else {
                return try .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: Date())
            }
            try await afterAdmission?(snapshot)
            guard Self.isSafeHTTPS(canonical.link) else {
                if let failed = try await store.setStatus(
                    requestID: snapshot.requestID, ownerToken: current.ownerToken,
                    operationGeneration: current.generation, status: .failed, failure: .unsafeArticle) {
                    await updateLocalRequest(failed)
                    await publishStatus(for: failed)
                }
                return try .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: Date())
            }
            guard snapshot.voiceID != nil, snapshot.voiceRevision != nil else {
                if let failed = try await store.setStatus(
                    requestID: snapshot.requestID, ownerToken: current.ownerToken,
                    operationGeneration: current.generation, status: .failed, failure: .missingVoice) {
                    await updateLocalRequest(failed)
                    await publishStatus(for: failed)
                }
                return try .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: Date())
            }
            enqueueIfPreparing(snapshot)
            Task { [weak self] in await self?.publishStatus(for: snapshot) }
            return try .applied(for: intent, at: Date())

        case let .cancelListenNext(requestID):
            let cancelled = try await store.cancel(
                requestID: requestID, requesterDeviceID: intent.deviceID,
                ownerToken: current.ownerToken, operationGeneration: current.generation)
            tasks[requestID]?.task.cancel()
            tasks.removeValue(forKey: requestID)
            if let cancelled {
                await updateLocalRequest(cancelled)
                await discardAudio(for: cancelled)
                await publishStatus(for: cancelled)
            }
            return try .applied(for: intent, at: Date())

        default:
            return try .rejected(for: intent, reason: IntentOutcome.reasonUnsupportedAction, at: Date())
        }
    }

    /// Rebinds durable work to the current verified owner and resumes interrupted narration.
    func activateAndResume() async {
        guard let result = try? await activate() else { return }
        for snapshot in result.2 {
            if snapshot.status == .preparing { enqueueIfPreparing(snapshot) }
            if snapshot.isTerminal { await discardAudio(for: snapshot) }
            await publishStatus(for: snapshot)
        }
    }

    /// Retries only status revisions whose last cloud write failed.
    func retryPendingStatusUpdates() async {
        guard let result = try? await activate() else { return }
        let pending = result.2.filter { pendingStatusRevisions[Self.statusKey(for: $0)] != nil }
        for snapshot in pending { await publishStatus(for: snapshot) }
    }

    func snapshots() async -> [LibraryListenNextRequestSnapshot] {
        guard let result = try? await activate() else { return [] }
        for snapshot in result.2 {
            if snapshot.status == .preparing { enqueueIfPreparing(snapshot) }
            if snapshot.isTerminal { await discardAudio(for: snapshot) }
        }
        return await store.snapshots(requesterDeviceID: deviceID, ownerToken: result.ownerToken)
    }

    /// Rechecks the exact durable ticket, local requester, generation and bytes before player use.
    func audioURL(for expected: LibraryListenNextRequestSnapshot) async -> URL? {
        guard expected.requesterDeviceID == deviceID,
              let current = try? await currentContext(),
              current.ownerToken == expected.ownerToken,
              current.generation == expected.operationGeneration,
              let stored = await store.snapshot(expected.requestID), stored == expected,
              [.ready, .selected, .playing].contains(expected.status),
              let offer = expected.audioOffer,
              offer.requesterDeviceID == deviceID,
              let url = localAudioURL(for: expected), Self.audioFile(url, matches: offer) else { return nil }
        return url
    }

    /// Advances queue state only if the caller still holds the exact selected snapshot.
    func transition(
        _ snapshot: LibraryListenNextRequestSnapshot,
        to status: LibraryListenNextRequestSnapshot.Status,
        failure: LibraryListenNextStatus.Failure? = nil
    ) async -> LibraryListenNextRequestSnapshot? {
        guard let current = try? await currentContext(),
              current.ownerToken == snapshot.ownerToken,
              current.generation == snapshot.operationGeneration else { return nil }
        guard let updated = try? await store.transition(from: snapshot, to: status, failure: failure) else { return nil }
        await updateLocalRequest(updated)
        if status == .failed || status == .completed { await discardAudio(for: snapshot) }
        return updated
    }

    func invalidate() {
        context = nil
        tasks.values.forEach { $0.task.cancel() }
        tasks.removeAll()
    }

    private func activate() async throws -> (ownerToken: String, generation: UInt64, [LibraryListenNextRequestSnapshot]) {
        let current = try await currentContext()
        if !sweptStagingOwners.contains(current.ownerToken),
           staging.sweepAbandoned(ownerToken: current.ownerToken) {
            sweptStagingOwners.insert(current.ownerToken)
        }
        let previousSnapshots = await store.allSnapshots()
        if previousSnapshots.contains(where: { $0.ownerToken != current.ownerToken }) {
            for snapshot in previousSnapshots {
                try? FileManager.default.removeItem(at: requestAudioFileURL(for: snapshot))
            }
        }
        if let context, context != current {
            tasks.values.forEach { $0.task.cancel() }
            tasks.removeAll()
            publishedStatusRevisions.removeAll()
            pendingStatusRevisions.removeAll()
        }
        context = current
        let snapshots = try await store.activate(
            ownerToken: current.ownerToken, operationGeneration: current.generation)
        return (current.ownerToken, current.generation, snapshots)
    }

    private func currentContext() async throws -> Context {
        guard let transport else {
            return Context(ownerToken: Self.localOwnerToken(for: deviceID), generation: 1)
        }
        try await transport.verifyOwner()
        guard let firstOwner = await transport.verifiedOwnerToken(), !firstOwner.isEmpty else {
            throw LibraryTransportError.superseded
        }
        let generation = await transport.operationGeneration()
        let generationAfterOwnerCheck = await transport.operationGeneration()
        let ownerAfterGenerationCheck = await transport.verifiedOwnerToken()
        guard generation == generationAfterOwnerCheck, firstOwner == ownerAfterGenerationCheck else {
            throw LibraryTransportError.superseded
        }
        return Context(ownerToken: firstOwner, generation: generation)
    }

    private func validatedStory(_ requested: LibraryHeadlineStory) throws -> LibraryHeadlineStory? {
        guard let model else { return nil }
        let projection = try model.headlineCatalogStore.projection(at: Date())
        return (projection.recent + projection.saved).first {
            $0.id == requested.id && $0.publisherID == requested.publisherID && $0.link == requested.link
        }
    }

    private func selectedVoice() -> ApprovedReadingVoiceID? {
        guard let model,
              let identifier = model.selectedReadingVoiceID,
              let voice = ApprovedReadingVoiceID(rawValue: identifier),
              model.readingVoiceRevision == ArticleNarrationCoordinator.voiceRevision(for: voice) else {
            return nil
        }
        return voice
    }

    private func enqueueIfPreparing(_ snapshot: LibraryListenNextRequestSnapshot) {
        guard snapshot.status == .preparing, tasks[snapshot.requestID] == nil else { return }
        model?.updateListenNextPresentation(snapshot)
        let taskID = UUID()
        let task = Task { [weak self] in
            await self?.prepare(snapshot, taskID: taskID)
            self?.finish(snapshot.requestID, taskID: taskID)
        }
        tasks[snapshot.requestID] = RunningTask(id: taskID, task: task)
    }

    private func finish(_ requestID: String, taskID: UUID) {
        guard tasks[requestID]?.id == taskID else { return }
        tasks.removeValue(forKey: requestID)
    }

    private func prepare(_ snapshot: LibraryListenNextRequestSnapshot, taskID: UUID) async {
        var stage = WorkStage.narration
        var uploadedOffer: LibraryStoryAudioOffer?
        let outputURL = staging.stagingURL(
            ownerToken: snapshot.ownerToken, operationGeneration: snapshot.operationGeneration,
            requesterDeviceID: snapshot.requesterDeviceID, requestID: snapshot.requestID, taskID: taskID)
        var stagingLease: WiltedMacListenNextStaging.Lease?
        defer {
            if let stagingLease { stagingLease.finish() }
            else { try? FileManager.default.removeItem(at: outputURL) }
        }
        do {
            guard let model,
                  let voiceID = snapshot.voiceID,
                  let voice = ApprovedReadingVoiceID(rawValue: voiceID),
                  let voiceRevision = snapshot.voiceRevision,
                  voiceRevision == ArticleNarrationCoordinator.voiceRevision(for: voice),
                  let originalURL = snapshot.story.link else {
                await fail(snapshot, with: .missingVoice)
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            stagingLease = try staging.acquire(
                ownerToken: snapshot.ownerToken, operationGeneration: snapshot.operationGeneration,
                requesterDeviceID: snapshot.requesterDeviceID, requestID: snapshot.requestID, taskID: taskID)
            let request = ArticleNarrationRequest(
                requestID: snapshot.requestID, storyID: snapshot.story.id, originalURL: originalURL,
                voiceID: voice, voiceRevision: voiceRevision, ownerToken: snapshot.ownerToken,
                generation: snapshot.operationGeneration)
            let result = try await narrate(request, outputURL) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.tasks[snapshot.requestID]?.id == taskID,
                          self.tasks[snapshot.requestID]?.task.isCancelled == false else { return }
                    self.model?.updateListenNextProgress(progress)
                }
            }
            guard !Task.isCancelled else { return }
            let contentHash = Self.validatedHash(result.contentHash, fileURL: result.audioURL, byteCount: result.byteCount)
            guard let contentHash, result.audioURL.standardizedFileURL == outputURL.standardizedFileURL else {
                throw ArticleNarrationError.invalidAudio
            }
            let offer = try LibraryStoryAudioOffer(
                requestID: snapshot.requestID, storyID: snapshot.story.id,
                requesterDeviceID: snapshot.requesterDeviceID, voiceID: voiceID, voiceRevision: voiceRevision,
                audioRevision: RevisionID(rawValue: result.revisionID), contentHash: contentHash,
                byteCount: result.byteCount, mediaType: result.mediaType, durationSeconds: result.duration)
            try await verify(snapshot)
            guard await store.snapshot(snapshot.requestID) == snapshot else { return }

            if snapshot.requesterDeviceID != deviceID {
                stage = .transfer
                guard let audioTransport else { throw WiltedMacListenNextError.unavailableTransport }
                uploadedOffer = offer
                try await audioTransport.publishStoryAudio(
                    offer: offer, fileURL: outputURL, expectedOwner: snapshot.ownerToken)
            } else {
                try await verify(snapshot)
                guard await store.snapshot(snapshot.requestID) == snapshot else { return }
                try installReadyAudio(from: outputURL, for: snapshot)
            }
            try await verify(snapshot)
            guard let ready = try await store.setStatus(
                requestID: snapshot.requestID, ownerToken: snapshot.ownerToken,
                operationGeneration: snapshot.operationGeneration, status: .ready, offer: offer) else {
                if let uploadedOffer { await removeStoryAudio(uploadedOffer, expectedOwner: snapshot.ownerToken) }
                return
            }
            await updateLocalRequest(ready)
            if ready.requesterDeviceID == deviceID,
               let readyURL = await audioURL(for: ready) {
                try? await model.storyAudioBecameReady(ready, fileURL: readyURL)
            }
            await publishStatus(for: ready)
        } catch let error as ArticleNarrationError {
            if let uploadedOffer { await removeStoryAudio(uploadedOffer, expectedOwner: snapshot.ownerToken) }
            guard !Task.isCancelled else { return }
            if error == .cancelled { return }
            let failure: LibraryListenNextStatus.Failure
            switch error {
            case .articleUnavailable: failure = .unsafeArticle
            case .voiceUnavailable: failure = .missingVoice
            default: failure = stage == .transfer ? .transferFailed : .narrationFailed
            }
            await fail(snapshot, with: failure)
        } catch {
            if let uploadedOffer { await removeStoryAudio(uploadedOffer, expectedOwner: snapshot.ownerToken) }
            guard !Task.isCancelled else { return }
            await fail(snapshot, with: stage == .transfer ? .transferFailed : .narrationFailed)
        }
    }

    private func verify(_ snapshot: LibraryListenNextRequestSnapshot) async throws {
        let current = try await currentContext()
        guard current.ownerToken == snapshot.ownerToken,
              current.generation == snapshot.operationGeneration,
              let stored = await store.snapshot(snapshot.requestID),
              stored.ownerToken == snapshot.ownerToken,
              stored.operationGeneration == snapshot.operationGeneration,
              stored.status == .preparing else { throw LibraryTransportError.superseded }
    }

    private func fail(_ snapshot: LibraryListenNextRequestSnapshot, with failure: LibraryListenNextStatus.Failure) async {
        guard let failed = try? await store.setStatus(
            requestID: snapshot.requestID, ownerToken: snapshot.ownerToken,
            operationGeneration: snapshot.operationGeneration, status: .failed, failure: failure) else { return }
        await updateLocalRequest(failed)
        await publishStatus(for: failed)
    }

    private func updateLocalRequest(_ snapshot: LibraryListenNextRequestSnapshot) async {
        guard snapshot.requesterDeviceID == deviceID, let model else { return }
        model.updateListenNextPresentation(snapshot)
        await model.refreshListenNextSnapshots([snapshot])
        switch snapshot.status {
        case .cancelled: try? model.storyRequestCancelled(snapshot)
        case .failed: try? model.storyRequestFailed(snapshot)
        default: break
        }
    }

    private func publishStatus(for snapshot: LibraryListenNextRequestSnapshot) async {
        guard snapshot.requesterDeviceID != deviceID, let audioTransport else { return }
        let key = Self.statusKey(for: snapshot)
        let phase: LibraryListenNextStatus.Phase
        switch snapshot.status {
        case .pending, .sent, .preparing: phase = .preparing
        case .ready: phase = .ready
        case .failed: phase = .failed
        case .cancelled: phase = .cancelled
        case .selected, .playing, .completed: return
        }
        let publishedRevision = publishedStatusRevisions[key] ?? 0
        if publishedRevision >= snapshot.statusRevision {
            if let pendingRevision = pendingStatusRevisions[key], pendingRevision <= publishedRevision {
                pendingStatusRevisions.removeValue(forKey: key)
            }
            return
        }
        if let pendingRevision = pendingStatusRevisions[key], pendingRevision > snapshot.statusRevision { return }
        pendingStatusRevisions[key] = max(pendingStatusRevisions[key] ?? 0, snapshot.statusRevision)
        guard let status = try? LibraryListenNextStatus(
            requestID: snapshot.requestID, storyID: snapshot.story.id,
            requesterDeviceID: snapshot.requesterDeviceID, phase: phase,
            statusRevision: snapshot.statusRevision, updatedAt: snapshot.statusUpdatedAt,
            voiceID: snapshot.voiceID, voiceRevision: snapshot.voiceRevision,
            audioOffer: phase == .ready ? snapshot.audioOffer : nil,
            failure: phase == .failed ? snapshot.failure : nil) else { return }
        do {
            try await audioTransport.publishListenNextStatus(status, expectedOwner: snapshot.ownerToken)
            publishedStatusRevisions[key] = max(publishedStatusRevisions[key] ?? 0, snapshot.statusRevision)
            if pendingStatusRevisions[key].map({ $0 <= (publishedStatusRevisions[key] ?? 0) }) == true {
                pendingStatusRevisions.removeValue(forKey: key)
            }
        } catch {
            pendingStatusRevisions[key] = max(pendingStatusRevisions[key] ?? 0, snapshot.statusRevision)
        }
    }

    private static func statusKey(for snapshot: LibraryListenNextRequestSnapshot) -> StatusKey {
        StatusKey(ownerToken: snapshot.ownerToken, deviceID: snapshot.requesterDeviceID, requestID: snapshot.requestID)
    }

    private func localAudioURL(for snapshot: LibraryListenNextRequestSnapshot) -> URL? {
        guard snapshot.requesterDeviceID == deviceID, snapshot.audioOffer?.requestID == snapshot.requestID else { return nil }
        return requestAudioFileURL(for: snapshot)
    }

    private func requestAudioFileURL(for snapshot: LibraryListenNextRequestSnapshot) -> URL {
        return directory.appendingPathComponent(Self.filename(for: snapshot), isDirectory: false)
    }

    /// Promotes local narration only after its exact request generation still owns the ticket.
    private func installReadyAudio(from stagingURL: URL, for snapshot: LibraryListenNextRequestSnapshot) throws {
        let destination = requestAudioFileURL(for: snapshot)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: stagingURL, to: destination)
        try DurableFile.persist(destination)
    }

    private func removeStoryAudio(_ offer: LibraryStoryAudioOffer, expectedOwner: String) async {
        guard let audioTransport else { return }
        await Task.detached(priority: .utility) {
            try? await audioTransport.removeStoryAudio(offer, expectedOwner: expectedOwner)
        }.value
    }

    private func discardAudio(for snapshot: LibraryListenNextRequestSnapshot) async {
        if let offer = snapshot.audioOffer, snapshot.requesterDeviceID != deviceID {
            await removeStoryAudio(offer, expectedOwner: snapshot.ownerToken)
        }
        try? FileManager.default.removeItem(at: requestAudioFileURL(for: snapshot))
    }

    private static func filename(for snapshot: LibraryListenNextRequestSnapshot) -> String {
        let identity = "\(snapshot.requesterDeviceID)\0\(snapshot.requestID)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "listen-next-\(digest).m4a"
    }

    private static func localOwnerToken(for deviceID: String) -> String {
        let digest = SHA256.hash(data: Data(deviceID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "local-\(digest)"
    }

    private static func isSafeHTTPS(_ url: URL?) -> Bool {
        guard let url else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && components?.user == nil && components?.password == nil
    }

    private static func audioFile(_ url: URL, matches offer: LibraryStoryAudioOffer) -> Bool {
        validatedHash(offer.contentHash, fileURL: url, byteCount: offer.byteCount) == offer.contentHash
    }

    private static func validatedHash(_ claimed: String, fileURL: URL, byteCount: Int64) -> String? {
        let normalized = claimed.hasPrefix("sha256:") ? claimed : "sha256:\(claimed)"
        guard MediaHash.isWellFormed(normalized),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size == byteCount,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        let actual = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == normalized ? actual : nil
    }
}
