import CloudKit
import Foundation
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

final class LibraryPublicationRecordTests: XCTestCase {
    func testResetDuringZoneWaitPreventsBatchPlaybackFromQueuingOldCallerRecords() async throws {
        let barrier = OwnerProbeBarrier()
        let driver = ScriptedDriver(send: { throw CKError(.networkFailure) }, zone: { await barrier.hold() })
        let transport = try cloudEndpoint(driver)
        let position = try makePosition(device: "mac")
        let task = Task { try await transport.publish([(record: position, channel: .progress)]) }
        await barrier.waitUntilHeld()
        await transport.resetAfterAccountChange()
        await barrier.release()
        do { try await task.value; XCTFail("reset admitted old batch") }
        catch { XCTAssertEqual(error as? LibraryTransportError, .superseded) }
        let pending = await driver.pending
        XCTAssertTrue(pending.isEmpty, "completed reset must stop queuing old caller records")
    }

    func testQuarantineDuringZoneWaitPreventsEvenQueuingReceiptForSend() async throws {
        let barrier = OwnerProbeBarrier()
        let completion = FactoryLog()
        let driver = ScriptedDriver(zone: { await barrier.hold() })
        let transport = try cloudEndpoint(driver)
        let value = try LibraryPublication(id: "p", publishedAt: Date(), writerDeviceID: "mac")
        let task = Task {
            defer { _ = completion.record(nil) }
            try await transport.publishPublication(value)
        }
        await barrier.waitUntilHeld()
        await driver.emit(.accountChanged(.signOut))
        for _ in 0..<200 where !(await transport.isQuarantined()) { try await Task.sleep(for: .milliseconds(1)) }
        await barrier.release()
        for _ in 0..<200 {
            if !(await driver.pending).isEmpty || !completion.states.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let pending = await driver.pending
        XCTAssertTrue(pending.isEmpty, "observed quarantine must stop queuing the old receipt")
        await transport.resetAfterAccountChange() // Completes the old buggy waiter on the red run.
        do { try await task.value; XCTFail("old operation succeeded") } catch {}
    }
    func testReceiptAcknowledgementCannotSucceedAcrossActualOwnerSwitch() async throws {
        let sequence = OwnerProbeSequence()
        let value = try LibraryPublication(id: "p", publishedAt: Date(), writerDeviceID: "mac")
        let record = try LibraryRecordMapper().record(publication: value)
        let driver = ScriptedDriver(send: {
            [.sent(saved: [record], failed: [], deleted: [], failedDeletes: [:]), .sendCompleted]
        }, identity: { await sequence.next() })
        let transport = try cloudEndpoint(driver, owner: "owner")
        await XCTAssertThrowsErrorAsync(try await transport.publishPublication(value)) { _ in }
        let held = await transport.isQuarantined()
        XCTAssertTrue(held)
    }
    func testPersistedStartupHoldBlocksAllReadsAndWritesDespiteOwnerConfirmation() async throws {
        let calls = FactoryLog()
        let probes = FactoryLog()
        let driver = ScriptedDriver(fetch: { _ = calls.record(nil); return [.fetchCompleted] },
            send: { _ = calls.record(nil); return [.sendCompleted] },
            identity: { _ = probes.record(nil); return .init(currentOwnerToken: "owner") })
        let transport = try cloudEndpoint(driver, owner: "owner", held: true)
        try await observeOwner(driver, transport, owner: "owner")
        let position = try makePosition(device: "mac")
        let intent = try LibraryIntent.requestMedia(entryID: position.entryID, deviceID: "mac", createdAt: Date())
        let offer = try LibraryMediaOffer(entryID: position.entryID, revisionID: position.revision,
            contentHash: "sha256:" + String(repeating: "a", count: 64), byteCount: 1,
            mediaType: "audio/mpeg", durationSeconds: 1)
        let publication = try receipt()
        await XCTAssertThrowsErrorAsync(try await transport.fetchChanges(since: nil)) { _ in }
        await XCTAssertThrowsErrorAsync(try await transport.push(changes: [])) { _ in }
        await XCTAssertThrowsErrorAsync(try await transport.publish(position, as: .progress)) { _ in }
        await XCTAssertThrowsErrorAsync(try await transport.send(intent: intent)) { _ in }
        await XCTAssertThrowsErrorAsync(try await transport.publishMedia(offer: offer, fileURL: URL(fileURLWithPath: "/unused"))) { _ in }
        await XCTAssertThrowsErrorAsync(try await transport.publishPublication(publication)) { _ in }
        await XCTAssertThrowsErrorAsync(try await transport.readPublication()) { _ in }
        await XCTAssertThrowsErrorAsync(try await transport.fetchDeviceRecords()) { _ in }
        await XCTAssertThrowsErrorAsync(try await transport.mediaOffers()) { _ in }
        await XCTAssertThrowsErrorAsync(try await transport.fetchMedia(offer, progress: { _ in })) { _ in }
        await XCTAssertThrowsErrorAsync(try await transport.listIntents()) { _ in }
        let held = await transport.isQuarantined()
        let pending = await driver.pending
        XCTAssertTrue(held)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(calls.states.isEmpty, "held startup must never reach engine fetch/send")
        XCTAssertTrue(probes.states.isEmpty, "held startup must never probe the current account")
    }

    func testOnlyExplicitResetReleasesPersistedStartupHoldForVerifiedFullBootstrap() async throws {
        let calls = FactoryLog()
        let old = ScriptedDriver(identity: { .init(currentOwnerToken: "owner") })
        let fresh = ScriptedDriver(fetch: { _ = calls.record(nil); return [.fetchCompleted] },
            identity: { .init(currentOwnerToken: "owner") })
        let transport = try cloudEndpoint(old, owner: "owner", held: true, factory: { _ in fresh })
        await XCTAssertThrowsErrorAsync(try await transport.fetchChanges(since: nil)) { _ in }
        await transport.resetAfterAccountChange()
        let batch = try await transport.fetchChanges(since: nil)
        XCTAssertEqual(batch.provenance?.ownerToken, "owner")
        XCTAssertEqual(batch.provenance?.isFullBootstrap, true)
        XCTAssertEqual(calls.states.count, 1)
        let held = await transport.isQuarantined()
        XCTAssertFalse(held)
    }

    private let mapper = LibraryRecordMapper()
    private func receipt(_ seconds: TimeInterval = 1_000) throws -> LibraryPublication {
        try .init(id: "operation-1", publishedAt: Date(timeIntervalSince1970: seconds), writerDeviceID: "mac")
    }

    func testDedicatedRecordHasOneNameAndRoundTripsWithoutAContentChange() throws {
        let value = try receipt()
        let record = try mapper.record(publication: value)
        XCTAssertEqual(record.recordType, "LibraryPublicationRecord")
        XCTAssertEqual(record.recordID.recordName, "publication:library")
        XCTAssertEqual(record.recordID.zoneID, mapper.zoneID)
        XCTAssertEqual(try mapper.decode(record), .publication(value))
    }

    func testForgedSingletonNameIsRejected() throws {
        let original = try mapper.record(publication: receipt())
        let bad = CKRecord(recordType: original.recordType,
                           recordID: .init(recordName: "publication:other", zoneID: mapper.zoneID))
        bad[LibraryRecordMapper.payloadField] = original[LibraryRecordMapper.payloadField]
        XCTAssertThrowsError(try mapper.decode(bad))
    }

    func testMalformedPublicationPayloadIsRejectedByMapper() {
        let bad = CKRecord(recordType: LibraryRecordType.publication.rawValue, recordID: mapper.publicationRecordID)
        bad[LibraryRecordMapper.payloadField] = Data("bad".utf8) as CKRecordValue
        XCTAssertThrowsError(try mapper.decode(bad))
    }

    func testWriterPublishesAndReaderObservesByNameWithoutZoneScan() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        try await mac.transport.publishPublication(receipt())
        let seen = try await phone.transport.readPublication()
        XCTAssertEqual(seen, try receipt())
        let scopes = await phone.driver.scopes
        let names = await phone.driver.askedNames
        XCTAssertTrue(scopes.isEmpty)
        XCTAssertEqual(names, [["publication:library"]])
        XCTAssertTrue(phone.log.states.isEmpty)
    }

    func testMissingNamedRecordRemainsUnknown() async throws {
        let fixture = try MediaFixture()
        let phone = try fixture.endpoint("phone", writer: false)
        let seen = try await phone.transport.readPublication()
        XCTAssertNil(seen)
    }

    func testReaderCannotPublishReceipt() async throws {
        let fixture = try MediaFixture()
        let phone = try fixture.endpoint("phone", writer: false)
        await XCTAssertThrowsErrorAsync(try await phone.transport.publishPublication(receipt())) {
            guard case .ownershipViolation? = $0 as? LibraryTransportError else { return XCTFail("reader admitted") }
        }
        let sends = await phone.driver.sendCount
        XCTAssertEqual(sends, 0)
    }

    func testWriterCannotForgeAReceiptForAnotherDevice() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let value = try LibraryPublication(id: "p", publishedAt: Date(), writerDeviceID: "phone")
        await XCTAssertThrowsErrorAsync(try await mac.transport.publishPublication(value)) { _ in }
        let sends = await mac.driver.sendCount
        XCTAssertEqual(sends, 0)
    }

    func testMissingSaveAcknowledgementIsAReceiptFailure() async throws {
        let driver = ScriptedDriver()
        let transport = try cloudEndpoint(driver)
        await XCTAssertThrowsErrorAsync(try await transport.publishPublication(receipt())) { _ in }
    }

    func testUnresolvedReceiptConflictCannotCountAsAcknowledged() async throws {
        let record = try mapper.record(publication: receipt())
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: record])
        let driver = ScriptedDriver(send: {
            [.sent(saved: [], failed: [.init(record: record, error: error)], deleted: [], failedDeletes: [:]), .sendCompleted]
        })
        let transport = try cloudEndpoint(driver)
        await XCTAssertThrowsErrorAsync(try await transport.publishPublication(receipt())) { _ in }
    }

    func testSameFetchKeepsValidObservationWhenOptionalRecordIsMalformed() async throws {
        let value = try receipt(9_000_000_000)
        let valid = try mapper.record(publication: value)
        let bad = CKRecord(recordType: valid.recordType, recordID: valid.recordID)
        bad[LibraryRecordMapper.payloadField] = Data("bad".utf8) as CKRecordValue
        let entry = try savedLibrary(.entry(makeEntry()))
        let driver = ScriptedDriver(fetch: {
            [.fetched(modifications: [valid, entry], deletions: []), .fetched(modifications: [bad], deletions: []),
             .stateUpdated(Data("state".utf8)), .fetchCompleted]
        })
        let transport = try cloudEndpoint(driver)
        let batch = try await transport.fetchChanges(since: nil)
        XCTAssertEqual(batch.observedPublication, value)
        XCTAssertEqual(batch.changes.count, 1)
        XCTAssertNil(batch.provenance)
    }
}

private func savedLibrary(_ change: LibraryChange) throws -> CKRecord {
    guard case let .save(record) = try LibraryRecordMapper().operation(for: change, existing: nil) else {
        throw LibraryTransportError.transport("expected save")
    }
    return stamped(record, 1_700_000_000)
}

private func cloudEndpoint(_ driver: ScriptedDriver, state: LibraryChangeToken? = nil,
                           owner: String? = nil, held: Bool = false, factory: CloudKitEngineDriverFactory? = nil) throws -> CloudKitLibraryTransport {
    try CloudKitLibraryTransport(deviceID: "mac", isLibraryWriter: true, driver: driver,
                                 driverFactory: factory ?? { _ in ScriptedDriver() }, outbox: CloudKitLibraryOutbox(),
                                 state: state, knownOwnerToken: owner, initialReviewHold: held)
}

private func observeOwner(_ driver: ScriptedDriver, _ transport: CloudKitLibraryTransport, owner: String) async throws {
    await driver.emit(.accountChanged(.signIn, identity: .init(currentOwnerToken: owner)))
    for _ in 0..<200 {
        if await transport.verifiedOwnerToken() == owner { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("owner observation did not arrive")
}

extension CloudKitLibraryTransportTests {
    func testResetDuringSuspendedCurrentOwnerProbeRejectsTheOldOperation() async throws {
        let barrier = OwnerProbeBarrier()
        let driver = ScriptedDriver(identity: {
            await barrier.hold()
            return .init(currentOwnerToken: "owner")
        })
        let transport = try cloudEndpoint(driver)
        let task = Task { try await transport.fetchChanges(since: nil) }
        await barrier.waitUntilHeld()
        await transport.resetAfterAccountChange()
        await barrier.release()
        do { _ = try await task.value; XCTFail("reset admitted old probe") }
        catch { XCTAssertEqual(error as? LibraryTransportError, .superseded) }
        let owner = await transport.verifiedOwnerToken()
        let token = await transport.provisionalFetchToken
        XCTAssertNil(owner)
        XCTAssertNil(token)
    }
    func testCurrentProbeConfirmsStoredOwnerWithoutAnyEngineAccountEvent() async throws {
        let state = LibraryChangeToken(rawValue: Data("restored".utf8).base64EncodedString())
        let driver = ScriptedDriver(identity: { .init(currentOwnerToken: "owner") })
        let transport = try cloudEndpoint(driver, state: state, owner: "owner")
        let batch = try await transport.fetchChanges(since: state)
        XCTAssertEqual(batch.provenance?.ownerToken, "owner")
        XCTAssertEqual(batch.provenance?.isFullBootstrap, false)
    }

    func testCurrentProbeFirstAdoptionEstablishesVerifiedFullBootstrap() async throws {
        let driver = ScriptedDriver(identity: { .init(currentOwnerToken: "first-owner") })
        let transport = try cloudEndpoint(driver)
        let batch = try await transport.fetchChanges(since: nil)
        XCTAssertEqual(batch.provenance?.ownerToken, "first-owner")
        XCTAssertEqual(batch.provenance?.isFullBootstrap, true)
    }

    func testActualProbeMismatchQuarantinesBeforeFetching() async throws {
        let driver = ScriptedDriver(identity: { .init(currentOwnerToken: "different") })
        let transport = try cloudEndpoint(driver, owner: "saved-owner")
        await XCTAssertThrowsErrorAsync(try await transport.fetchChanges(since: nil)) { _ in }
        let held = await transport.isQuarantined()
        let owner = await transport.verifiedOwnerToken()
        XCTAssertTrue(held)
        XCTAssertNil(owner)
    }

    func testTransientProbeFailurePreservesCommittedCursorWithoutHoldingAccount() async throws {
        let state = LibraryChangeToken(rawValue: Data("saved".utf8).base64EncodedString())
        let driver = ScriptedDriver(identity: { throw CKError(.networkFailure) })
        let transport = try cloudEndpoint(driver, state: state, owner: "owner")
        await XCTAssertThrowsErrorAsync(try await transport.fetchChanges(since: state)) { _ in }
        let committed = await transport.committedFetchToken
        let held = await transport.isQuarantined()
        XCTAssertEqual(committed, state)
        XCTAssertFalse(held)
    }

    func testActualOwnerSwitchOnPostFetchProbeRejectsProvisionalState() async throws {
        let sequence = OwnerProbeSequence()
        let driver = ScriptedDriver(fetch: { [.stateUpdated(Data("new".utf8)), .fetchCompleted] },
                                    identity: { await sequence.next() })
        let transport = try cloudEndpoint(driver, owner: "owner")
        await XCTAssertThrowsErrorAsync(try await transport.fetchChanges(since: nil)) { _ in }
        let held = await transport.isQuarantined()
        let token = await transport.provisionalFetchToken
        XCTAssertTrue(held)
        XCTAssertNil(token)
    }

    func testNilBootstrapRebuildsLegacyEngineAndCollectsAllContentPages() async throws {
        let old = ScriptedDriver()
        let full = ScriptedDriver(fetch: { [] })
        let log = FactoryLog()
        let prior = LibraryChangeToken(rawValue: Data("old".utf8).base64EncodedString())
        let transport = try cloudEndpoint(old, state: prior, owner: "owner", factory: { state in _ = log.record(state); return full })
        try await observeOwner(old, transport, owner: "owner")
        let task = Task { try await transport.fetchChanges(since: nil) }
        await full.waitForFetch()
        let source = LibrarySource(id: try item("feed-1"), kind: .podcastFeed, title: "Feed")
        await full.emit(.fetched(modifications: [try savedLibrary(.source(source)), try savedLibrary(.entry(makeEntry()))], deletions: []))
        let listening = ListeningRecord(itemID: try item("ep-1"), completedAt: Date(), updatedAt: Date(), deviceID: "mac")
        await full.emit(.fetched(modifications: [try savedLibrary(.slot(QueueSlot(entryID: item("ep-1"), sortKey: 1))),
                                                try savedLibrary(.listening(listening))], deletions: []))
        await full.emit(.stateUpdated(Data("new".utf8)))
        await full.emit(.fetchCompleted)
        let batch = try await task.value
        XCTAssertEqual(Set(batch.changes.map(\.change.key.kind)), [.source, .entry, .slot, .listening])
        XCTAssertEqual(batch.provenance, .init(ownerToken: "owner", operationGeneration: 0, isFullBootstrap: true))
        XCTAssertEqual(log.states.count, 1)
        XCTAssertNil(log.states[0])
    }

    func testAccountResetWithNilPositionRebuildsAndIgnoresOldEpoch() async throws {
        let old = ScriptedDriver()
        let fresh = ScriptedDriver(fetch: { [] })
        let log = FactoryLog()
        let transport = try cloudEndpoint(old, factory: { state in _ = log.record(state); return fresh })
        await transport.resetAfterAccountChange()
        try await observeOwner(old, transport, owner: "owner")
        let task = Task { try await transport.fetchChanges(since: nil) }
        await fresh.waitForFetch()
        await old.emit(.fetched(modifications: [try savedLibrary(.entry(makeEntry("old")))], deletions: []))
        await old.emit(.fetchCompleted)
        await fresh.emit(.fetched(modifications: [try savedLibrary(.entry(makeEntry("new")))], deletions: []))
        await fresh.emit(.stateUpdated(Data("new-state".utf8)))
        await fresh.emit(.fetchCompleted)
        let batch = try await task.value
        XCTAssertEqual(batch.changes.map(\.change.key.id.rawValue), ["new"])
        XCTAssertEqual(batch.provenance?.isFullBootstrap, true)
        XCTAssertEqual(log.states.count, 1)
        XCTAssertNil(log.states[0])
    }

    func testStoredOwnerAloneDoesNotVerifyFullBootstrap() async throws {
        let transport = try cloudEndpoint(ScriptedDriver(), owner: "saved-owner")
        let batch = try await transport.fetchChanges(since: nil)
        XCTAssertNil(batch.provenance)
        let owner = await transport.verifiedOwnerToken()
        XCTAssertNil(owner)
    }

    func testObservedFirstAdoptionVerifiesOwnerButIncrementalIsNotBootstrap() async throws {
        let data = Data("state".utf8)
        let driver = ScriptedDriver(fetch: { [.stateUpdated(data), .fetchCompleted] })
        let transport = try cloudEndpoint(driver)
        try await observeOwner(driver, transport, owner: "adopted")
        let first = try await transport.fetchChanges(since: nil)
        XCTAssertEqual(first.provenance?.ownerToken, "adopted")
        XCTAssertEqual(first.provenance?.isFullBootstrap, true)
        let next = try await transport.fetchChanges(since: first.token)
        XCTAssertEqual(next.provenance?.isFullBootstrap, false)
    }

    func testOwnerSwitchBetweenPagesAndCompletionRejectsTheBatch() async throws {
        let driver = ScriptedDriver(fetch: { [] })
        let transport = try cloudEndpoint(driver, owner: "owner")
        try await observeOwner(driver, transport, owner: "owner")
        let task = Task { try await transport.fetchChanges(since: nil) }
        await driver.waitForFetch()
        await driver.emit(.fetched(modifications: [try savedLibrary(.entry(makeEntry()))], deletions: []))
        await driver.emit(.accountChanged(.signIn, identity: .init(currentOwnerToken: "different")))
        await driver.emit(.stateUpdated(Data("new".utf8)))
        await driver.emit(.fetchCompleted)
        do { _ = try await task.value; XCTFail("account switch returned batch") } catch {}
        let token = await transport.provisionalFetchToken
        let owner = await transport.verifiedOwnerToken()
        XCTAssertNil(token)
        XCTAssertNil(owner)
    }

    func testFailedAccumulationRetryRebuildsFromCommittedPosition() async throws {
        let prior = Data("committed".utf8)
        let token = LibraryChangeToken(rawValue: prior.base64EncodedString())
        let invalid = CKRecord(recordType: LibraryRecordType.entry.rawValue,
                               recordID: LibraryRecordMapper().recordID(for: .init(kind: .entry, id: try item("broken"))))
        let bad = ScriptedDriver(fetch: { [.fetched(modifications: [invalid], deletions: []), .stateUpdated(Data("bad".utf8)), .fetchCompleted] })
        let good = ScriptedDriver(fetch: { [.stateUpdated(Data("good".utf8)), .fetchCompleted] })
        let log = FactoryLog()
        let transport = try cloudEndpoint(bad, state: token, factory: { state in _ = log.record(state); return good })
        await XCTAssertThrowsErrorAsync(try await transport.fetchChanges(since: token)) { _ in }
        let committed = await transport.committedFetchToken
        XCTAssertEqual(committed, token)
        _ = try await transport.fetchChanges(since: token)
        XCTAssertEqual(log.states, [prior])
    }
}

private actor OwnerProbeSequence {
    private var reads = 0
    func next() -> CloudKitAccountIdentity {
        reads += 1
        return .init(currentOwnerToken: reads == 1 ? "owner" : "different")
    }
}

private actor OwnerProbeBarrier {
    private var arrived = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilHeld() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
