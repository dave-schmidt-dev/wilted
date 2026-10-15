import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// The Mac side of adopting the phone's positions: candidate choice, the importer's settling
/// rules, and the whole phone -> Mac -> phone loop over an in-memory server and a real store.
@MainActor
private final class ScriptedImportHost: WiltedMacPositionImportHost {
    var targets: [ItemID: WiltedMacImportTarget]? = [:]
    var outcome: RemotePositionOutcome? = .applied
    private(set) var requests: [RemotePositionRequest] = []
    private(set) var targetReads = 0
    var associationEntries: [LibraryEntry] = []
    var associationOffers: [ItemID: LibraryMediaOffer] = [:]
    private(set) var associationChecks: [ItemID] = []

    func importAssociationContext() async -> (entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer]) {
        (associationEntries, associationOffers)
    }

    func associationImportIsCurrent(entryID: ItemID, entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer]) async -> Bool {
        associationChecks.append(entryID)
        return true
    }

    func importTargets() async -> [ItemID: WiltedMacImportTarget]? {
        targetReads += 1
        return targets
    }

    func applyRemotePosition(_ request: RemotePositionRequest) async -> RemotePositionOutcome? {
        requests.append(request)
        return outcome
    }
}

/// The real playback controller behind the same seam the model uses.
@MainActor
private final class ControllerImportHost: WiltedMacPositionImportHost {
    let controller: PlaybackController
    let targets: [ItemID: WiltedMacImportTarget]

    init(controller: PlaybackController, targets: [ItemID: WiltedMacImportTarget]) {
        self.controller = controller
        self.targets = targets
    }

    func importTargets() async -> [ItemID: WiltedMacImportTarget]? { targets }

    func applyRemotePosition(_ request: RemotePositionRequest) async -> RemotePositionOutcome? {
        try? await controller.applyRemotePosition(request)
    }
}

@MainActor
final class WiltedMacPositionImporterTests: XCTestCase {
    private let macID = "mac-test"
    private let phoneID = "iphone-a"
    private let episode = try! ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
    private let revisionA = try! RevisionID(rawValue: "rev-a")
    private let revisionB = try! RevisionID(rawValue: "rev-b")
    private let base = Date().addingTimeInterval(-3_600)

    // MARK: planner

    private func candidate(revision: RevisionID, observedAt: Date? = nil) -> ImportablePosition {
        ImportablePosition(
            entryID: episode, revision: revision, positionSeconds: 300, observedAt: observedAt ?? base,
            sourceDeviceID: phoneID, epoch: 2)
    }

    func testARequestIsMadeOnlyForTheMacsReadyRevision() {
        let target = WiltedMacImportTarget(revision: revisionA, durationSeconds: 1_482)
        let matching = WiltedMacPositionImport.requests(candidates: [candidate(revision: revisionA)], targets: [episode: target])
        XCTAssertEqual(matching.first?.positionSeconds, 300)
        XCTAssertEqual(matching.first?.durationSeconds, 1_482)
        XCTAssertEqual(matching.first?.revisionID, revisionA)
        XCTAssertTrue(WiltedMacPositionImport.requests(
            candidates: [candidate(revision: revisionB)], targets: [episode: target]).isEmpty,
            "a position for another revision is never paired with this one")
        XCTAssertTrue(WiltedMacPositionImport.requests(candidates: [candidate(revision: revisionA)], targets: [:]).isEmpty,
            "no ready audio, retired or finished: no request")
    }

    // MARK: importer

    private func records(position: Double, epoch: Int = 2, at server: Date, device: String? = nil) throws -> LibraryDeviceRecords {
        let record = try DevicePlaybackPosition(
            deviceID: device ?? phoneID, entryID: episode, revision: revisionA, positionSeconds: position,
            isPlaying: false, epoch: epoch, publishedAt: server)
        let observed = ObservedPlayback(record: record, serverModifiedAt: server)
        return LibraryDeviceRecords(nowPlaying: [observed], progress: [observed])
    }

    private func importer(_ host: ScriptedImportHost) -> WiltedMacPositionImporter {
        host.targets = [episode: WiltedMacImportTarget(revision: revisionA, durationSeconds: 1_482)]
        return WiltedMacPositionImporter(host: host, deviceID: macID)
    }

    func testAnAdoptedRecordIsSettledAndNotAppliedAgain() async throws {
        let host = ScriptedImportHost()
        let importer = importer(host)
        let first = try records(position: 300, at: base)
        await importer.handle(first)
        await importer.handle(first)
        XCTAssertEqual(host.requests.count, 1)
        XCTAssertEqual(host.targetReads, 1, "a settled record costs no store read")
        XCTAssertEqual(importer.appliedCount, 1)

        await importer.handle(try records(position: 420, at: base.addingTimeInterval(60)))
        XCTAssertEqual(host.requests.map(\.positionSeconds), [300, 420], "a newer record is a new import")
    }

    func testARecordSkippedBecauseTheMacIsPlayingIsTriedAgain() async throws {
        let host = ScriptedImportHost()
        let importer = importer(host)
        host.outcome = .playing
        let phone = try records(position: 300, at: base)
        await importer.handle(phone)
        host.outcome = .applied
        await importer.handle(phone)
        XCTAssertEqual(host.requests.count, 2)
        XCTAssertEqual(importer.appliedCount, 1)
    }

    func testAFailedWriteOrReadIsTriedAgain() async throws {
        let host = ScriptedImportHost()
        let importer = importer(host)
        host.outcome = nil
        let phone = try records(position: 300, at: base)
        await importer.handle(phone)
        host.targets = nil
        await importer.handle(phone)
        host.targets = [episode: WiltedMacImportTarget(revision: revisionA, durationSeconds: 1_482)]
        host.outcome = .applied
        await importer.handle(phone)
        XCTAssertEqual(host.requests.count, 2)
        XCTAssertEqual(importer.appliedCount, 1)
    }

    func testTheMacsOwnRecordsAreNeverImported() async throws {
        let host = ScriptedImportHost()
        let importer = importer(host)
        await importer.handle(try records(position: 300, at: base, device: macID))
        XCTAssertTrue(host.requests.isEmpty)
        XCTAssertEqual(host.targetReads, 0)
    }

    func testARecordBelowTheEntrysEpochIsIgnored() async throws {
        let host = ScriptedImportHost()
        let importer = importer(host)
        let mac = try records(position: 900, epoch: 5, at: base, device: macID)
        let phone = try records(position: 20, epoch: 4, at: base.addingTimeInterval(5))
        await importer.handle(LibraryDeviceRecords(
            nowPlaying: mac.nowPlaying + phone.nowPlaying, progress: mac.progress + phone.progress))
        XCTAssertTrue(host.requests.isEmpty)
    }

    // MARK: phone -> Mac -> phone

    private struct Rig {
        let store: LocalLibraryStore
        let controller: PlaybackController
        let backend: WiltedFixturePlaybackBackend
        let server: InMemoryLibraryServer
        let phone: HandoffCoordinator
        let mac: HandoffCoordinator
        let importer: WiltedMacPositionImporter
    }

    private var revision: AudioRevision {
        try! AudioRevision(
            itemID: episode, revisionID: revisionA, durationSeconds: 1_482, byteCount: 1,
            contentHash: "sha256:\(String(repeating: "a", count: 64))", mediaType: "audio/mp4",
            createdAt: Timestamp(base), schemaVersion: 1)
    }

    private func makeRig(macPosition: Double) async throws -> Rig {
        let directory = wiltedTemporaryDirectory("position-importer")
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        // The store keeps a checkpoint only for an item it still holds.
        try await store.saveReadyRevision(revision, mediaURL: URL(fileURLWithPath: "/tmp/podcast-a.m4a"))
        try await store.save(playback: PlaybackState(
            itemID: episode, revisionID: revisionA, sessionID: "session-mac", sequence: 3, positionSeconds: macPosition,
            durationSeconds: 1_482, completed: false, intent: .progress, deviceID: macID,
            updatedAt: Timestamp(base)))
        let backend = WiltedFixturePlaybackBackend()
        let controller = PlaybackController(store: store, backend: backend, deviceID: macID)
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        let phone = HandoffCoordinator(
            transport: InMemoryLibraryTransport(deviceID: phoneID, server: server), deviceID: phoneID,
            clock: { [base] in base.addingTimeInterval(600) }, sleep: { _ in })
        let mac = HandoffCoordinator(
            transport: InMemoryLibraryTransport(deviceID: macID, server: server), deviceID: macID,
            clock: { Date() }, sleep: { _ in })
        let host = ControllerImportHost(
            controller: controller,
            targets: [episode: WiltedMacImportTarget(revision: revisionA, durationSeconds: 1_482)])
        return Rig(
            store: store, controller: controller, backend: backend, server: server, phone: phone, mac: mac,
            importer: WiltedMacPositionImporter(host: host, deviceID: macID))
    }

    private func macFetch(_ rig: Rig) async throws -> LibraryDeviceRecords {
        try await InMemoryLibraryTransport(deviceID: macID, server: rig.server).fetchDeviceRecords()
    }

    /// The phone listens to `position` at `minutes` after `base` and pauses there.
    private func phoneListens(_ rig: Rig, to position: Double, minutes: Double) async throws {
        await rig.server.setClock(base.addingTimeInterval(minutes * 60))
        try await rig.phone.takeover(entryID: episode, revision: revisionA, positionSeconds: position - 30)
        try await rig.phone.paused(at: position)
    }

    func testPhoneOnlyListenThenMacResumesAtThePhonesPosition() async throws {
        let rig = try await makeRig(macPosition: 100)
        try await phoneListens(rig, to: 720, minutes: 10)

        await rig.importer.handle(try await macFetch(rig))

        XCTAssertEqual(rig.importer.appliedCount, 1)
        // The Mac has nothing loaded; playing the episode loads the stored state.
        try await rig.controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/podcast-a.m4a"))
        XCTAssertEqual(rig.controller.positionSeconds, 720)
        XCTAssertEqual(rig.backend.currentTime, 720)
        XCTAssertFalse(rig.backend.isPlaying)
    }

    func testAStaleRecordDoesNotMoveTheMacBackwards() async throws {
        let rig = try await makeRig(macPosition: 900)
        // The phone listened before the Mac's own checkpoint.
        try await phoneListens(rig, to: 200, minutes: -10)

        await rig.importer.handle(try await macFetch(rig))

        let state = try await rig.store.playbackState(for: episode, revisionID: revisionA)
        XCTAssertEqual(state?.positionSeconds, 900)
        XCTAssertEqual(rig.importer.appliedCount, 0)
    }

    func testAPlayingMacIsNotDisturbedAndTheRecordIsAdoptedOnceItPauses() async throws {
        let rig = try await makeRig(macPosition: 100)
        try await rig.controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/podcast-a.m4a"))
        rig.backend.currentTime = 130
        try rig.controller.play()
        try await phoneListens(rig, to: 720, minutes: 10)
        let records = try await macFetch(rig)

        await rig.importer.handle(records)
        XCTAssertEqual(rig.backend.currentTime, 130)
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertEqual(rig.importer.appliedCount, 0)

        // Pausing checkpoints at the Mac's own later time, so its own listening wins.
        try await rig.controller.pause()
        await rig.importer.handle(records)
        let state = try await rig.store.playbackState(for: episode, revisionID: revisionA)
        XCTAssertEqual(state?.positionSeconds, 130, "what the Mac played last is newer than the phone's record")
    }

    func testACompletedEpisodeIsNotResurrectedByAPhoneRecord() async throws {
        let rig = try await makeRig(macPosition: 100)
        try await rig.store.save(playback: PlaybackState(
            itemID: episode, revisionID: revisionA, sessionID: "session-mac", sequence: 4, positionSeconds: 1_482,
            durationSeconds: 1_482, completed: true, intent: .progress, deviceID: macID, updatedAt: Timestamp(base)))
        try await phoneListens(rig, to: 300, minutes: 10)

        await rig.importer.handle(try await macFetch(rig))

        let state = try await rig.store.playbackState(for: episode, revisionID: revisionA)
        XCTAssertEqual(state?.completed, true)
        XCTAssertEqual(state?.positionSeconds, 1_482)
    }

    func testRoundTripPhoneToMacToPhone() async throws {
        let rig = try await makeRig(macPosition: 100)
        try await phoneListens(rig, to: 720, minutes: 10)
        await rig.importer.handle(try await macFetch(rig))
        try await rig.controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/podcast-a.m4a"))

        // The Mac listens on to 900 and pauses; its checkpoint is newer than the phone's record.
        await rig.server.setClock(Date())
        rig.backend.currentTime = 900
        try await rig.controller.pause()
        let loaded = try await rig.store.playbackState(for: episode, revisionID: revisionA)
        let snapshotState = try XCTUnwrap(loaded)
        XCTAssertEqual(snapshotState.positionSeconds, 900)
        let positions = WiltedMacStoredPositions.derive(
            queue: [episode], retired: [], readyRevisions: [episode: revisionA],
            playbackStates: ["\(episode.rawValue)|\(revisionA.rawValue)": snapshotState], completed: [])
        let written = try await rig.mac.publishStoredPositions(positions)
        XCTAssertEqual(written, [episode], "the Mac publishes its position, now beyond the phone's")

        // What the phone's Play uses: the newest same-revision record among the devices.
        let records = try await macFetch(rig)
        let candidates = (records.nowPlaying + records.progress).filter { $0.record.revision == revisionA }
        let winner = try XCTUnwrap(HandoffResolver.winner(among: candidates))
        XCTAssertEqual(winner.record.positionSeconds, 900)
        XCTAssertEqual(winner.record.deviceID, macID)
    }
}


extension WiltedMacPositionImporterTests {
    func testNewestAssociatedOriginSettlesItsOwnCandidateAcrossRepeatedPolls() async throws {
        let first = try ItemID(rawValue: "alias-A"), second = try ItemID(rawValue: "alias-B")
        let feed = try ItemID(rawValue: "alias-feed")
        let association = LibraryEpisodeAssociation(groupID: UUID(), representativeID: first,
            memberIDs: [first, second], associationVersion: 1, isTerminal: false)
        let host = ScriptedImportHost()
        host.associationEntries = try [first, second].map { id in
            try LibraryEntry(id: id, kind: .podcastEpisode, sourceID: feed, title: "Alias", summary: "",
                publishedAt: base, episodeAssociation: association)
        }
        host.targets = [first: WiltedMacImportTarget(revision: revisionA, durationSeconds: 600)]
        for (id, revision) in [(first, revisionA), (second, revisionB)] {
            host.associationOffers[id] = try LibraryMediaOffer(entryID: id, revisionID: revision,
                contentHash: "sha256:" + String(repeating: "a", count: 64), byteCount: 512,
                mediaType: "audio/mp4", durationSeconds: 600,
                preparation: LibraryMediaPreparation(preparedAt: Timestamp(base)))
        }
        func observed(_ id: ItemID, revision: RevisionID, position: Double, at: Date, device: String) throws -> ObservedPlayback {
            ObservedPlayback(record: try DevicePlaybackPosition(deviceID: device, entryID: id, revision: revision,
                positionSeconds: position, isPlaying: false, epoch: 4), serverModifiedAt: at)
        }
        // Entry-ID order puts old A first; epoch/date order must choose newer B.
        let old = try observed(first, revision: revisionA, position: 40, at: base, device: "old-phone")
        let recent = try observed(second, revision: revisionB, position: 123,
            at: base.addingTimeInterval(60), device: "new-phone")
        let records = LibraryDeviceRecords(nowPlaying: [old, recent], progress: [old, recent])
        let candidates = HandoffPositionImport.candidates(records: records, localDeviceID: macID)
        let resolved = WiltedMacPositionImport.resolvedRequests(candidates: candidates, targets: host.targets!,
            entries: host.associationEntries, offers: host.associationOffers)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.source.entryID, second)
        XCTAssertEqual(resolved.first?.source.sourceDeviceID, "new-phone")
        let importer = WiltedMacPositionImporter(host: host, deviceID: macID)
        await importer.handle(records)
        XCTAssertEqual(host.requests.map(\.positionSeconds), [123])
        XCTAssertEqual(host.associationChecks, [first], "The selected B-to-A translation still requires the current-proof fence")
        XCTAssertEqual(importer.adopted[first]?.stampedAt, recent.serverModifiedAt)
        // A's older record remains independently eligible; the writer correctly
        // rejects it as not newer, and the importer then settles that origin too.
        host.outcome = .notNewer
        await importer.handle(records)
        await importer.handle(records)
        XCTAssertEqual(host.requests.map(\.positionSeconds), [123, 40], "Settled newer B must not be imported repeatedly")
        XCTAssertEqual(host.targetReads, 2, "Once both actual origins settle, repeat polling needs no store read")
        XCTAssertEqual(importer.appliedCount, 1)
        XCTAssertEqual(importer.adopted[first]?.positionSeconds, 123)
    }

    func testAssociatedPositionPrefersExactRawBThenCompatibleAAndRefusesConflictingProof() throws {
        let first = try ItemID(rawValue: "alias-A"), second = try ItemID(rawValue: "alias-B")
        let feed = try ItemID(rawValue: "alias-feed")
        let association = LibraryEpisodeAssociation(groupID: UUID(), representativeID: first,
            memberIDs: [first, second], associationVersion: 1, isTerminal: false)
        let entries = try [first, second].map { id in
            try LibraryEntry(id: id, kind: .podcastEpisode, sourceID: feed, title: "Alias", summary: "",
                publishedAt: base, episodeAssociation: association)
        }
        let hash = "sha256:" + String(repeating: "a", count: 64)
        func offer(_ id: ItemID, _ revision: RevisionID, hash value: String? = nil,
                   count: Int64 = 512, duration: Double = 120, mediaType: String = "audio/mp4") throws -> LibraryMediaOffer {
            try LibraryMediaOffer(entryID: id, revisionID: revision, contentHash: value ?? hash,
                byteCount: count, mediaType: mediaType, durationSeconds: duration,
                preparation: LibraryMediaPreparation(preparedAt: Timestamp(base)))
        }
        let source = ImportablePosition(entryID: second, revision: revisionB, positionSeconds: 73,
            observedAt: base, sourceDeviceID: phoneID, epoch: 4)
        let targets = [first: WiltedMacImportTarget(revision: revisionA, durationSeconds: 120),
                       second: WiltedMacImportTarget(revision: revisionB, durationSeconds: 120)]
        let offers = try [first: offer(first, revisionA), second: offer(second, revisionB)]
        let exact = WiltedMacPositionImport.requests(candidates: [source], targets: targets, entries: entries, offers: offers)
        XCTAssertEqual(exact.first?.itemID, second)
        XCTAssertEqual(exact.first?.revisionID, revisionB)
        XCTAssertEqual(exact.first?.positionSeconds, 73)
        let onlyA = [first: targets[first]!]
        let translated = WiltedMacPositionImport.requests(candidates: [source], targets: onlyA, entries: entries, offers: offers)
        XCTAssertEqual(translated.first?.itemID, first)
        XCTAssertEqual(translated.first?.revisionID, revisionA)
        XCTAssertEqual(translated.first?.positionSeconds, 73)
        let negatives = try [offer(first, revisionA, hash: "sha256:" + String(repeating: "b", count: 64)),
            offer(first, revisionA, count: 513), offer(first, revisionA, duration: 119),
            offer(first, revisionA, mediaType: "audio/mpeg"), offer(first, revisionB)]
        for negative in negatives {
            var changed = offers; changed[first] = negative
            XCTAssertTrue(WiltedMacPositionImport.requests(candidates: [source], targets: onlyA,
                entries: entries, offers: changed).isEmpty, "Incompatible media cannot translate the source position")
        }
        XCTAssertTrue(WiltedMacPositionImport.requests(candidates: [source], targets: onlyA,
            entries: entries, offers: [first: offers[first]!]).isEmpty, "Missing source proof cannot resume at zero")
    }
}
