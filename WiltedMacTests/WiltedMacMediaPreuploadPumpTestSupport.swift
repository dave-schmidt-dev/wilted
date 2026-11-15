import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

final class PumpTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ current: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.current = current }
    var now: Date { lock.withLock { current } }
    func advance(by interval: TimeInterval) { lock.withLock { current = current.addingTimeInterval(interval) } }
}

final class PumpSleepTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepCalls: [Duration] = []
    private var onSleepHook: (@Sendable (Duration) -> Void)?
    init(onSleep: (@Sendable (Duration) -> Void)? = nil) { self.onSleepHook = onSleep }
    var calls: [Duration] { lock.withLock { sleepCalls } }
    func sleep(for duration: Duration) async throws {
        lock.withLock {
            sleepCalls.append(duration)
            onSleepHook?(duration)
        }
    }
}

final class PumpAsyncLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { cont in
            lock.withLock {
                if isOpen { cont.resume() }
                else { continuation = cont }
            }
        }
    }

    func open() {
        lock.withLock {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}

final class PumpScriptedAudioSource: WiltedMacReadyAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var ready: [ItemID: WiltedMacReadyAudio] = [:]
    private var queue: [ItemID] = []
    private var transcriptStore: [ItemID: LibraryTranscript] = [:]
    private var readyOverride: [ItemID: (audio: WiltedMacReadyAudio?, callsLeft: Int)] = [:]
    private var readyCalls = 0

    /// Makes the next `calls` reads of `readyAudio(for:)` answer `audio`, while `preparedQueued()`
    /// keeps listing what `set` stored: the audio changed after the reconcile that listed it.
    func overrideReady(_ entryID: ItemID, with audio: WiltedMacReadyAudio?, calls: Int) {
        lock.withLock { readyOverride[entryID] = (audio, calls) }
    }

    var readyAudioCalls: Int { lock.withLock { readyCalls } }

    func set(_ entryID: ItemID, _ audio: WiltedMacReadyAudio?) {
        lock.withLock {
            if let audio { ready[entryID] = audio } else { ready.removeValue(forKey: entryID) }
        }
    }

    func setQueueOrder(_ order: [ItemID]) { lock.withLock { queue = order } }
    func setTranscript(_ entryID: ItemID, _ transcript: LibraryTranscript) { lock.withLock { transcriptStore[entryID] = transcript } }
    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? {
        lock.withLock {
            readyCalls += 1
            if let override = readyOverride[entryID], override.callsLeft > 0 {
                readyOverride[entryID] = (override.audio, override.callsLeft - 1)
                return override.audio
            }
            return ready[entryID]
        }
    }
    func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio] { lock.withLock { ready } }

    func preparedQueued() async throws -> WiltedMacPreparedQueue {
        lock.withLock {
            let entries = queue.compactMap { id -> (ItemID, WiltedMacReadyAudio)? in
                guard let audio = ready[id] else { return nil }
                return (id, audio)
            }
            return WiltedMacPreparedQueue(entries: entries, larderIDs: Set(queue))
        }
    }

    /// Runs before every transcript read, so a test can hold the step after the audio is booked.
    func holdTranscriptReads(_ hold: @escaping @Sendable () async -> Void) { lock.withLock { transcriptHold = hold } }
    private var transcriptHold: (@Sendable () async -> Void)?

    func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        if let hold = lock.withLock({ transcriptHold }) { await hold() }
        return lock.withLock {
            guard let transcript = transcriptStore[entryID], transcript.revisionID == revisionID else { return nil }
            return transcript
        }
    }

    func transcripts(for revisions: [ItemID: RevisionID]) async throws -> [ItemID: LibraryTranscript] {
        lock.withLock {
            var result: [ItemID: LibraryTranscript] = [:]
            for (id, rev) in revisions where transcriptStore[id]?.revisionID == rev {
                result[id] = transcriptStore[id]
            }
            return result
        }
    }
}

final class PumpTrackingTransport: LibraryTransport, @unchecked Sendable {
    private let inner: InMemoryLibraryTransport
    private let lock = NSLock()
    private var uploadsCount = 0
    private var concurrentUploads = 0
    private var maxConcurrentUploads = 0
    private var uploadedOrder: [ItemID] = []
    private var failurePlan: [String: @Sendable () -> Error] = [:]
    private var uploadLatches: [String: @Sendable () async -> Void] = [:]
    private var onUploadStarted: (@Sendable (ItemID) -> Void)?

    init(inner: InMemoryLibraryTransport, onUploadStarted: (@Sendable (ItemID) -> Void)? = nil) {
        self.inner = inner
        self.onUploadStarted = onUploadStarted
    }

    var readyUploads: Int { lock.withLock { uploadsCount } }
    var maxConcurrency: Int { lock.withLock { maxConcurrentUploads } }
    var uploadedIDs: [ItemID] { lock.withLock { uploadedOrder } }

    func planFailure(for entryID: String, error: @escaping @Sendable () -> Error) {
        lock.withLock { failurePlan[entryID] = error }
    }

    func clearFailure(for entryID: String) { lock.withLock { failurePlan.removeValue(forKey: entryID) } }

    func setLatch(for entryID: String, latch: @escaping @Sendable () async -> Void) {
        lock.withLock { uploadLatches[entryID] = latch }
    }

    func clearLatch(for entryID: String) { lock.withLock { uploadLatches.removeValue(forKey: entryID) } }

    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await inner.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await inner.mediaOffers() }
    func removeMedia(entryID: ItemID) async throws { try await inner.removeMedia(entryID: entryID) }
    func publishTranscript(_ transcript: LibraryTranscript) async throws { try await inner.publishTranscript(transcript) }
    func removeTranscript(entryID: ItemID) async throws { try await inner.removeTranscript(entryID: entryID) }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await inner.transcript(entryID: entryID, revisionID: revisionID)
    }

    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        if offer.state == .ready {
            let latch = lock.withLock { () -> (@Sendable () async -> Void)? in
                concurrentUploads += 1
                if concurrentUploads > maxConcurrentUploads { maxConcurrentUploads = concurrentUploads }
                onUploadStarted?(offer.entryID)
                return uploadLatches[offer.entryID.rawValue]
            }
            if let latch { await latch() }
            let plannedError = lock.withLock { failurePlan[offer.entryID.rawValue]?() }
            if let plannedError {
                lock.withLock { concurrentUploads -= 1 }
                throw plannedError
            }
            try await inner.publishMedia(offer: offer, fileURL: fileURL)
            lock.withLock {
                uploadsCount += 1
                uploadedOrder.append(offer.entryID)
                concurrentUploads -= 1
            }
            return
        }
        try await inner.publishMedia(offer: offer, fileURL: fileURL)
    }
}
