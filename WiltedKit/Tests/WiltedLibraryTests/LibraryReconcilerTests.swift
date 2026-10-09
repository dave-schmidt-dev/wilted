import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class LibraryReconcilerTests: XCTestCase {
    private func id(_ name: String) -> ItemID { try! ItemID(rawValue: "item-\(name)") }

    private func entry(_ name: String) -> LibraryEntry {
        try! LibraryEntry(
            id: id(name), kind: .podcastEpisode, sourceID: id("feed"), title: "Episode \(name)",
            summary: "", publishedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func slot(_ name: String, _ key: Double) -> QueueSlot { try! QueueSlot(entryID: id(name), sortKey: key) }

    private struct Replica {
        let transport: InMemoryLibraryTransport
        let store: InMemoryLibraryStore
        let reconciler: LibraryReconciler

        init(_ deviceID: String, server: InMemoryLibraryServer) {
            transport = InMemoryLibraryTransport(deviceID: deviceID, server: server)
            store = InMemoryLibraryStore()
            reconciler = LibraryReconciler(transport: transport, store: store)
        }

        func publish(_ changes: [LibraryChange]) async throws {
            for change in changes { await store.enqueue(change) }
            _ = try await reconciler.sendPending().get()
        }
    }

    private func syncOK(_ replica: Replica) async throws {
        _ = try await replica.reconciler.synchronize().get()
    }

    func testReapplyingABatchIsIdempotent() async throws {
        let changes = [
            VersionedLibraryChange(version: 1, change: .entry(entry("a"))),
            VersionedLibraryChange(version: 2, change: .slot(slot("a", 0))),
            VersionedLibraryChange(version: 3, change: .removal(entryID: id("a"), state: .retired)),
        ]
        let batch = LibraryChangeBatch(generationID: "g", changes: changes, token: LibraryChangeToken(rawValue: "3"))
        let once = LibraryReconciler.reconcile(LibraryStoreState(), with: batch)
        let twice = LibraryReconciler.reconcile(once, with: batch)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.content.entries[id("a")]?.removal, .retired)

        // The same through the coordinator path: a second sync with nothing new changes nothing.
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = Replica("mac", server: server)
        try await mac.publish([.entry(entry("a")), .slot(slot("a", 0))])
        let phone = Replica("phone", server: server)
        try await syncOK(phone)
        let first = await phone.store.state()
        try await syncOK(phone)
        let second = await phone.store.state()
        XCTAssertEqual(first.content, second.content)
        XCTAssertEqual(first.versions, second.versions)
        XCTAssertEqual(first.cursor, second.cursor)
        XCTAssertEqual(first.content.queue.map(\.entryID), [id("a")])
    }

    func testTokenDoesNotAdvanceOnFailedCommit() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        try await Replica("mac", server: server).publish([.entry(entry("a"))])
        let phone = Replica("phone", server: server)

        await phone.store.failNextCommit(with: LibraryTransportError.transport("disk full"))
        let failed = await phone.reconciler.synchronize()
        guard case .failure = failed else { return XCTFail("commit failure must surface") }
        let afterFailure = await phone.store.state()
        XCTAssertNil(afterFailure.cursor)
        XCTAssertTrue(afterFailure.content.entries.isEmpty)
        let committedAfterFailure = await phone.transport.committedFetchToken
        XCTAssertNil(committedAfterFailure)

        // Nothing was lost: the same changes are delivered again and now commit.
        try await syncOK(phone)
        let afterRetry = await phone.store.state()
        XCTAssertEqual(afterRetry.content.entries.count, 1)
        XCTAssertEqual(afterRetry.cursor, LibraryChangeToken(rawValue: "1"))
        let committedAfterRetry = await phone.transport.committedFetchToken
        XCTAssertEqual(committedAfterRetry, afterRetry.cursor)
    }

    func testStaleGenerationIsRejectedWithoutCommitting() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        try await Replica("mac", server: server).publish([.entry(entry("a"))])
        let phone = Replica("phone", server: server)
        let transport = phone.transport
        await transport.setAfterFetchHook { await transport.invalidateOperations() }

        let result = await phone.reconciler.synchronize()
        guard case let .failure(error) = result else { return XCTFail("stale generation must be rejected") }
        XCTAssertEqual(error as? LibraryTransportError, .superseded)
        let state = await phone.store.state()
        XCTAssertNil(state.cursor)
        XCTAssertTrue(state.content.entries.isEmpty)
        let committed = await phone.transport.committedFetchToken
        XCTAssertNil(committed)

        await transport.setAfterFetchHook(nil)
        try await syncOK(phone)
        let recovered = await phone.store.state()
        XCTAssertEqual(recovered.content.entries.count, 1)
    }

    func testStaleGenerationOnSendKeepsChangePending() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = Replica("mac", server: server)
        let transport = mac.transport
        await transport.setAfterPushHook { await transport.invalidateOperations() }
        await mac.store.enqueue(.entry(entry("a")))
        let result = await mac.reconciler.sendPending()
        guard case let .failure(error) = result else { return XCTFail("stale send must be rejected") }
        XCTAssertEqual(error as? LibraryTransportError, .superseded)
        let state = await mac.store.state()
        XCTAssertEqual(state.pending.count, 1)
        let committedSent = await transport.committedSentToken
        XCTAssertNil(committedSent)
    }

    func testFetchedChangeConflictingWithPendingWorkIsHeldNotDropped() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = Replica("mac", server: server)
        let staleMac = Replica("mac", server: server) // a second writer process on the same account
        await mac.store.enqueue(.slot(slot("a", 5)))
        try await staleMac.publish([.slot(slot("a", 9))])

        try await syncOK(mac)
        let held = await mac.store.state()
        let key = LibraryRecordKey(kind: .slot, id: id("a"))
        XCTAssertEqual(held.pending.map(\.change), [.slot(slot("a", 5))], "local work survives")
        XCTAssertEqual(held.conflicts[key]?.server.change, .slot(slot("a", 9)))
        XCTAssertEqual(held.content.slots[id("a")], slot("a", 5), "content is not overwritten")

        let send = await mac.reconciler.sendPending()
        guard case let .failure(error) = send else { return XCTFail("a fully blocked send must not report success") }
        XCTAssertEqual(error as? LibraryTransportError, .sendBlockedByConflicts(count: 1))

        // Keeping local rebases it onto the server version; the next send wins.
        try await mac.reconciler.resolveConflict(key, keepLocal: true)
        _ = try await mac.reconciler.sendPending().get()
        let serverSlots = await server.currentSnapshot.slots
        XCTAssertEqual(serverSlots[id("a")], slot("a", 5))
        let settled = await mac.store.state()
        XCTAssertTrue(settled.pending.isEmpty && settled.conflicts.isEmpty)
    }

    func testPushConflictIsHeldAndOtherChangesStillSend() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = Replica("mac", server: server)
        try await Replica("mac", server: server).publish([.slot(slot("a", 9))])
        await mac.store.enqueue(.slot(slot("a", 5)))
        await mac.store.enqueue(.slot(slot("b", 1)))

        let result = try await mac.reconciler.sendPending().get()
        XCTAssertEqual(result.acknowledged.map(\.key), [LibraryRecordKey(kind: .slot, id: id("b"))])
        XCTAssertEqual(result.failures.first?.disposition, .conflict)
        let state = await mac.store.state()
        XCTAssertEqual(state.pending.map(\.key), [LibraryRecordKey(kind: .slot, id: id("a"))])
        XCTAssertEqual(state.conflicts.count, 1)
        let serverSlots = await server.currentSnapshot.slots
        XCTAssertEqual(serverSlots[id("a")], slot("a", 9))

        // Discarding local takes the server's record.
        try await mac.reconciler.resolveConflict(LibraryRecordKey(kind: .slot, id: id("a")), keepLocal: false)
        let resolved = await mac.store.state()
        XCTAssertTrue(resolved.pending.isEmpty)
        XCTAssertEqual(resolved.content.slots[id("a")], slot("a", 9))
    }

    func testLateAcknowledgementDoesNotRetireANewerLocalWrite() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = Replica("mac", server: server)
        let store = mac.store
        let transport = mac.transport
        let newer = slot("a", 7)
        await transport.setAfterPushHook { await store.enqueue(.slot(newer)) }
        await mac.store.enqueue(.slot(slot("a", 1)))

        _ = try await mac.reconciler.sendPending().get()
        await transport.setAfterPushHook(nil)
        let state = await mac.store.state()
        XCTAssertEqual(state.pending.map(\.change), [.slot(slot("a", 7))])
        XCTAssertEqual(state.pending.first?.baseVersion, 1, "rebased onto the acknowledged version")
        _ = try await mac.reconciler.sendPending().get()
        let serverSlots = await server.currentSnapshot.slots
        XCTAssertEqual(serverSlots[id("a")], slot("a", 7))
    }

    func testOnlyTheWriterMayPushLibraryState() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let phone = Replica("phone", server: server)
        await phone.store.enqueue(.entry(entry("a")))
        let result = await phone.reconciler.sendPending()
        guard case let .failure(error) = result else { return XCTFail("phone push must be rejected") }
        guard case .ownershipViolation = error as? LibraryTransportError else { return XCTFail("\(error)") }
        let leaked = await server.currentSnapshot.entries
        XCTAssertTrue(leaked.isEmpty)
    }

    func testTwoDeviceHandoffSequence() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        await server.setClock(Date(timeIntervalSince1970: 1_000))
        let mac = Replica("mac", server: server)
        let phone = Replica("phone", server: server)

        // 1. The Mac publishes its Larder through the differ; the phone mirrors it.
        let library = LibrarySnapshot(entries: [entry("a"), entry("b")], slots: [slot("a", 0), slot("b", 1)])
        try await mac.publish(LibraryStateDiffer.diff(from: nil, to: library))
        try await syncOK(phone)
        let mirrored = await phone.store.state()
        XCTAssertEqual(mirrored.content, library)

        // 2. The Mac plays "a" at epoch 1, position 100 s.
        let revision = try RevisionID(rawValue: "rev-1")
        let macPlaying = try DevicePlaybackPosition(
            deviceID: "mac", entryID: id("a"), revision: revision, positionSeconds: 100, isPlaying: true, epoch: 1
        )
        try await mac.transport.publish(macPlaying, as: .nowPlaying)

        // 3. The phone sees it, takes over with epoch max + 1, and resumes where the Mac was.
        await server.setClock(Date(timeIntervalSince1970: 1_010))
        let seen = try await phone.transport.fetchDeviceRecords()
        let winner = try XCTUnwrap(HandoffResolver.winner(among: seen.nowPlaying))
        XCTAssertEqual(winner.record.deviceID, "mac")
        let resume = HandoffResolver.resumePosition(of: winner, now: Date(timeIntervalSince1970: 1_010))
        XCTAssertEqual(resume, 110, accuracy: 0.001)
        let epoch = HandoffResolver.takeoverEpoch(seen: seen.nowPlaying.map(\.record))
        let phonePlaying = try DevicePlaybackPosition(
            deviceID: "phone", entryID: id("a"), revision: revision, positionSeconds: resume, isPlaying: true, epoch: epoch
        )
        try await phone.transport.publish(phonePlaying, as: .nowPlaying)
        try await phone.transport.send(intent: .requestMedia(entryID: id("a"), deviceID: "phone", id: "intent-1"))
        try await phone.transport.send(intent: .requestMedia(entryID: id("a"), deviceID: "phone", id: "intent-1"))

        // 4. The Mac observes the higher epoch and relinquishes; the phone keeps playing.
        let afterTakeover = try await mac.transport.fetchDeviceRecords()
        XCTAssertEqual(
            HandoffResolver.decision(localDeviceID: "mac", localEpoch: 1, observed: afterTakeover.nowPlaying),
            .relinquish(to: "phone")
        )
        XCTAssertEqual(
            HandoffResolver.decision(localDeviceID: "phone", localEpoch: epoch, observed: afterTakeover.nowPlaying),
            .keepPlaying
        )
        let intents = try await mac.transport.listIntents()
        XCTAssertEqual(intents.map(\.id), ["intent-1"], "the retried intent is applied once")

        // 5. Devices never write each other's records or library state.
        do {
            try await phone.transport.publish(macPlaying, as: .nowPlaying)
            XCTFail("a device must not write another device's record")
        } catch {
            XCTAssertTrue(error is LibraryTransportError)
        }
        try await mac.publish([.slot(slot("b", 0.5))])
        try await syncOK(phone)
        let converged = await phone.store.state()
        XCTAssertEqual(converged.content.queue.map(\.entryID), [id("a"), id("b")])
        XCTAssertEqual(converged.content.slots[id("b")], slot("b", 0.5))
    }
    func testVerifiedBatchGenerationMustMatchCapturedOperation() async throws {
        let transport = ReconcilerContextTransport(owner: "owner", proofOwner: "owner", proofGeneration: 9)
        let store = InMemoryLibraryStore()
        let result = await LibraryReconciler(transport: transport, store: store).synchronize()
        guard case .failure = result else { return XCTFail("mismatched proof generation committed") }
        let state = await store.state()
        XCTAssertNil(state.cursor)
    }

    func testVerifiedBatchOwnerMustMatchCurrentObservedOwner() async throws {
        let transport = ReconcilerContextTransport(owner: "current", proofOwner: "different")
        let store = InMemoryLibraryStore()
        let result = await LibraryReconciler(transport: transport, store: store).synchronize()
        guard case .failure = result else { return XCTFail("mismatched proof owner committed") }
        let state = await store.state()
        XCTAssertNil(state.cursor)
    }

    func testStoredBatchOwnerWithoutCurrentVerificationCannotCommit() async throws {
        let transport = ReconcilerContextTransport(owner: nil, proofOwner: "stored")
        let store = InMemoryLibraryStore()
        let result = await LibraryReconciler(transport: transport, store: store).synchronize()
        guard case .failure = result else { return XCTFail("unverified current identity committed") }
        let state = await store.state()
        XCTAssertNil(state.cursor)
    }

    func testTokenAcknowledgementFailureKeepsTheAlreadyCommittedBatch() async throws {
        let transport = ReconcilerContextTransport(owner: "owner", proofOwner: "owner", failAcknowledgement: true)
        let store = InMemoryLibraryStore()
        let result = await LibraryReconciler(transport: transport, store: store).synchronize()
        guard case .failure = result else { return XCTFail("acknowledgement error must surface") }
        let state = await store.state()
        XCTAssertEqual(state.cursor?.rawValue, "new-cursor")
        XCTAssertEqual(state.revision, 1)
    }

}


private actor ReconcilerContextTransport: LibraryTransport {
    let owner: String?
    let proofOwner: String
    let proofGeneration: UInt64
    let failAcknowledgement: Bool
    init(owner: String?, proofOwner: String, proofGeneration: UInt64 = 0, failAcknowledgement: Bool = false) {
        self.owner = owner; self.proofOwner = proofOwner; self.proofGeneration = proofGeneration
        self.failAcknowledgement = failAcknowledgement
    }
    func verifiedOwnerToken() -> String? { owner }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        .init(generationID: "proof", changes: [], token: .init(rawValue: "new-cursor"),
              provenance: .init(ownerToken: proofOwner, operationGeneration: proofGeneration, isFullBootstrap: true))
    }
    func commitFetchedState(_ token: LibraryChangeToken?) throws {
        if failAcknowledgement { throw LibraryTransportError.transport("acknowledgement failed") }
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { .init() }
    func send(intent: LibraryIntent) async throws {}
    func listIntents() async throws -> [LibraryIntent] { [] }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { .init() }
}
