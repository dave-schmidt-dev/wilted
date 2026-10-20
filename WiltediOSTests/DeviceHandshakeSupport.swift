import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// A clock the test moves by hand.
final class HandshakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time = time.addingTimeInterval(seconds) } }
}

/// What the test makes the phone's reads and announcements do, and what it recorded of them.
final class HandshakeProbe: @unchecked Sendable {
    /// How the phone's read of the device link behaves.
    enum Read: Sendable {
        /// The Mac's link, if it wrote one.
        case normal
        /// The whole read fails, as a dropped connection would.
        case throwing
        /// The round did not read the link at all (`deviceLinkRead` false).
        case unread
        /// The read worked and found nothing.
        case absent
        /// The read worked and found a link written for another device.
        case otherDevice
    }

    private let lock = NSLock()
    private var read = Read.normal
    private var announceFails = false
    private var sent: [LibraryDeviceAnnouncement] = []
    private var attempted = 0
    private var offerReads = 0
    private var linkReads = 0

    var readMode: Read { get { lock.withLock { read } } set { lock.withLock { read = newValue } } }
    var announcementsFail: Bool { get { lock.withLock { announceFails } } set { lock.withLock { announceFails = newValue } } }
    /// Announcements that reached the server.
    var announcements: [LibraryDeviceAnnouncement] { lock.withLock { sent } }
    /// Every announce call, whether it worked or not.
    var announceAttempts: Int { lock.withLock { attempted } }

    /// Reads of the offers and of the link made on their own, outside a round's batched poll.
    var directOfferReads: Int { lock.withLock { offerReads } }
    var directLinkReads: Int { lock.withLock { linkReads } }

    func noteOfferRead() { lock.withLock { offerReads += 1 } }
    func noteLinkRead() { lock.withLock { linkReads += 1 } }
    func noteAttempt() -> Bool { lock.withLock { attempted += 1; return !announceFails } }
    func noteSent(_ announcement: LibraryDeviceAnnouncement) { lock.withLock { sent.append(announcement) } }
}

/// The in-memory transport with the handshake's reads and announcements under the test's control.
struct HandshakeTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    let probe: HandshakeProbe

    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await inner.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }
    func mediaOffers() async throws -> [LibraryMediaOffer] {
        probe.noteOfferRead()
        return try await inner.mediaOffers()
    }
    func intentOutcomes() async throws -> [IntentOutcome] { try await inner.intentOutcomes() }
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        try await inner.fetchMedia(offer, progress: progress)
    }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await inner.transcript(entryID: entryID, revisionID: revisionID)
    }
    func fetchDeviceDirectory() async throws -> LibraryDeviceDirectory? { try await inner.fetchDeviceDirectory() }

    func announceDevice(_ announcement: LibraryDeviceAnnouncement) async throws {
        guard probe.noteAttempt() else { throw LibraryTransportError.transport("offline") }
        try await inner.announceDevice(announcement)
        probe.noteSent(announcement)
    }

    func fetchDeviceLink() async throws -> LibraryDeviceLink? {
        probe.noteLinkRead()
        return try await readLink()
    }

    private func readLink() async throws -> LibraryDeviceLink? {
        switch probe.readMode {
        case .throwing: throw LibraryTransportError.transport("offline")
        case .absent: return nil
        case .otherDevice: return LibraryDeviceLink(deviceID: "another-phone", linkedAt: Date(timeIntervalSince1970: 1_000))
        case .normal, .unread: return try await inner.fetchDeviceLink()
        }
    }

    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
        var result = try await inner.poll(options.subtracting(.deviceLink))
        if options.contains(.deviceLink), probe.readMode != .unread {
            result.deviceLink = try await readLink()
            result.deviceLinkRead = true
        }
        return result
    }
}

/// A library mirror whose account the test chooses, and which it can put under review.
actor HandshakeStore: LibraryStore {
    private var saved: LibraryStoreState
    init(owner: String?) {
        saved = LibraryStoreState()
        saved.ownerToken = owner
    }
    func state() -> LibraryStoreState { saved }
    func commit(_ staged: StagedLibraryBatch) { saved = staged.nextState; saved.revision += 1 }
    func enqueue(_ change: LibraryChange) { saved.enqueue(change) }
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) { saved.acknowledge(result, sent: sent) }
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) { saved.resolveConflict(key, keepLocal: keepLocal) }
    func hold() { saved.reviewHold = true; saved.revision += 1 }
}

/// One phone model over an in-memory Mac, for the device handshake tests: its own clock, defaults and
/// audio cache, and a probe over the transport. Call `tearDown()` when done.
@MainActor
final class HandshakeRig {
    static let owner = "handshake-owner"

    let server = InMemoryLibraryServer(writerDeviceID: "mac")
    let mac: InMemoryLibraryTransport
    let probe = HandshakeProbe()
    let clock = HandshakeClock()
    let suite = "handshake-rig-\(UUID().uuidString)"
    let defaults: UserDefaults
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("handshake-rig-\(UUID().uuidString)")
    private(set) var model: LibraryAppModel!
    private(set) var store: HandshakeStore
    private var localSeq: UInt64 = 0

    /// `storeOwner` is the account the phone's saved library belongs to, `verifiedOwner` the one the
    /// transport proves it is signed in to; both are the same for an ordinary verified phone.
    init(
        storeOwner: String? = HandshakeRig.owner, verifiedOwner: String? = HandshakeRig.owner, deviceKind: String = "iPad",
        timing: LibraryMediaTiming = LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
        handoffTiming: LibraryHandoffTiming = LibraryHandoffTiming(), realClock: Bool = false,
        recovery: LibraryAccountRecovery? = nil, defaults existing: UserDefaults? = nil
    ) throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defaults = existing ?? UserDefaults(suiteName: suite)!
        mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: HandshakeRig.owner)
        store = HandshakeStore(owner: storeOwner)
        model = makeModel(store: store, verifiedOwner: verifiedOwner, deviceKind: deviceKind, timing: timing,
                          handoffTiming: handoffTiming, realClock: realClock, recovery: recovery)
    }

    /// A model over the same Mac, defaults and cache directory, as a relaunch of the app would build.
    func makeModel(
        store: HandshakeStore, verifiedOwner: String?, deviceKind: String = "iPad",
        timing: LibraryMediaTiming = LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
        handoffTiming: LibraryHandoffTiming = LibraryHandoffTiming(), realClock: Bool = false,
        recovery: LibraryAccountRecovery? = nil
    ) -> LibraryAppModel {
        let transport = HandshakeTransport(
            inner: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: verifiedOwner), probe: probe)
        let clock = clock
        let nowProvider: @Sendable () -> Date
        if realClock { nowProvider = { Date() } } else { nowProvider = { clock.now } }
        return LibraryAppModel(
            transport: transport, store: store, deviceID: "phone", deviceKind: deviceKind, recovery: recovery,
            mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("cache")), mediaTiming: timing,
            handoffTiming: handoffTiming, preferences: defaults,
            now: nowProvider, timeZone: TimeZone(identifier: "UTC")!)
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: The Mac's side

    func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    /// The Mac links the phone, as it does when it learns of it.
    func macLinksPhone(requests: [LibraryMediaRequestStatus] = []) async throws {
        try await mac.publishDeviceLink(LibraryDeviceLink(deviceID: "phone", linkedAt: Date(), requests: requests))
    }

    /// The Mac reports the stage of one request.
    func macReports(_ stage: LibraryMediaRequestStatus.Stage, intentID: String, entry raw: String, detail: String? = nil) async throws {
        let status = LibraryMediaRequestStatus(intentID: intentID, entryID: id(raw), stage: stage, detail: detail, updatedAt: Date())
        try await macLinksPhone(requests: [status])
    }

    /// Queues an episode on the Mac and brings it to the phone.
    func queue(_ raw: String) async throws {
        localSeq += 1
        let entry = try LibraryEntry(
            id: id(raw), kind: .podcastEpisode, sourceID: id("show"), title: "Title \(raw)", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: 60)
        let slot = try QueueSlot(entryID: id(raw), sortKey: Double(localSeq))
        let source = LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show")
        let changes: [LibraryChange] = [.source(source), .entry(entry), .slot(slot)]
        let pushed = try await mac.push(changes: changes.enumerated().map {
            PendingLibraryChange(localSeq: localSeq * 10 + UInt64($0.offset), change: $0.element, baseVersion: 0)
        })
        XCTAssertTrue(pushed.failures.isEmpty)
        await model.refresh()
    }

    /// The Mac publishes real audio for `raw`, as its media service would once it answers.
    func macPublishesAudio(_ raw: String) async throws {
        let payload = Data((0..<20_000).map { UInt8($0 % 251) })
        let hash = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let offer = try LibraryMediaOffer(
            entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"), contentHash: hash, byteCount: Int64(payload.count),
            mediaType: "audio/mp4", durationSeconds: 60,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_000))))
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try payload.write(to: file)
        try await mac.publishMedia(offer: offer, fileURL: file)
    }

    /// The id of the request intent the phone sent for `raw`, once it is on the server.
    func requestIntentID(_ raw: String) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let sent = try await mac.listIntents()
            if let found = sent.first(where: { $0.action == .requestMedia(entryID: id(raw)) && $0.deviceID == "phone" }) { return found.id }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the phone never sent its request for \(raw)")
        return ""
    }

    /// Waits up to `timeout` for `condition`.
    func eventually(
        _ what: String, timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
