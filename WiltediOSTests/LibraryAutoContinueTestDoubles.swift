import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
@testable import WiltediOS

// Test doubles for `LibraryAutoContinueTests`: a fake engine that can finish naturally, inert
// session/Now Playing/remote/events, and a cache whose lookups a `LookupGate` can hold.

final class AutoEngine: ListenerAudioEngine, LibraryRateAdjustable, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentTime = 0.0
    private var _isPlaying = false
    private var handler: (@Sendable (UInt64) -> Void)?
    private var generation: UInt64 = 0
    var duration = 600.0
    var rate: Float = 1
    private(set) var loadedStarts: [Double] = []

    var currentTime: Double {
        get { lock.withLock { _currentTime } }
        set { lock.withLock { _currentTime = newValue } }
    }
    var isPlaying: Bool {
        get { lock.withLock { _isPlaying } }
        set { lock.withLock { _isPlaying = newValue } }
    }
    func load(url: URL) throws { try load(url: url, completionGeneration: 0) }
    func load(url: URL, completionGeneration: UInt64) throws { generation = completionGeneration; currentTime = 0 }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) { self.handler = handler }

    func finishNaturally(reporting reported: UInt64? = nil) {
        isPlaying = false
        currentTime = duration
        handler?(reported ?? generation)
    }
}

final class AutoSession: ListenerAudioSession, @unchecked Sendable {
    func activate() throws {}
    func deactivate() {}
}

final class AutoNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func clear() {}
}

@MainActor final class AutoRemote: LibraryRemoteCommands {
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) {}
    func uninstall() {}
}

@MainActor final class AutoEvents: LibrarySessionEvents {
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {}
}

/// Holds cache lookups so a test can act between two of them deterministically, without sleeping.
/// The wrapper captures the entries before it holds, so what the caller receives was decided
/// before the hold began and the test's mutation lands strictly after it.
actor LookupGate {
    private enum WaitError: Error { case timedOut }
    private var armed = false
    private var heldCount = 0
    private var heldLookups: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var heldOrder: [UUID] = []
    private var observers: [UUID: CheckedContinuation<Void, Error>] = [:]

    func arm() { armed = true }

    /// Called by the cache wrapper after it captured the entries: wakes the test, then waits.
    func hold() async {
        guard armed else { return }
        heldCount += 1
        observers.values.forEach { $0.resume() }
        observers.removeAll()
        let id = UUID()
        await withCheckedContinuation { continuation in
            heldLookups[id] = continuation
            heldOrder.append(id)
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.releaseHeld(id)
            }
        }
    }

    /// Waits until a lookup is held right now.
    func waitForHold() async throws {
        if heldCount > 0 { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            observers[id] = continuation
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.timeoutWait(id)
            }
        }
    }

    private func timeoutWait(_ id: UUID) {
        observers.removeValue(forKey: id)?.resume(throwing: WaitError.timedOut)
    }

    private func releaseHeld(_ id: UUID) {
        guard let continuation = heldLookups.removeValue(forKey: id) else { return }
        heldOrder.removeAll { $0 == id }
        heldCount -= 1
        continuation.resume()
    }

    /// Lets the oldest held lookup return, keeping the gate armed.
    func releaseNext() {
        guard let id = heldOrder.first else { return }
        releaseHeld(id)
    }

    /// Lets every held lookup return and stops holding new ones.
    func disarm() {
        armed = false
        heldOrder.forEach { heldLookups.removeValue(forKey: $0)?.resume() }
        heldLookups.removeAll()
        heldOrder.removeAll()
        heldCount = 0
    }
}

/// A `LibraryMediaCache` whose lookups a `LookupGate` can hold.
actor AutoContinueGatedMediaCache: LibraryMediaCache {
    let base: FileMediaCache
    let gate: LookupGate

    init(base: FileMediaCache, gate: LookupGate) {
        self.base = base
        self.gate = gate
    }

    func storedAudioByteCounts() async -> [ItemID: Int64] { await base.storedAudioByteCounts() }
    func cachedEntries() async -> [ItemID: CachedMedia] {
        let entries = await base.cachedEntries()
        await gate.hold()
        return entries
    }

    func bindOwner(ownerToken: String?, libraryScope: String, held: Bool) async throws {
        try await base.bindOwner(ownerToken: ownerToken, libraryScope: libraryScope, held: held)
    }
    func admission(entryID: ItemID, ownerToken: String, libraryScope: String, transportGeneration: UInt64) async -> MediaCacheAdmission? {
        await base.admission(entryID: entryID, ownerToken: ownerToken, libraryScope: libraryScope, transportGeneration: transportGeneration)
    }
    func revokePreparation(entryID: ItemID) async throws { try await base.revokePreparation(entryID: entryID) }
    func verifies(_ cached: CachedMedia) async -> Bool { await base.verifies(cached) }
    func permits(_ admission: MediaCacheAdmission, for offer: LibraryMediaOffer) async -> Bool {
        await base.permits(admission, for: offer)
    }
    func cachedFile(for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async -> URL? {
        await base.cachedFile(for: offer, admission: admission)
    }
    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async throws -> URL {
        try await base.adopt(verifiedFile: verifiedFile, for: offer, admission: admission)
    }
    func remove(entryID: ItemID) async throws { try await base.remove(entryID: entryID) }
    func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript? {
        await base.cachedTranscript(entryID: entryID, revisionID: revisionID)
    }
    func storeTranscript(_ transcript: LibraryTranscript) async { await base.storeTranscript(transcript) }
}
