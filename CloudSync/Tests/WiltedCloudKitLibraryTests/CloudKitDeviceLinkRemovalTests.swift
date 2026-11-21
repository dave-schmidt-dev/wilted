import CloudKit
import Foundation
import WiltedCloudKit
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

final class CloudKitDeviceLinkRemovalTests: XCTestCase {
    func testAccountChangeDuringOwnerProbePreventsRawLinkDeletion() async throws {
        let probe = RemovalBarrier()
        let driver = DeviceLinkRemovalDriver(identity: {
            await probe.hold()
            return .init(currentOwnerToken: "fixture-owner")
        })
        let transport = try makeTransport(driver)
        let task = Task { try await transport.deleteDeviceLink(deviceID: "fixture-device") }

        guard await waitUntil({ await probe.hasEntered }) else {
            await probe.release()
            _ = await task.result
            return XCTFail("deletion must probe the current account before touching CloudKit")
        }
        await driver.emit(.accountChanged(.signIn, identity: .init(currentOwnerToken: "other-owner")))
        let quarantined = await waitUntil { await transport.isQuarantined() }
        await probe.release()
        XCTAssertTrue(quarantined, "the simulated account change must be observed")

        switch await task.result {
        case .success:
            XCTFail("an account change during the owner probe must reject the deletion")
        case .failure:
            break
        }
        let deleted = await driver.deletedNames
        XCTAssertTrue(deleted.isEmpty, "no raw deletion may run after the account changed")
    }

    func testAccountChangeDuringRawDeleteRejectsTheStaleCompletion() async throws {
        let deletion = RemovalBarrier()
        let driver = DeviceLinkRemovalDriver(
            identity: { .init(currentOwnerToken: "fixture-owner") },
            delete: { _ in await deletion.hold() })
        let transport = try makeTransport(driver)
        let task = Task { try await transport.deleteDeviceLink(deviceID: "fixture-device") }

        guard await waitUntil({ await deletion.hasEntered }) else {
            await deletion.release()
            _ = await task.result
            return XCTFail("the selected link deletion did not reach its fake transport")
        }
        await driver.emit(.accountChanged(.signIn, identity: .init(currentOwnerToken: "other-owner")))
        let quarantined = await waitUntil { await transport.isQuarantined() }
        await deletion.release()
        XCTAssertTrue(quarantined, "the simulated account change must be observed")

        switch await task.result {
        case .success:
            XCTFail("a deletion started under the old account must not report success")
        case .failure:
            break
        }
        let deleted = await driver.deletedNames
        XCTAssertEqual(deleted, ["devicelink:fixture-device"])
    }

    private func makeTransport(_ driver: DeviceLinkRemovalDriver) throws -> CloudKitLibraryTransport {
        try CloudKitLibraryTransport(
            deviceID: "fixture-mac", isLibraryWriter: true, driver: driver,
            driverFactory: { _ in driver }, outbox: CloudKitLibraryOutbox(), knownOwnerToken: "fixture-owner")
    }

    private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<250 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
}

private actor DeviceLinkRemovalDriver: CloudKitEngineDriver {
    typealias Identity = @Sendable () async throws -> CloudKitAccountIdentity?
    typealias Delete = @Sendable ([CKRecord.ID]) async throws -> Void

    nonisolated let stream: AsyncStream<CloudKitEngineEvent>
    private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
    private let identity: Identity
    private let delete: Delete
    private(set) var deletedNames: [String] = []

    init(identity: @escaping Identity = { nil }, delete: @escaping Delete = { _ in }) {
        (stream, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        self.identity = identity
        self.delete = delete
    }

    var events: AsyncStream<CloudKitEngineEvent> { get async { stream } }
    func currentAccountIdentity() async throws -> CloudKitAccountIdentity? { try await identity() }
    func fetchChanges() async throws { continuation.yield(.fetchCompleted) }
    func sendChanges() async throws { continuation.yield(.sendCompleted) }
    func cancelOperations() async {}
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {}
    func deleteRecordsRaw(_ ids: [CKRecord.ID]) async throws {
        deletedNames += ids.map(\.recordName)
        try await delete(ids)
    }
    func emit(_ event: CloudKitEngineEvent) { continuation.yield(event) }
    nonisolated func isValidStateData(_ data: Data) -> Bool { true }
}

private actor RemovalBarrier {
    private var entered = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { entered }

    func hold() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
