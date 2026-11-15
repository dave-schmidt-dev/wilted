import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// Mac order advance: in `.mac` list order, a natural completion takes candidate rows
/// from the live queue order from the top, minus the ended row and minus audiobook rows.
/// In `.playOrder`, and after an audiobook row, it follows the captured forward suffix.
@MainActor
final class LibraryMacOrderAdvanceTests: XCTestCase {
    private var scratch: URL!
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
    private let revision = try! RevisionID(rawValue: "rev-1")
    private let payload = Data((0..<2_000).map { UInt8($0 % 251) })
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var localSeq: UInt64 = 0

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-mac-advance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private struct MacAdvanceRig {
        let model: LibraryAppModel
        let player: LibraryPlayer
        let engine: AutoEngine
    }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func macPush(_ changes: [LibraryChange]) async throws {
        let pending = changes.map { change -> PendingLibraryChange in
            localSeq += 1
            return PendingLibraryChange(localSeq: localSeq, change: change, baseVersion: versions[change.key] ?? 0)
        }
        let result = try await mac.push(changes: pending)
        XCTAssertTrue(result.failures.isEmpty)
        for ack in result.acknowledged { versions[ack.key] = ack.version }
    }

    private func makeRig(
        entries: [(id: String, kind: LibraryKind)],
        onPhone: Set<String>? = nil,
        listOrder: LibraryListOrder = .mac,
        autoPlayNext: Bool = true
    ) async throws -> MacAdvanceRig {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache-" + UUID().uuidString))
        var changes: [LibraryChange] = [
            .source(LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show"))
        ]
        for (offset, entry) in entries.enumerated() {
            changes.append(.entry(try LibraryEntry(
                id: id(entry.id), kind: entry.kind, sourceID: id("show"), title: "Title \(entry.id)", summary: "",
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(offset) * 86_400),
                durationSeconds: 600, removal: .none, removedAt: nil)))
            changes.append(.slot(try QueueSlot(entryID: id(entry.id), sortKey: Double(offset))))
        }
        try await macPush(changes)

        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        let mirror = FileLibraryStore(url: scratch.appendingPathComponent("mirror-" + UUID().uuidString + ".json"))
        try await PreparedMediaFixture.bootstrap(mirror, transport: phone)

        let downloaded = onPhone ?? Set(entries.map(\.id))
        for entry in entries {
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try payload.write(to: file)
            let digest = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let certifiedOffer = try PreparedMediaFixture.certified(LibraryMediaOffer(
                entryID: id(entry.id), revisionID: revision, contentHash: digest,
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600))
            try await mac.publishMedia(offer: certifiedOffer, fileURL: file)
            if downloaded.contains(entry.id) {
                _ = try await PreparedMediaFixture.adopt(
                    into: cache, verifiedFile: file, for: certifiedOffer, owner: "fixture-owner")
            }
        }

        let engine = AutoEngine()
        let player = LibraryPlayer(
            engine: engine, session: AutoSession(), nowPlaying: AutoNowPlaying(),
            remoteCommands: AutoRemote(), sessionEvents: AutoEvents(), tickInterval: .seconds(3600))
        player.apply(LibraryPlaybackPreferences(
            defaultSpeed: 1.0, skipBackSeconds: 15, skipForwardSeconds: 30, autoPlayNext: autoPlayNext))

        let model = LibraryAppModel(
            transport: phone, store: mirror, deviceID: "phone", mediaCache: cache,
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval,
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                settleSleep: { _ in }),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            timeZone: TimeZone(identifier: "UTC")!)
        model.listOrder = listOrder
        model.attachPlayer(player)
        await model.refresh()
        for raw in downloaded { model.media[id(raw)] = .onPhone }
        return MacAdvanceRig(model: model, player: player, engine: engine)
    }

    private func makeRig(
        entries: [String] = ["a", "b", "c", "d"],
        onPhone: Set<String>? = nil,
        listOrder: LibraryListOrder = .mac,
        autoPlayNext: Bool = true
    ) async throws -> MacAdvanceRig {
        try await makeRig(
            entries: entries.map { ($0, .podcastEpisode) },
            onPhone: onPhone,
            listOrder: listOrder,
            autoPlayNext: autoPlayNext)
    }

    private func complete(_ raw: String, at seconds: TimeInterval = 1_690_000_000) async throws {
        try await macPush([.listening(ListeningRecord(
            itemID: id(raw), completedAt: Date(timeIntervalSince1970: seconds),
            updatedAt: Date(timeIntervalSince1970: seconds), deviceID: "mac"))])
    }

    private func inProgressOnMac(_ raw: String, position: Double = 100, at seconds: TimeInterval = 1_650_000_000) async throws {
        await server.setClock(Date(timeIntervalSince1970: seconds))
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: id(raw), revision: revision, positionSeconds: position, rate: 1, isPlaying: false, epoch: 1,
            publishedAt: Date(timeIntervalSince1970: seconds))
        try await mac.publish(record, as: .progress)
    }

    private func macPublishesNowPlaying(
        _ raw: String, position: Double = 100, at seconds: TimeInterval = 1_700_000_000
    ) async throws {
        await server.setClock(Date(timeIntervalSince1970: seconds))
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: id(raw), revision: revision, positionSeconds: position, rate: 1,
            isPlaying: true, epoch: 1, publishedAt: Date(timeIntervalSince1970: seconds))
        try await mac.publish(record, as: .nowPlaying)
        try await mac.publish(record, as: .progress)
    }

    private func start(_ rig: MacAdvanceRig, _ raw: String) async {
        let row = try! XCTUnwrap(rig.model.queued.first { $0.id == id(raw) })
        await rig.model.playCached(row)
    }

    private func settle() async { await settleOnClock() }

    // MARK: - Tests

    func testNaturalEndInMacOrderStartsFirstNotCompletedOnPhoneRowFromTop() async throws {
        let rig = try await makeRig(entries: ["a", "b", "c", "d"], listOrder: .mac)
        await start(rig, "c")
        XCTAssertEqual(rig.player.item?.entryID, id("c"))

        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("a"), "In Mac order, natural end starts the first not-completed row from the top")
    }

    func testQueueRebuiltInNewSlotOrderDuringPlaybackDecidesNextRow() async throws {
        let rig = try await makeRig(entries: ["a", "b", "c", "d"], listOrder: .mac)
        await start(rig, "c")
        XCTAssertEqual(rig.player.item?.entryID, id("c"))

        // Rebuild the queue in a new slot order during playback
        var changes: [LibraryChange] = []
        changes.append(.slot(try QueueSlot(entryID: id("d"), sortKey: 0)))
        changes.append(.slot(try QueueSlot(entryID: id("b"), sortKey: 1)))
        changes.append(.slot(try QueueSlot(entryID: id("a"), sortKey: 2)))
        changes.append(.slot(try QueueSlot(entryID: id("c"), sortKey: 3)))
        try await macPush(changes)
        await rig.model.refresh()

        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("d"), "The new slot order at natural end decides the next row")
    }

    func testCompletedRowAtTopIsNeverStarted() async throws {
        let rig = try await makeRig(entries: ["a", "b", "c", "d"], listOrder: .mac)
        try await complete("a")
        await rig.model.refresh()

        await start(rig, "c")
        XCTAssertEqual(rig.player.item?.entryID, id("c"))

        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("b"), "A completed row at the top is never started")
    }

    func testRowNotOnPhoneAtTopIsNeverStarted() async throws {
        let rig = try await makeRig(entries: ["a", "b", "c", "d"], onPhone: ["b", "c", "d"], listOrder: .mac)
        await start(rig, "c")
        XCTAssertEqual(rig.player.item?.entryID, id("c"))

        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("b"), "A row not on the phone at the top is never started")
    }

    func testAudiobookRowAtTopIsNeverStarted() async throws {
        let rig = try await makeRig(
            entries: [
                (id: "a", kind: .audiobook),
                (id: "b", kind: .podcastEpisode),
                (id: "c", kind: .podcastEpisode),
                (id: "d", kind: .podcastEpisode)
            ],
            listOrder: .mac
        )
        await start(rig, "c")
        XCTAssertEqual(rig.player.item?.entryID, id("c"))

        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("b"), "An audiobook row at the top is never started on non-audiobook natural end")
    }

    func testEndOfAudiobookRowStartsNextRowOfCapturedForwardSuffix() async throws {
        let rig = try await makeRig(
            entries: [
                (id: "a", kind: .podcastEpisode),
                (id: "b", kind: .audiobook),
                (id: "c", kind: .podcastEpisode),
                (id: "d", kind: .podcastEpisode)
            ],
            listOrder: .mac
        )
        await start(rig, "b")
        XCTAssertEqual(rig.player.item?.entryID, id("b"))

        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("c"), "End of an audiobook row starts the next row of the captured forward suffix")
    }

    func testNoRowStartsWhenNoCandidateRemains() async throws {
        let rig = try await makeRig(entries: ["a"], listOrder: .mac)
        await start(rig, "a")
        XCTAssertEqual(rig.player.item?.entryID, id("a"))

        rig.engine.finishNaturally()
        await settle()
        XCTAssertFalse(rig.player.isPlaying, "Player does not continue when no candidate remains")
        XCTAssertEqual(rig.player.status, .ended)
    }

    func testManualForwardSuffixEqualsQueueOrderInMacOrder() async throws {
        let rig = try await makeRig(entries: ["a", "b", "c", "d"], listOrder: .mac)
        // Partway through "d": Play order would list it first, so its suffix from "b" would differ.
        try await inProgressOnMac("d")
        await rig.model.refresh()
        let suffix = rig.model.manualForwardSuffix(from: id("b"))
        XCTAssertEqual(suffix, [id("b"), id("c"), id("d")])
        rig.model.listOrder = .playOrder
        XCTAssertEqual(rig.model.manualForwardSuffix(from: id("b")), [id("b"), id("c")])
    }

    func testRemoteResumeRowEqualsQueueOrderInMacOrder() async throws {
        let rig = try await makeRig(entries: ["a", "b", "c", "d"], listOrder: .mac)
        try await inProgressOnMac("c")
        await rig.model.refresh()
        let resumeRow = try XCTUnwrap(rig.model.remoteResumeRow)
        XCTAssertEqual(resumeRow.id, id("a"), "Remote resume picks first not-completed in Mac queue order, not the in-progress row")
    }

    func testContinueFromMacCapturesSuffixInQueueOrderInMacOrder() async throws {
        let rig = try await makeRig(entries: ["a", "b", "c", "d"], listOrder: .mac)
        try await macPublishesNowPlaying("b")
        await rig.model.refresh()
        await rig.model.continueFromMac()
        XCTAssertEqual(rig.model.handoffState.forwardSequenceIDs, [id("b"), id("c"), id("d")])
    }

    func testNaturalEndInPlayOrderStartsRowAfterEndedInCapturedSuffixAndNeverRowAboveIt() async throws {
        let rig = try await makeRig(entries: ["a", "b", "c", "d"], listOrder: .playOrder)
        await start(rig, "c")
        XCTAssertEqual(rig.player.item?.entryID, id("c"))
        XCTAssertEqual(rig.model.handoffState.forwardSequenceIDs, [id("c"), id("d")])

        rig.engine.finishNaturally()
        await settle()
        XCTAssertEqual(rig.player.item?.entryID, id("d"), "In play order, natural end advances to next in captured suffix")
        XCTAssertNotEqual(rig.player.item?.entryID, id("a"), "Never starts a row above the ended row in play order")
    }
}
