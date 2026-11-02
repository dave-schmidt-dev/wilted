import CloudKit
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

/// Tests that per-record CloudKit errors carry rate-limiting, service-unavailable and zone-busy pressure
/// with their Retry-After to an error recognised by `TransportPressureClassifier`.
final class CloudKitPressureMappingTests: XCTestCase {
    private actor PressureDriver: CloudKitEngineDriver {
        nonisolated let stream: AsyncStream<CloudKitEngineEvent>
        private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
        private let errorToThrowOnSend: CKError
        private var pending: [CKSyncEngine.PendingRecordZoneChange] = []

        init(error: CKError) {
            self.errorToThrowOnSend = error
            (stream, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        }

        var events: AsyncStream<CloudKitEngineEvent> { get async { stream } }
        func cancelOperations() async {}
        func fetchChanges() async throws { continuation.yield(.fetchCompleted) }
        func fetchChanges(zoneIDs: Set<CKRecordZone.ID>) async throws { continuation.yield(.fetchCompleted) }
        func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async { pending += changes }
        nonisolated func isValidStateData(_ data: Data) -> Bool { true }

        func sendChanges() async throws {
            var failed: [CloudKitRecordFailure] = []
            for change in pending {
                if case let .saveRecord(id) = change {
                    failed.append(CloudKitRecordFailure(record: CKRecord(recordType: "Test", recordID: id), error: errorToThrowOnSend))
                }
            }
            pending = []
            continuation.yield(.sent(saved: [], failed: failed, deleted: [], failedDeletes: [:]))
            continuation.yield(.sendCompleted)
        }

        func fetchRecordsIfPresent(_ ids: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord] { [] }
        func ensureZone(_ zoneID: CKRecordZone.ID) async throws {}
        func saveRecordRaw(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws {}
        func fetchAssetRecordRaw(
            _ id: CKRecord.ID,
            assetField: String,
            to destination: URL,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws -> CKRecord {
            throw CloudKitSyncError.assetUnavailable(id.recordName)
        }
    }

    func testPerRecordRequestRateLimitedWithRetryAfterClassifiesAsPressure() async throws {
        let ckError = CKError(
            .requestRateLimited,
            userInfo: [
                CKErrorRetryAfterKey: NSNumber(value: 45.0),
                NSLocalizedDescriptionKey: "Request was rate limited."
            ]
        )
        let driver = PressureDriver(error: ckError)
        let outbox = CloudKitLibraryOutbox()
        let transport = try CloudKitLibraryTransport(
            deviceID: "phone",
            isLibraryWriter: false,
            driver: driver,
            driverFactory: { _ in driver },
            outbox: outbox
        )

        let position = try DevicePlaybackPosition(
            deviceID: "phone", entryID: ItemID(rawValue: "ep-1"), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: 120, rate: 1.0, isPlaying: true, epoch: 1
        )

        do {
            try await transport.publish(position, as: .nowPlaying)
            XCTFail("expected write to fail with pressure")
        } catch {
            let classified = TransportPressureClassifier.classify(error)
            XCTAssertEqual(classified, TransportPressure(kind: .rateLimited, retryAfter: 45.0))
        }
    }

    func testPerRecordServiceUnavailableClassifiesAsPressure() async throws {
        let ckError = CKError(
            .serviceUnavailable,
            userInfo: [
                CKErrorRetryAfterKey: NSNumber(value: 15.0),
                NSLocalizedDescriptionKey: "Service unavailable."
            ]
        )
        let driver = PressureDriver(error: ckError)
        let outbox = CloudKitLibraryOutbox()
        let transport = try CloudKitLibraryTransport(
            deviceID: "phone",
            isLibraryWriter: false,
            driver: driver,
            driverFactory: { _ in driver },
            outbox: outbox
        )

        let intent = try LibraryIntent.requestMedia(
            entryID: ItemID(rawValue: "ep-1"),
            deviceID: "phone",
            createdAt: Date(),
            id: "req-1"
        )

        do {
            try await transport.send(intent: intent)
            XCTFail("expected write to fail with pressure")
        } catch {
            let classified = TransportPressureClassifier.classify(error)
            XCTAssertEqual(classified, TransportPressure(kind: .serviceUnavailable, retryAfter: 15.0))
        }
    }

    func testPerRecordZoneBusyClassifiesAsRateLimitedPressure() async throws {
        let ckError = CKError(
            .zoneBusy,
            userInfo: [
                NSLocalizedDescriptionKey: "Zone is busy."
            ]
        )
        let driver = PressureDriver(error: ckError)
        let outbox = CloudKitLibraryOutbox()
        let transport = try CloudKitLibraryTransport(
            deviceID: "phone",
            isLibraryWriter: false,
            driver: driver,
            driverFactory: { _ in driver },
            outbox: outbox
        )

        let position = try DevicePlaybackPosition(
            deviceID: "phone", entryID: ItemID(rawValue: "ep-1"), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: 60, rate: 1.0, isPlaying: false, epoch: 1
        )

        do {
            try await transport.publish([(record: position, channel: .progress)])
            XCTFail("expected writeMany to fail with pressure")
        } catch {
            let classified = TransportPressureClassifier.classify(error)
            XCTAssertEqual(classified?.kind, .rateLimited)
            XCTAssertNil(classified?.retryAfter)
        }
    }
}
