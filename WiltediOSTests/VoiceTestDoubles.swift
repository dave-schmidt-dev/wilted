import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedListener
import XCTest
@testable import WiltediOS

// Test doubles and fixture specs shared by the voice tests.
// MARK: - Doubles

/// The observe cadence's sleep: returns only when a test releases it, so the loop never runs unbidden.
actor VoiceSleeper {
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func cancelAll() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

/// The engine the player drives: a controllable clock that can also report a natural completion.
final class VoiceFakeEngine: ListenerAudioEngine, LibraryRateAdjustable, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentTime = 0.0
    private var _isPlaying = false
    private var handler: (@Sendable (UInt64) -> Void)?
    private var generation: UInt64 = 0
    private var loads: [URL] = []
    var duration = 600.0
    var rate: Float = 1

    var currentTime: Double {
        get { lock.withLock { _currentTime } }
        set { lock.withLock { _currentTime = newValue } }
    }
    var isPlaying: Bool {
        get { lock.withLock { _isPlaying } }
        set { lock.withLock { _isPlaying = newValue } }
    }
    var loadedURLs: [URL] { lock.withLock { loads } }

    func load(url: URL) throws { try load(url: url, completionGeneration: 0) }
    func load(url: URL, completionGeneration: UInt64) throws {
        lock.withLock {
            loads.append(url)
            generation = completionGeneration
            _currentTime = 0
        }
    }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// The file played out: the engine stops and reports the load it finished.
    func finishNaturally() {
        isPlaying = false
        currentTime = duration
        lock.withLock { handler?(generation) }
    }
}

final class VoiceFakeSession: ListenerAudioSession, @unchecked Sendable {
    func activate() throws {}
    func deactivate() {}
}

final class VoiceFakeNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func clear() {}
}

@MainActor final class VoiceFakeRemote: LibraryRemoteCommands {
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) {}
    func uninstall() {}
}

@MainActor final class VoiceFakeEvents: LibrarySessionEvents {
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {}
}

// MARK: - Fixtures

struct ShowSpec {
    let raw: String
    let title: String
}

struct EpisodeSpec {
    let raw: String
    let title: String
    let show: String
    let sortKey: Double
    var published: Double = 1_600_000_000
}

// MARK: - Target fake

/// A `VoiceCommandTarget` that serves a fixed snapshot and records what it is asked to perform.
@MainActor
final class RecordingTarget: VoiceCommandTarget {
    var snapshot: VoiceSnapshot
    private(set) var performed: [VoiceAction] = []
    var outcome = VoiceOutcome.done

    init(snapshot: VoiceSnapshot) { self.snapshot = snapshot }

    func voiceSnapshot() async -> VoiceSnapshot { snapshot }
    func perform(_ action: VoiceAction) async -> VoiceOutcome {
        performed.append(action)
        return outcome
    }
}

// MARK: - Race and failure doubles

/// A media cache that can hold one `cachedEntries()` answer mid-await, so a test can start playback
/// from somewhere else (CarPlay, the phone) in the window between Siri's check and its start.
actor GatedMediaCache: LibraryMediaCache {
    private let base: FileMediaCache
    private var armed = false
    private(set) var isHeld = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(_ base: FileMediaCache) { self.base = base }

    /// The next `cachedEntries()` reads the cache, then waits for `release()`.
    func arm() { armed = true }

    func release() {
        waiting?.resume()
        waiting = nil
        isHeld = false
    }

    func cachedEntries() async -> [ItemID: CachedMedia] {
        let entries = await base.cachedEntries()
        guard armed else { return entries }
        armed = false
        isHeld = true
        await withCheckedContinuation { waiting = $0 }
        return entries
    }

    func cachedFile(for offer: LibraryMediaOffer) async -> URL? { await base.cachedFile(for: offer) }
    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer) async throws -> URL {
        try await base.adopt(verifiedFile: verifiedFile, for: offer)
    }
    func remove(entryID: ItemID) async throws { try await base.remove(entryID: entryID) }
    func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript? {
        await base.cachedTranscript(entryID: entryID, revisionID: revisionID)
    }
    func storeTranscript(_ transcript: LibraryTranscript) async { await base.storeTranscript(transcript) }
}

/// A transport that refuses to send intents (the Mac is unreachable) and forwards everything else.
struct SendFailingTransport: LibraryTransport {
    let base: InMemoryLibraryTransport

    func operationGeneration() async -> UInt64 { await base.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await base.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await base.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { throw LibraryTransportError.transport("the Mac is unreachable") }
    func listIntents() async throws -> [LibraryIntent] { try await base.listIntents() }
    func publishIntentOutcome(_ outcome: IntentOutcome) async throws { try await base.publishIntentOutcome(outcome) }
    func intentOutcomes() async throws -> [IntentOutcome] { try await base.intentOutcomes() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await base.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await base.fetchDeviceRecords() }
    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws { try await base.publishMedia(offer: offer, fileURL: fileURL) }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await base.mediaOffers() }
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        try await base.fetchMedia(offer, progress: progress)
    }
    func removeMedia(entryID: ItemID) async throws { try await base.removeMedia(entryID: entryID) }
    func publishStats(_ stats: LibraryStats) async throws { try await base.publishStats(stats) }
    func readStats() async throws -> LibraryStats? { try await base.readStats() }
    func publishTranscript(_ transcript: LibraryTranscript) async throws { try await base.publishTranscript(transcript) }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await base.transcript(entryID: entryID, revisionID: revisionID)
    }
    func removeTranscript(entryID: ItemID) async throws { try await base.removeTranscript(entryID: entryID) }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws { try await base.commitFetchedState(token) }
    func commitSentState(_ token: LibraryChangeToken?) async throws { try await base.commitSentState(token) }
}
