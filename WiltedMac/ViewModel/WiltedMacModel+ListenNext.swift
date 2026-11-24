import Foundation
import ObjectiveC
import Observation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

private nonisolated(unsafe) var listenNextStoreKey: UInt8 = 0
private nonisolated(unsafe) var listenNextCoordinatorKey: UInt8 = 0
private nonisolated(unsafe) var listenNextRemoteCoordinatorKey: UInt8 = 0
private nonisolated(unsafe) var listenNextPresentationKey: UInt8 = 0

@Observable
@MainActor
final class WiltedMacListenNextPresentation {
    var actionMessage: String?
    var isRequestInProgress = false
}

extension WiltedMacModel {
    var listenNextRequestStore: WiltedMacListenNextStore {
        if let existing = objc_getAssociatedObject(self, &listenNextStoreKey) as? WiltedMacListenNextStore {
            return existing
        }
        let fileURL = libraryURL.deletingLastPathComponent().appendingPathComponent("listen-next-local.json")
        let created = WiltedMacListenNextStore(fileURL: fileURL)
        objc_setAssociatedObject(self, &listenNextStoreKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return created
    }

    var listenNextCoordinator: WiltedMacListenNextCoordinator? {
        if let existing = objc_getAssociatedObject(self, &listenNextCoordinatorKey) as? WiltedMacListenNextCoordinator {
            return existing
        }
        let directory = libraryURL.deletingLastPathComponent().appendingPathComponent("listen-next-audio", isDirectory: true)
        let created = try? WiltedMacListenNextCoordinator(
            model: self, transport: nil, directory: directory, deviceID: libraryDeviceID())
        objc_setAssociatedObject(self, &listenNextCoordinatorKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return created
    }

    /// Replaces local narration for tests that exercise the real Listen next request and cancel paths.
    func installListenNextCoordinatorForTesting(_ coordinator: WiltedMacListenNextCoordinator) {
        (objc_getAssociatedObject(self, &listenNextCoordinatorKey) as? WiltedMacListenNextCoordinator)?.invalidate()
        objc_setAssociatedObject(self, &listenNextCoordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    var listenNextRemoteCoordinator: WiltedMacListenNextCoordinator? {
        get { objc_getAssociatedObject(self, &listenNextRemoteCoordinatorKey) as? WiltedMacListenNextCoordinator }
        set {
            (objc_getAssociatedObject(self, &listenNextRemoteCoordinatorKey) as? WiltedMacListenNextCoordinator)?.invalidate()
            objc_setAssociatedObject(self, &listenNextRemoteCoordinatorKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private var listenNextPresentation: WiltedMacListenNextPresentation {
        if let existing = objc_getAssociatedObject(self, &listenNextPresentationKey) as? WiltedMacListenNextPresentation {
            return existing
        }
        let created = WiltedMacListenNextPresentation()
        objc_setAssociatedObject(self, &listenNextPresentationKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return created
    }

    var listenNextActionMessage: String? { listenNextPresentation.actionMessage }
    var isListenNextRequestInProgress: Bool { listenNextPresentation.isRequestInProgress }

    func updateListenNextPresentation(_ snapshot: LibraryListenNextRequestSnapshot) {
        guard snapshot.requesterDeviceID == libraryDeviceID() else { return }
        let presentation = listenNextPresentation
        switch snapshot.status {
        case .pending, .sent, .preparing:
            presentation.actionMessage = "Preparing story audio."
            presentation.isRequestInProgress = true
        case .ready, .selected, .playing:
            presentation.actionMessage = "Story audio is ready in your queue."
            presentation.isRequestInProgress = false
        case .failed:
            presentation.actionMessage = snapshot.failure == .missingVoice
                ? "Choose a voice to listen to stories."
                : "Story audio could not be prepared."
            presentation.isRequestInProgress = false
        case .cancelled:
            presentation.actionMessage = "Story request cancelled."
            presentation.isRequestInProgress = false
        case .completed:
            presentation.actionMessage = "Story finished."
            presentation.isRequestInProgress = false
        }
    }

    func updateListenNextProgress(_ progress: ArticleNarrationProgress) {
        let phase: String
        switch progress.stage {
        case .fetching: phase = "Finding the story"
        case .extracting: phase = "Reading the story"
        case .loadingVoice: phase = "Loading the voice"
        case .synthesizing: phase = "Creating story audio"
        case .saving: phase = "Finishing story audio"
        }
        if let fraction = progress.fraction, fraction.isFinite, (0...1).contains(fraction) {
            listenNextPresentation.actionMessage = "\(phase) · \(Int((fraction * 100).rounded()))%"
        } else {
            listenNextPresentation.actionMessage = "\(phase)…"
        }
        listenNextPresentation.isRequestInProgress = true
    }

    /// Creates a durable local request for the Mac's own queue.
    @discardableResult
    func listenNextRequest(story: LibraryHeadlineStory, anchorID: ItemID?) async throws -> LibraryListenNextRequestSnapshot {
        guard selectedReadingVoiceID != nil, readingVoiceRevision != nil else {
            listenNextPresentation.actionMessage = "Choose a voice to listen to stories."
            listenNextPresentation.isRequestInProgress = false
            throw WiltedMacListenNextError.missingVoice
        }
        guard let coordinator = listenNextCoordinator else {
            listenNextPresentation.actionMessage = "Listen next is unavailable right now."
            throw WiltedMacListenNextError.unavailableTransport
        }
        listenNextPresentation.actionMessage = "Queueing story audio."
        listenNextPresentation.isRequestInProgress = true
        let intent = try LibraryIntent.listenNext(story: story, anchorID: anchorID, deviceID: libraryDeviceID())
        do {
            _ = try await coordinator.handle(intent) { snapshot in
                try self.recordStoryListenNext(snapshot, holdEpoch: self.playback?.listenNextHoldEpoch ?? 0)
            }
        } catch {
            listenNextPresentation.actionMessage = "Story audio could not be queued."
            listenNextPresentation.isRequestInProgress = false
            throw error
        }
        guard let snapshot = await listenNextRequestStore.snapshot(intent.id) else {
            listenNextPresentation.actionMessage = "That story is no longer available."
            listenNextPresentation.isRequestInProgress = false
            throw WiltedMacListenNextError.unavailableStory
        }
        updateListenNextPresentation(snapshot)
        return snapshot
    }

    /// Records cancellation before it interrupts narration or removes request-scoped audio.
    func cancelListenNextRequest(_ requestID: String) async throws {
        guard let coordinator = listenNextCoordinator else { throw WiltedMacListenNextError.unavailableTransport }
        let intent = try LibraryIntent.cancelListenNext(requestID: requestID, deviceID: libraryDeviceID())
        let outcome = try await coordinator.handle(intent)
        guard outcome.isApplied else { throw WiltedMacListenNextError.unavailableTransport }
    }

    func listenNextSnapshots() async -> [LibraryListenNextRequestSnapshot] {
        await listenNextCoordinator?.snapshots() ?? []
    }

    func listenNextAudioURL(for snapshot: LibraryListenNextRequestSnapshot) async -> URL? {
        await listenNextCoordinator?.audioURL(for: snapshot)
    }

    @discardableResult
    func setListenNextStatus(
        _ snapshot: LibraryListenNextRequestSnapshot,
        to status: LibraryListenNextRequestSnapshot.Status,
        failure: LibraryListenNextStatus.Failure? = nil
    ) async -> LibraryListenNextRequestSnapshot? {
        await listenNextCoordinator?.transition(snapshot, to: status, failure: failure)
    }
}
