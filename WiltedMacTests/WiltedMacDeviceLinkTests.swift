import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// Forwards to the in-memory transport, counts link writes, can fail the next ones, and can hold
/// every ready upload until the test releases it, as a slow connection would.
private final class HandshakeTransport: LibraryTransport, @unchecked Sendable {
    private let inner: InMemoryLibraryTransport
    private let lock = NSLock()
    private var linkWrites = 0
    private var failLinks = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var uploadsFail = false

    init(_ inner: InMemoryLibraryTransport) { self.inner = inner }

    var linkWriteCount: Int { lock.withLock { linkWrites } }
    var heldUploads: Int { lock.withLock { held.count } }
    func failNextLinkWrites(_ count: Int) { lock.withLock { failLinks = count } }
    func holdUploads() { lock.withLock { holding = true } }
    func failUploads() { lock.withLock { uploadsFail = true } }
    func releaseUploads() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

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
    func fetchDeviceDirectory() async throws -> LibraryDeviceDirectory? { try await inner.fetchDeviceDirectory() }
    func fetchDeviceLink() async throws -> LibraryDeviceLink? { try await inner.fetchDeviceLink() }

    func publishDeviceLink(_ link: LibraryDeviceLink) async throws {
        let fails = lock.withLock { () -> Bool in
            linkWrites += 1
            guard failLinks > 0 else { return false }
            failLinks -= 1
            return true
        }
        if fails { throw URLError(.notConnectedToInternet) }
        try await inner.publishDeviceLink(link)
    }

    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        if offer.state == .ready {
            if lock.withLock({ uploadsFail }) { throw URLError(.networkConnectionLost) }
            await withCheckedContinuation { continuation in
                let wait = lock.withLock { () -> Bool in
                    guard holding else { return false }
                    held.append(continuation)
                    return true
                }
                if !wait { continuation.resume() }
            }
        }
        try await inner.publishMedia(offer: offer, fileURL: fileURL)
    }
}

/// Hands each intent to the runtime the way the Mac's sink does: media requests are queued, not awaited.
private struct AdmittingSink: LibraryIntentSink {
    let runtime: WiltedMacInboundRuntime
    func receive(_ intent: LibraryIntent) async throws { await runtime.admit(intent) }
}

private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(LibraryMediaRequestStatus.Stage, String?)] = []
    func append(_ stage: LibraryMediaRequestStatus.Stage, _ detail: String?) { lock.withLock { entries.append((stage, detail)) } }
    var stages: [LibraryMediaRequestStatus.Stage] { lock.withLock { entries.map(\.0) } }
    var details: [String?] { lock.withLock { entries.map(\.1) } }
}

/// The Mac's side of the device handshake: it links a device the round it syncs, tells it each
/// request was read and how it is going, never holds a round on an upload, and writes nothing in
/// an idle round.
@MainActor
final class WiltedMacDeviceLinkTests: XCTestCase {
    private let macID = "mac-test"
    private let ipadID = "ipad-b"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Rig {
        let server: InMemoryLibraryServer
        let transport: HandshakeTransport
        let ipad: InMemoryLibraryTransport
        let source: ScriptedAudioSource
        let directory: URL
    }

    private func rig(_ name: String) -> Rig {
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        return Rig(server: server, transport: HandshakeTransport(InMemoryLibraryTransport(deviceID: macID, server: server)),
                   ipad: InMemoryLibraryTransport(deviceID: ipadID, server: server), source: ScriptedAudioSource(),
                   directory: wiltedTemporaryDirectory(name))
    }

    private func runtime(_ rig: Rig) -> WiltedMacInboundRuntime {
        let start = start
        return WiltedMacInboundRuntime(source: rig.source, transport: rig.transport, directory: rig.directory,
                                       deviceID: macID, now: { start })
    }

    private func poller(_ rig: Rig, _ runtime: WiltedMacInboundRuntime) -> WiltedMacInboundPoller {
        WiltedMacInboundPoller(transport: rig.transport, sink: AdmittingSink(runtime: runtime), deviceID: macID,
                               onRead: { polled in await runtime.noteRound(polled) }, sleep: { _ in })
    }

    private func entry(_ raw: String) throws -> ItemID { try ItemID(rawValue: raw) }

    private func prepare(_ rig: Rig, _ raw: String) throws -> ItemID {
        let id = try entry(raw)
        let file = rig.directory.appendingPathComponent("\(raw).m4a")
        try Data(repeating: 7, count: 2_048).write(to: file)
        rig.source.set(id, WiltedMacReadyAudio(
            revisionID: try RevisionID(rawValue: "rev-\(raw)"), contentHash: try MediaHash.sha256(fileAt: file),
            byteCount: 2_048, mediaType: "audio/mp4", durationSeconds: 60, fileURL: file,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(start))))
        return id
    }

    private func announce(_ rig: Rig, at offset: TimeInterval = 0) async throws {
        try await rig.ipad.announceDevice(LibraryDeviceAnnouncement(
            deviceID: ipadID, kind: "iPad", announcedAt: start.addingTimeInterval(offset)))
    }

    private func request(_ rig: Rig, _ entry: ItemID, _ id: String) async throws {
        try await rig.ipad.send(intent: LibraryIntent.requestMedia(entryID: entry, deviceID: ipadID, createdAt: start, id: id))
    }

    private func stage(_ rig: Rig, _ intent: String) async throws -> LibraryMediaRequestStatus.Stage? {
        try await rig.ipad.fetchDeviceLink()?.status(intentID: intent)?.stage
    }

    private func eventually(_ what: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    func testARoundLinksTheDeviceAndAcknowledgesEachRequestWithoutWaitingOnAnUpload() async throws {
        let rig = rig("links-ack")
        let runtime = runtime(rig)
        let poller = poller(rig, runtime)
        let first = try prepare(rig, "ep-1"), second = try prepare(rig, "ep-2")
        try await announce(rig)
        try await request(rig, first, "r-1")
        rig.transport.holdUploads()
        defer { rig.transport.releaseUploads() }

        await poller.pollNow()
        let link = try await rig.ipad.fetchDeviceLink()
        XCTAssertEqual(link?.linkedAt, start, "the device is linked in the round the Mac reads the directory")
        try await eventually("the first upload to start") { rig.transport.heldUploads == 1 }
        let sending = try await stage(rig, "r-1")
        XCTAssertEqual(sending, .sending)

        // A request sent while the first upload runs is read and acknowledged in the next round.
        try await request(rig, second, "r-2")
        await poller.pollNow()
        let cycles = await poller.cycleCount
        XCTAssertEqual(cycles, 2, "neither round waited on the held upload")
        let queued = try await stage(rig, "r-2")
        XCTAssertEqual(queued, .received)

        rig.transport.releaseUploads()
        await runtime.service.drain()
        await poller.pollNow()
        let firstAnswer = try await stage(rig, "r-1")
        let secondAnswer = try await stage(rig, "r-2")
        XCTAssertEqual(firstAnswer, .answered)
        XCTAssertEqual(secondAnswer, .answered)
        let devices = await runtime.links.devices()
        XCTAssertEqual(devices.map(\.kind), ["iPad"])
        XCTAssertEqual(devices.first?.isLinked, true)
        XCTAssertEqual(devices.first?.inFlight, [])
    }

    func testIdleRoundsWriteNoLinkAndARepeatedAnnouncementIsAnsweredAgain() async throws {
        let rig = rig("links-idle")
        let poller = poller(rig, runtime(rig))
        try await announce(rig)
        await poller.pollNow()
        XCTAssertEqual(rig.transport.linkWriteCount, 1)
        for _ in 0..<10 { await poller.pollNow() }
        XCTAssertEqual(rig.transport.linkWriteCount, 1, "an idle round writes no link")

        // A device that still sees no link announces again; the Mac writes the link again.
        try await announce(rig, at: 600)
        await poller.pollNow()
        XCTAssertEqual(rig.transport.linkWriteCount, 2)
    }

    func testARequestReadAgainOrAfterARestartKeepsItsAnswer() async throws {
        let rig = rig("links-restart")
        let first = runtime(rig)
        let entry = try prepare(rig, "ep-1")
        try await announce(rig)
        try await request(rig, entry, "r-1")
        await poller(rig, first).pollNow()
        await first.service.drain()
        let restarted = runtime(rig)
        let poller = poller(rig, restarted)
        await poller.pollNow()
        await poller.pollNow()
        let kept = try await stage(rig, "r-1")
        XCTAssertEqual(kept, .answered, "the ledger keeps a re-read request from going back to received")
    }

    func testTheMacNeverLinksItselfAndLinksADeviceKnownOnlyByItsRecords() async throws {
        let rig = rig("links-records")
        let poller = poller(rig, runtime(rig))
        let item = try entry("ep-1"), revision = try RevisionID(rawValue: "rev-1")
        for device in [macID, ipadID] {
            let record = try DevicePlaybackPosition(deviceID: device, entryID: item, revision: revision, positionSeconds: 5,
                                                    isPlaying: false, epoch: 1, publishedAt: start)
            try await InMemoryLibraryTransport(deviceID: device, server: rig.server).publish(record, as: .progress)
        }
        await poller.pollNow()
        let ipadLink = try await rig.ipad.fetchDeviceLink()
        XCTAssertNotNil(ipadLink, "an older app that never announces is still linked")
        let macLink = try await InMemoryLibraryTransport(deviceID: macID, server: rig.server).fetchDeviceLink()
        XCTAssertNil(macLink)
    }

    func testALinkThatFailedToSaveIsWrittenInTheNextRound() async throws {
        let rig = rig("links-retry")
        let runtime = runtime(rig)
        let poller = poller(rig, runtime)
        try await announce(rig)
        rig.transport.failNextLinkWrites(1)
        await poller.pollNow()
        let none = try await rig.ipad.fetchDeviceLink()
        XCTAssertNil(none)
        let pending = await runtime.links.devices()
        XCTAssertEqual(pending.first?.isLinked, false)
        await poller.pollNow()
        let link = try await rig.ipad.fetchDeviceLink()
        XCTAssertNotNil(link)
    }

    func testAFailedUploadIsReportedInPlainWords() async throws {
        let rig = rig("links-failed")
        let entry = try prepare(rig, "ep-1")
        rig.transport.failUploads()
        let log = StageLog()
        let service = WiltedMacMediaService(
            source: rig.source, transport: rig.transport, accountingURL: nil, now: { [start] in start },
            uploadRetryDelay: .zero, sleep: { _ in },
            reportRequest: { _, stage, detail in log.append(stage, detail) })
        await service.handle(try LibraryIntent.requestMedia(entryID: entry, deviceID: ipadID, createdAt: start, id: "r-1"))
        XCTAssertEqual(log.stages, [.sending, .failed])
        let detail = try XCTUnwrap(log.details.last ?? nil)
        XCTAssertEqual(detail, "The Mac could not send the audio. Try again.")
        XCTAssertFalse(detail.contains("URLError") || detail.contains("NSURLErrorDomain"), "no typed cause leaves the Mac")
    }

    func testTheSyncCardNamesEachDeviceOnceAndItsRequests() throws {
        let item = try entry("ep-1")
        func status(_ id: String, _ stage: LibraryMediaRequestStatus.Stage) -> LibraryMediaRequestStatus {
            LibraryMediaRequestStatus(intentID: id, entryID: item, stage: stage, updatedAt: start)
        }
        let rows = WiltedMacLibrarySyncStatus.deviceRows([
            WiltedMacLinkedDevice(deviceID: "a", kind: "iPad", isLinked: true,
                                  inFlight: [status("1", .sending), status("2", .received), status("3", .received)]),
            WiltedMacLinkedDevice(deviceID: "b", kind: "iPad", isLinked: false, inFlight: []),
            WiltedMacLinkedDevice(deviceID: "c", kind: "iPhone", isLinked: true, inFlight: []),
        ])
        XCTAssertEqual(rows.map(\.label), ["iPad 1", "iPad 2", "iPhone"])
        XCTAssertEqual(rows.map(\.value), ["Linked · sending 1 episode, 2 episodes queued", "Linking…", "Linked"])
    }

    /// A Mac linked only to an iPad names the iPad, and its copy about devices in general names no phone.
    func testAMacLinkedToAnIPadNamesTheIPadAndItsGeneralCopyNamesNoPhone() {
        let rows = WiltedMacLibrarySyncStatus.deviceRows([
            WiltedMacLinkedDevice(deviceID: "a", kind: "iPad", isLinked: true, inFlight: []),
        ])
        XCTAssertEqual(rows.map(\.label), ["iPad"])
        XCTAssertEqual(rows.map(\.value), ["Linked"])
        let now = Date(timeIntervalSince1970: 2000)
        XCTAssertTrue(WiltedPublicationAge.macDetail(now).hasSuffix(
            "Author evidence does not prove your devices have the same library."))
        let general = [
            WiltedMacLibrarySyncStatus.scopeNote,
            WiltedPublicationAge.macDetail(now),
            WiltedPublicationAge.macSidebarSummary(nil, verified: true, held: false, now: now),
            WiltedPublicationAge.macSidebarSummary(now.addingTimeInterval(-300), verified: true, held: false, now: now),
        ]
        for text in general {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("phone"), text)
        }
    }
}
