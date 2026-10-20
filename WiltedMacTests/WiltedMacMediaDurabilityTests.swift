import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac
@testable import WiltedProducer

/// Writes the accounting through the central replacement primitive, failing the folder sync of
/// chosen saves or throwing before the rename.
private final class ScriptedAccountingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var saves = 0
    private let uncertainSaves: Set<Int>
    private let failingSave: Int?

    init(uncertainSaves: Set<Int> = [], failingBeforeRename save: Int? = nil) {
        self.uncertainSaves = uncertainSaves
        failingSave = save
    }

    var calls: Int { lock.withLock { saves } }

    var write: WiltedMacMediaService.AccountingWriter {
        { [self] data, url in
            let save = lock.withLock { () -> Int in
                saves += 1
                return saves
            }
            if save == failingSave { throw POSIXError(.ENOSPC) }
            guard uncertainSaves.contains(save) else { return try DurableFile.replace(data, to: url) }
            return try DurableFile.$directorySyncInterceptor.withValue({ _ in throw POSIXError(.EIO) }) {
                try DurableFile.replace(data, to: url)
            }
        }
    }
}

/// Records the stages the service reports for a request.
private final class RequestStageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LibraryMediaRequestStatus.Stage] = []

    var stages: [LibraryMediaRequestStatus.Stage] { lock.withLock { storage } }

    func append(_ stage: LibraryMediaRequestStatus.Stage) { lock.withLock { storage.append(stage) } }
}

/// Forwards to the in-memory transport and counts ready-audio uploads.
private final class CountingMediaTransport: LibraryTransport, @unchecked Sendable {
    private let inner: InMemoryLibraryTransport
    private let lock = NSLock()
    private var uploads = 0

    init(_ inner: InMemoryLibraryTransport) { self.inner = inner }

    var readyUploads: Int { lock.withLock { uploads } }

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
        if offer.state == .ready { lock.withLock { uploads += 1 } }
        try await inner.publishMedia(offer: offer, fileURL: fileURL)
    }
}

@MainActor
final class WiltedMacMediaDurabilityTests: XCTestCase {
    private let macID = "mac-test"
    private let phoneID = "iphone-a"
    private let tabletID = "ipad-b"
    private let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))

    private struct Rig {
        let server: InMemoryLibraryServer
        let mac: InMemoryLibraryTransport
        let phone: InMemoryLibraryTransport
        let source: ScriptedAudioSource
        let clock: MutableClock
        let directory: URL
    }

    private func rig(_ name: String) -> Rig {
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        return Rig(
            server: server, mac: InMemoryLibraryTransport(deviceID: macID, server: server),
            phone: InMemoryLibraryTransport(deviceID: phoneID, server: server), source: ScriptedAudioSource(),
            clock: clock, directory: wiltedTemporaryDirectory(name)
        )
    }

    private func id(_ raw: String) throws -> ItemID { try ItemID(rawValue: raw) }

    private func makeAudio(_ directory: URL, revision: String) throws -> WiltedMacReadyAudio {
        let file = directory.appendingPathComponent("\(revision).m4a")
        try Data(repeating: UInt8(revision.utf8.last ?? 1), count: 4_096).write(to: file)
        return WiltedMacReadyAudio(
            revisionID: try RevisionID(rawValue: revision), contentHash: try MediaHash.sha256(fileAt: file),
            byteCount: 4_096, mediaType: "audio/mp4", durationSeconds: 60, fileURL: file,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(clock.now))
        )
    }

    private func request(_ rig: Rig, _ entry: ItemID, from device: String, intentID: String) throws -> LibraryIntent {
        try LibraryIntent.requestMedia(entryID: entry, deviceID: device, createdAt: rig.clock.now, id: intentID)
    }

    private func cached(_ rig: Rig, _ entry: ItemID, _ revision: String, from device: String, intentID: String) throws -> LibraryIntent {
        try LibraryIntent.mediaCached(
            entryID: entry, revisionID: try RevisionID(rawValue: revision), deviceID: device, createdAt: rig.clock.now, id: intentID
        )
    }

    private func makeService(
        _ rig: Rig, transport: any LibraryTransport, writer: ScriptedAccountingWriter,
        reportRequest: WiltedMacMediaService.RequestReporter? = nil
    ) -> WiltedMacMediaService {
        let clock = rig.clock
        return WiltedMacMediaService(
            source: rig.source, transport: transport,
            accountingURL: rig.directory.appendingPathComponent("media-accounting.json"),
            now: { clock.now }, reportRequest: reportRequest, accountingWrite: writer.write
        )
    }

    func testAnUncertainAccountingSaveAnswersSuccessAndDoesNotUploadAgain() async throws {
        let rig = rig("media-accounting-uncertain")
        let entry = try id("episode-accounting-uncertain")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        let transport = CountingMediaTransport(rig.mac)
        let writer = ScriptedAccountingWriter(uncertainSaves: [1, 2])
        let stages = RequestStageLog()
        let service = makeService(rig, transport: transport, writer: writer,
                                  reportRequest: { _, stage, _ in stages.append(stage) })
        let mediaRequest = try request(rig, entry, from: phoneID, intentID: "a-1")

        await service.handle(mediaRequest)

        let failure = await service.lastFailure
        XCTAssertNil(failure, "a landed accounting save must not be reported as a failure")
        XCTAssertEqual(transport.readyUploads, 1)
        let holding = await service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holding)
        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.state, .ready)
        XCTAssertEqual(stages.stages, [.sending, .answered], "an uncertain folder sync is not reported as a failed request")

        await service.handle(mediaRequest)
        XCTAssertEqual(transport.readyUploads, 1, "a false save failure must not trigger another upload")
        XCTAssertEqual(writer.calls, 2, "the redundant request updated the requester, not the audio")
    }

    func testTwoRequestersSurviveRestartAndWithdrawalWaitsForBothAcks() async throws {
        let rig = rig("media-accounting-requesters")
        let entry = try id("episode-two-requesters")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        let transport = CountingMediaTransport(rig.mac)
        let writer = ScriptedAccountingWriter(uncertainSaves: Set(1...8))
        let first = makeService(rig, transport: transport, writer: writer)

        await first.handle(try request(rig, entry, from: phoneID, intentID: "two-a"))
        await first.handle(try request(rig, entry, from: tabletID, intentID: "two-b"))
        XCTAssertEqual(transport.readyUploads, 1)
        let firstFailure = await first.lastFailure
        XCTAssertNil(firstFailure)

        let restarted = makeService(rig, transport: transport, writer: writer)
        let accounted = await restarted.accountedAssetCount
        XCTAssertEqual(accounted, 1, "the accounting with both requesters survives the restart")

        await restarted.handle(try cached(rig, entry, "rev-1", from: phoneID, intentID: "two-ack-a"))
        let holdingAfterOne = await restarted.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holdingAfterOne, "one acknowledgment is not enough")
        XCTAssertEqual(transport.readyUploads, 1)

        await restarted.handle(try cached(rig, entry, "rev-1", from: tabletID, intentID: "two-ack-b"))
        let holdingAfterBoth = await restarted.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertFalse(holdingAfterBoth)
        let remaining = await restarted.accountedAssetCount
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(transport.readyUploads, 1, "withdrawal never uploads the audio again")
    }

    func testAnAccountingSaveThatFailsBeforeTheRenameIsStillReported() async throws {
        let rig = rig("media-accounting-before-rename")
        let entry = try id("episode-accounting-before-rename")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let transport = CountingMediaTransport(rig.mac)
        let writer = ScriptedAccountingWriter(failingBeforeRename: 1)
        let service = makeService(rig, transport: transport, writer: writer)

        await service.handle(try request(rig, entry, from: phoneID, intentID: "b-1"))

        let failure = await service.lastFailure
        XCTAssertNotNil(failure, "a pre-rename persistence failure stays observable")
        XCTAssertEqual(transport.readyUploads, 1)
        XCTAssertEqual(writer.calls, 1)
    }
}
