import Foundation
import Network
import WiltedDomain
import WiltedLibrary
@testable import WiltediOS

/// Fakes for the phone's direct download path: the Mac search, the LAN client, the background task, and
/// a CloudKit transport that counts what reaches it.

/// A latch a test opens to release a wait. Waiting polls, so cancelling the waiting task ends the wait.
final class DirectLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.lock(); open = true; lock.unlock() }
    private var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func wait() async throws {
        while !isOpen {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

final class DirectCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// The 1-based number of this call.
    func next() -> Int { lock.withLock { count += 1; return count } }
}

final class DirectSleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    func record(_ duration: Duration) { lock.lock(); recorded.append(duration); lock.unlock() }
    var values: [Duration] { lock.lock(); defer { lock.unlock() }; return recorded }
}

/// What reached the CloudKit side. `failEverything` makes each server call throw, to show none is needed.
final class DirectCloudCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var intents: [LibraryIntent] = []
    private var calls = 0
    private var failing = false

    var failEverything: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    var requestIDs: [String] {
        lock.withLock { intents.compactMap { if case .requestMedia = $0.action { $0.id } else { nil } } }
    }
    /// Every server call that was attempted, including the intents.
    var serverCalls: Int { lock.withLock { calls } }
    func attempt(_ intent: LibraryIntent? = nil) throws {
        let fails = lock.withLock { () -> Bool in
            calls += 1
            if let intent { intents.append(intent) }
            return failing
        }
        if fails { throw URLError(.notConnectedToInternet) }
    }
}

struct DirectCountingTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    let counter: DirectCloudCounter
    /// What this launch's account check finds; nil leaves the owner unverified (offline).
    var ownerCheck = DirectOwnerCheck()

    // Local bookkeeping: never leaves the phone.
    func verifiedOwnerToken() async -> String? {
        if let confirmed = ownerCheck.confirmed { return confirmed }
        return await inner.verifiedOwnerToken()
    }
    func verifyOwner() async throws { ownerCheck.run() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }

    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        try counter.attempt(); return try await inner.fetchChanges(since: token)
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        try counter.attempt(); return try await inner.push(changes: changes)
    }
    func listIntents() async throws -> [LibraryIntent] { try counter.attempt(); return try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try counter.attempt(); try await inner.publish(record, as: channel)
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try counter.attempt(); return try await inner.fetchDeviceRecords() }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try counter.attempt(); return try await inner.mediaOffers() }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try counter.attempt(); return try await inner.transcript(entryID: entryID, revisionID: revisionID)
    }
    func send(intent: LibraryIntent) async throws {
        try counter.attempt(intent); try await inner.send(intent: intent)
    }
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        try counter.attempt(); return try await inner.fetchMedia(offer, progress: progress)
    }
}

/// The Mac search: answers as told, optionally after a latch, and counts how often it was asked.
final class DirectFakeLocator: LocalMacLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: LocalMacSearch
    private var asked = 0
    var hold: DirectLatch?

    init(_ answer: LocalMacSearch = .found([.hostPort(host: "127.0.0.1", port: 9)])) { self.answer = answer }
    var calls: Int { lock.withLock { asked } }
    func set(_ new: LocalMacSearch) { lock.withLock { answer = new } }

    func locate(within budget: Duration) async -> LocalMacSearch {
        lock.withLock { asked += 1 }
        try? await hold?.wait()
        return lock.withLock { answer }
    }
}

/// The LAN client: the test supplies what each fetch does, and reads back the offsets it was given.
final class DirectFakeSource: DirectMediaSource, @unchecked Sendable {
    typealias Handler = @Sendable (LibraryMediaOffer, Int64, MediaProgressHandler) async throws -> URL
    private let lock = NSLock()
    private var current: Handler
    private var seen: [(entry: ItemID, offset: Int64)] = []

    init(_ handler: @escaping Handler = { _, _, _ in throw LANMediaError.refused }) { current = handler }
    func set(_ handler: @escaping Handler) { lock.withLock { current = handler } }
    var fetches: [(entry: ItemID, offset: Int64)] { lock.withLock { seen } }
    var fetchCount: Int { lock.withLock { seen.count } }

    func fetch(_ offer: LibraryMediaOffer, from offset: Int64, progress: @escaping MediaProgressHandler) async throws -> URL {
        let handler = lock.withLock { () -> Handler in seen.append((offer.entryID, offset)); return current }
        return try await handler(offer, offset, progress)
    }
}

@MainActor
final class DirectFakeTask: LibraryBackgroundTransferTask {
    var expirationHandler: (@MainActor () -> Void)?
    private(set) var progress: (completed: Int64, total: Int64) = (0, 0)
    private(set) var title = ""
    private(set) var subtitle = ""
    private(set) var completion: Bool?

    func setProgress(completed: Int64, total: Int64) { progress = (completed, total) }
    func setText(title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
    func complete(success: Bool) { completion = success }
}

/// Holds the `start` closure the model gives the system, so a test can play the part of the system.
@MainActor
final class DirectFakeScheduler: LibraryBackgroundTransferScheduling {
    private(set) var submissions = 0
    private(set) var titles: [String] = []
    private var start: (@MainActor (any LibraryBackgroundTransferTask) -> Void)?
    var refuse = false

    func submit(title: String, subtitle: String, start: @escaping @MainActor (any LibraryBackgroundTransferTask) -> Void) throws {
        if refuse { throw URLError(.cancelled) }
        submissions += 1
        titles.append(title)
        self.start = start
    }

    /// The system starts the submitted task.
    func begin(_ task: DirectFakeTask) { start?(task) }
}

/// The account check a cold launch makes: counts its runs, and confirms `finds` when set.
final class DirectOwnerCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var found: String?
    private var ran = 0
    var finds: String? {
        get { lock.withLock { found } }
        set { lock.withLock { found = newValue } }
    }
    private var confirmedOwner: String?
    var confirmed: String? { lock.withLock { confirmedOwner } }
    var runs: Int { lock.withLock { ran } }
    func run() { lock.withLock { ran += 1; confirmedOwner = found } }
}
