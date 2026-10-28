import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// Serves a scripted ready revision and transcript; never touches a store.
private final class ScriptedTranscriptSource: WiltedMacReadyAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var audio: [ItemID: WiltedMacReadyAudio] = [:]
    private var transcripts: [ItemID: LibraryTranscript] = [:]

    func set(_ entryID: ItemID, audio value: WiltedMacReadyAudio?, transcript: LibraryTranscript?) {
        lock.withLock { audio[entryID] = value; transcripts[entryID] = transcript }
    }

    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? { lock.withLock { audio[entryID] } }

    func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio] { lock.withLock { audio } }

    func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        lock.withLock { transcripts[entryID].flatMap { $0.revisionID == revisionID ? $0 : nil } }
    }
}

private final class TranscriptClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Hands offers back the way CloudKit does, encoded and decoded, and records every audio and
/// transcript write the service makes.
private final class WireTransport: LibraryTransport, @unchecked Sendable {
    private let inner: InMemoryLibraryTransport
    private let lock = NSLock()
    private var log: [String] = []

    init(_ inner: InMemoryLibraryTransport) { self.inner = inner }

    var writes: [String] { lock.withLock { log } }
    private func record(_ write: String) { lock.withLock { log.append(write) } }

    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await inner.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }
    func removeMedia(entryID: ItemID) async throws { try await inner.removeMedia(entryID: entryID) }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await inner.transcript(entryID: entryID, revisionID: revisionID)
    }

    func mediaOffers() async throws -> [LibraryMediaOffer] {
        try JSONDecoder().decode([LibraryMediaOffer].self, from: JSONEncoder().encode(try await inner.mediaOffers()))
    }

    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        record("offer \(offer.entryID.rawValue) \(offer.state.rawValue)")
        try await inner.publishMedia(offer: offer, fileURL: fileURL)
    }

    func publishTranscript(_ transcript: LibraryTranscript) async throws {
        record("transcript \(transcript.entryID.rawValue) \(transcript.revisionID.rawValue)")
        try await inner.publishTranscript(transcript)
    }

    func removeTranscript(entryID: ItemID) async throws {
        record("remove transcript \(entryID.rawValue)")
        try await inner.removeTranscript(entryID: entryID)
    }
}

@MainActor
final class WiltedMacTranscriptPublishTests: XCTestCase {
    private let macID = "mac-test"
    private let phoneID = "iphone-a"
    private let tabletID = "ipad-b"

    @MainActor private struct Rig {
        let mac: InMemoryLibraryTransport
        let phone: InMemoryLibraryTransport
        let source = ScriptedTranscriptSource()
        let clock = TranscriptClock()
        let directory: URL
        let runtime: WiltedMacInboundRuntime

        init(directory: URL, macID: String, phoneID: String) {
            let server = InMemoryLibraryServer(writerDeviceID: macID)
            mac = InMemoryLibraryTransport(deviceID: macID, server: server)
            phone = InMemoryLibraryTransport(deviceID: phoneID, server: server)
            self.directory = directory
            let clock = self.clock, source = self.source, mac = self.mac
            runtime = WiltedMacInboundRuntime(
                source: source, transport: mac, directory: directory, now: { clock.now })
        }
    }

    private func rig(_ name: String) -> Rig { Rig(directory: wiltedTemporaryDirectory(name), macID: macID, phoneID: phoneID) }
    private func id(_ raw: String) throws -> ItemID { try ItemID(rawValue: raw) }
    private func rev(_ raw: String) throws -> RevisionID { try RevisionID(rawValue: raw) }

    /// A preparation time finer than the wire's milliseconds, as the producer stamps it.
    private let fineTime = Date(timeIntervalSince1970: 1_800_000_000.123456)

    /// A service over the rig's source and server that reads and writes `accounting`, as one
    /// launch of the Mac app would.
    private func launch(_ rig: Rig, accounting: String = "relaunch-accounting.json") -> (WiltedMacMediaService, WireTransport) {
        let wire = WireTransport(rig.mac)
        let clock = rig.clock
        let service = WiltedMacMediaService(
            source: rig.source, transport: wire, accountingURL: rig.directory.appendingPathComponent(accounting), now: { clock.now })
        return (service, wire)
    }

    private func audio(_ rig: Rig, revision: String, preparedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> WiltedMacReadyAudio {
        let file = rig.directory.appendingPathComponent("\(revision).m4a")
        try Data(repeating: 7, count: 2_048).write(to: file)
        return WiltedMacReadyAudio(
            revisionID: try rev(revision), contentHash: try MediaHash.sha256(fileAt: file), byteCount: 2_048,
            mediaType: "audio/mp4", durationSeconds: 30, fileURL: file,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(preparedAt)))
    }

    private func transcript(_ entry: ItemID, revision: String, cues: Int = 3) throws -> LibraryTranscript {
        try LibraryTranscript(
            entryID: entry, revisionID: rev(revision),
            cues: (0..<cues).map { LibraryTranscriptCue(start: Double($0), end: Double($0) + 0.5, text: "cue \($0)") })
    }

    private func request(_ rig: Rig, _ entry: ItemID, from device: String, _ intentID: String) throws -> LibraryIntent {
        try LibraryIntent.requestMedia(entryID: entry, deviceID: device, createdAt: rig.clock.now, id: intentID)
    }

    private func cached(_ rig: Rig, _ entry: ItemID, _ revision: String, from device: String, _ intentID: String) throws -> LibraryIntent {
        try LibraryIntent.mediaCached(entryID: entry, revisionID: rev(revision), deviceID: device, createdAt: rig.clock.now, id: intentID)
    }

    func testARequestPublishesTheTranscriptAndTheWithdrawalRemovesItWithTheAudio() async throws {
        let rig = rig("transcript-publish")
        let entry = try id("episode-a")
        let expected = try transcript(entry, revision: "rev-1")
        rig.source.set(entry, audio: try audio(rig, revision: "rev-1"), transcript: expected)

        let before = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertNil(before)
        await rig.runtime.consume(try request(rig, entry, from: phoneID, "p-1"))
        let published = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertEqual(published, expected)
        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.count, 1)

        await rig.runtime.consume(try cached(rig, entry, "rev-1", from: phoneID, "p-2"))
        let gone = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertNil(gone, "withdrawn once every requester cached the audio")
        let remaining = try await rig.phone.mediaOffers()
        XCTAssertEqual(remaining.first?.state, .notReady)
        XCTAssertFalse(remaining.contains { $0.isPrepared })
    }

    func testTheTranscriptStaysUntilEveryRequesterHasCachedTheAudio() async throws {
        let rig = rig("transcript-two-requesters")
        let entry = try id("episode-b")
        rig.source.set(entry, audio: try audio(rig, revision: "rev-1"), transcript: try transcript(entry, revision: "rev-1"))
        await rig.runtime.consume(try request(rig, entry, from: phoneID, "b-1"))
        await rig.runtime.consume(try request(rig, entry, from: tabletID, "b-2"))
        await rig.runtime.consume(try cached(rig, entry, "rev-1", from: phoneID, "b-3"))
        let held = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertNotNil(held)
        await rig.runtime.consume(try cached(rig, entry, "rev-1", from: tabletID, "b-4"))
        let gone = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertNil(gone)
    }

    func testAMissingTranscriptDoesNotBlockTheAudioAndALaterRequestPublishesIt() async throws {
        let rig = rig("transcript-late")
        let entry = try id("episode-c")
        let media = try audio(rig, revision: "rev-1")
        rig.source.set(entry, audio: media, transcript: nil)
        await rig.runtime.consume(try request(rig, entry, from: phoneID, "c-1"))
        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.count, 1, "audio is offered without a transcript")
        let none = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertNil(none)

        let late = try transcript(entry, revision: "rev-1")
        rig.source.set(entry, audio: media, transcript: late)
        await rig.runtime.consume(try request(rig, entry, from: tabletID, "c-2"))
        let seen = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertEqual(seen, late)
    }

    func testANewRevisionReplacesTheTranscriptAndAStaleOneIsDropped() async throws {
        let rig = rig("transcript-revisions")
        let entry = try id("episode-d")
        rig.source.set(entry, audio: try audio(rig, revision: "rev-1"), transcript: try transcript(entry, revision: "rev-1"))
        await rig.runtime.consume(try request(rig, entry, from: phoneID, "d-1"))

        rig.source.set(entry, audio: try audio(rig, revision: "rev-2"), transcript: try transcript(entry, revision: "rev-2", cues: 5))
        await rig.runtime.consume(try request(rig, entry, from: tabletID, "d-2"))
        let old = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        let new = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-2"))
        XCTAssertNil(old)
        XCTAssertEqual(new?.cues.count, 5)

        // A revision with no transcript must not leave the previous revision's one behind.
        rig.source.set(entry, audio: try audio(rig, revision: "rev-3"), transcript: nil)
        await rig.runtime.consume(try request(rig, entry, from: phoneID, "d-3"))
        let stale = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-2"))
        XCTAssertNil(stale)
    }

    func testNotReadyAndSevenDayExpiryAlsoWithdrawTheTranscript() async throws {
        let rig = rig("transcript-expiry")
        let entry = try id("episode-e")
        rig.source.set(entry, audio: try audio(rig, revision: "rev-1"), transcript: try transcript(entry, revision: "rev-1"))
        await rig.runtime.consume(try request(rig, entry, from: phoneID, "e-1"))
        rig.clock.advance(WiltedMacMediaService.timeToLive + 60)
        await rig.runtime.service.sweepExpired()
        let expired = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertNil(expired)

        let other = try id("episode-f")
        rig.source.set(other, audio: try audio(rig, revision: "rev-9"), transcript: try transcript(other, revision: "rev-9"))
        await rig.runtime.consume(try request(rig, other, from: phoneID, "f-1"))
        rig.source.set(other, audio: nil, transcript: nil)
        await rig.runtime.consume(try request(rig, other, from: tabletID, "f-2"))
        let dropped = try await rig.phone.transcript(entryID: other, revisionID: rev("rev-9"))
        XCTAssertNil(dropped, "notReady drops the transcript with the audio")
    }

    func testReconcilePublishesTheTranscriptOfAnAlreadyCachedEpisodeWithoutARequest() async throws {
        let rig = rig("transcript-reconcile")
        let withTranscript = try id("episode-g")
        let without = try id("episode-h")
        let expected = try transcript(withTranscript, revision: "rev-1")
        rig.source.set(withTranscript, audio: try audio(rig, revision: "rev-1"), transcript: expected)
        rig.source.set(without, audio: try audio(rig, revision: "rev-2"), transcript: nil)

        let ok = await rig.runtime.service.reconcileAvailable()
        XCTAssertTrue(ok)

        let published = try await rig.phone.transcript(entryID: withTranscript, revisionID: rev("rev-1"))
        XCTAssertEqual(published, expected)
        let none = try await rig.phone.transcript(entryID: without, revisionID: rev("rev-2"))
        XCTAssertNil(none)
        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.filter { $0.state == .ready }.count, 0, "publishing a transcript uploads no audio")
    }

    func testTheTranscriptSurvivesTheAckWhileTheEntryStaysPreparedAndLeavesWithTheLarder() async throws {
        let rig = rig("transcript-survives-ack")
        let entry = try id("episode-i")
        let expected = try transcript(entry, revision: "rev-1")
        rig.source.set(entry, audio: try audio(rig, revision: "rev-1"), transcript: expected)
        _ = await rig.runtime.service.reconcileAvailable()
        await rig.runtime.consume(try request(rig, entry, from: phoneID, "i-1"))
        await rig.runtime.consume(try cached(rig, entry, "rev-1", from: phoneID, "i-2"))

        let held = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertEqual(held, expected, "a phone that lost its copy, or asks later, can still fetch it")
        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.state, .available)

        rig.source.set(entry, audio: nil, transcript: nil)
        _ = await rig.runtime.service.reconcileAvailable()
        let gone = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertNil(gone, "it goes when the entry leaves the prepared Larder")
    }

    func testARelaunchWithAnUnchangedLarderWritesNothing() async throws {
        let rig = rig("transcript-relaunch")
        let entry = try id("episode-r")
        rig.source.set(entry, audio: try audio(rig, revision: "rev-1", preparedAt: fineTime), transcript: try transcript(entry, revision: "rev-1"))
        let (first, firstWire) = launch(rig)
        _ = await first.reconcileAvailable()
        _ = await first.reconcileAvailable()
        XCTAssertEqual(firstWire.writes, ["offer episode-r available", "transcript episode-r rev-1"])

        let (again, againWire) = launch(rig)
        _ = await again.reconcileAvailable()
        _ = await again.reconcileAvailable()
        XCTAssertEqual(againWire.writes, [], "a relaunch republishes no offer and no transcript")
        let held = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-1"))
        XCTAssertNotNil(held)
    }

    func testARequestAfterARelaunchAddsARequesterWithoutUploadingTheAudioAgain() async throws {
        let rig = rig("transcript-relaunch-request")
        let entry = try id("episode-s")
        rig.source.set(entry, audio: try audio(rig, revision: "rev-1", preparedAt: fineTime), transcript: try transcript(entry, revision: "rev-1"))
        let (first, _) = launch(rig)
        _ = await first.reconcileAvailable()
        await first.handle(try request(rig, entry, from: phoneID, "s-1"))

        let (again, againWire) = launch(rig)
        _ = await again.reconcileAvailable()
        await again.handle(try request(rig, entry, from: tabletID, "s-2"))
        XCTAssertFalse(againWire.writes.contains("offer episode-s ready"), "the audio is already offered: \(againWire.writes)")
        let holding = await again.isHolding(entryID: entry, revisionID: try rev("rev-1"))
        XCTAssertTrue(holding)
    }

    func testRepublishingTheSameRevisionKeepsItsTranscript() async throws {
        let rig = rig("transcript-same-revision")
        let entry = try id("episode-t")
        let text = try transcript(entry, revision: "rev-1")
        rig.source.set(entry, audio: try audio(rig, revision: "rev-1"), transcript: text)
        let (service, wire) = launch(rig)
        _ = await service.reconcileAvailable()

        rig.source.set(entry, audio: try audio(rig, revision: "rev-1", preparedAt: fineTime.addingTimeInterval(60)), transcript: text)
        _ = await service.reconcileAvailable()
        XCTAssertEqual(wire.writes, ["offer episode-t available", "transcript episode-t rev-1", "offer episode-t available"],
                       "a new preparation of the same revision keeps its transcript")
    }

    func testANewRevisionReplacesTheTranscriptOnce() async throws {
        let rig = rig("transcript-new-revision")
        let entry = try id("episode-u")
        rig.source.set(entry, audio: try audio(rig, revision: "rev-1"), transcript: try transcript(entry, revision: "rev-1"))
        let (service, wire) = launch(rig)
        _ = await service.reconcileAvailable()

        rig.source.set(entry, audio: try audio(rig, revision: "rev-2"), transcript: try transcript(entry, revision: "rev-2"))
        _ = await service.reconcileAvailable()
        _ = await service.reconcileAvailable()
        XCTAssertEqual(wire.writes, [
            "offer episode-u available", "transcript episode-u rev-1",
            "offer episode-u available", "remove transcript episode-u", "transcript episode-u rev-2"
        ])
        let current = try await rig.phone.transcript(entryID: entry, revisionID: rev("rev-2"))
        XCTAssertNotNil(current)
    }
}
