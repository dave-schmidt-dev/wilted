import CloudKit
import Foundation

/// CloudKit events reduced to values that can be injected into the transport tests.
public enum CloudKitEngineEvent: @unchecked Sendable {
    case stateUpdated(Data)
    case willFetch
    case fetched(modifications: [CKRecord], deletions: [CloudKitRecordDeletion])
    case didFetchRecordZoneChanges
    case fetchCompleted
    case willSend
    case sent(saved: [CKRecord], failed: [CloudKitRecordFailure], deleted: [CKRecord.ID], failedDeletes: [CKRecord.ID: CKError])
    case sendCompleted
    case accountChanged
    case ignored
}

public struct CloudKitRecordDeletion: @unchecked Sendable {
    public let recordID: CKRecord.ID
    public let recordType: String

    public init(recordID: CKRecord.ID, recordType: String) {
        self.recordID = recordID
        self.recordType = recordType
    }
}

public struct CloudKitRecordFailure: @unchecked Sendable {
    public let record: CKRecord
    public let error: Error

    public init(record: CKRecord, error: Error) {
        self.record = record
        self.error = error
    }
}

/// An injectable seam around CKSyncEngine. Implementations own all mutable engine state.
public protocol CloudKitEngineDriver: Sendable {
    var events: AsyncStream<CloudKitEngineEvent> { get async }
    func ensureZone() async throws
    func fetchChanges() async throws
    func sendChanges() async throws
    func cancelOperations() async
    func resetZoneBootstrap() async
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async
    nonisolated func isValidStateData(_ data: Data) -> Bool
}

public extension CloudKitEngineDriver {
    func ensureZone() async throws {}
    func resetZoneBootstrap() async {}
}

/// The production driver. It does not expose CKSyncEngine to WiltedSync or tests.
///
/// The state serialization is fixed when the engine is constructed. Recovery that
/// intentionally discards engine state must create a new driver with `nil` state;
/// clearing a transport's cached bytes does not reset this driver's live engine.
public actor LiveCloudKitEngineDriver: CloudKitEngineDriver {
    private let engine: CKSyncEngine
    private let delegate: CloudKitEngineDelegateProxy
    private let zoneBootstrap: any CloudKitZoneBootstrap

    public init(database: CKDatabase, stateSerialization: CKSyncEngine.State.Serialization? = nil,
                automaticallySync: Bool = false,
                zoneBootstrap: (any CloudKitZoneBootstrap)? = nil,
                recordProvider: @escaping @Sendable (CKRecord.ID) async -> CKRecord? = { _ in nil }) {
        let delegate = CloudKitEngineDelegateProxy(recordProvider: recordProvider)
        self.delegate = delegate
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: stateSerialization, delegate: delegate)
        configuration.automaticallySync = automaticallySync
        self.engine = CKSyncEngine(configuration)
        self.zoneBootstrap = zoneBootstrap ?? LiveCloudKitZoneBootstrap(database: database)
    }

    public var events: AsyncStream<CloudKitEngineEvent> { get async { delegate.events } }
    public func ensureZone() async throws { try await zoneBootstrap.ensureZone() }
    public func fetchChanges() async throws { try await engine.fetchChanges() }
    public func sendChanges() async throws {
        try await engine.sendChanges()
    }
    public func cancelOperations() async {
        await zoneBootstrap.cancel()
        await engine.cancelOperations()
    }
    public func resetZoneBootstrap() async { await zoneBootstrap.invalidate() }
    public func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {
        engine.state.add(pendingRecordZoneChanges: changes)
    }
    public nonisolated func isValidStateData(_ data: Data) -> Bool {
        data.isEmpty || (try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)) != nil
    }
}

private actor CloudKitEngineDelegateProxy: CKSyncEngineDelegate {
    let events: AsyncStream<CloudKitEngineEvent>
    private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
    private let recordProvider: @Sendable (CKRecord.ID) async -> CKRecord?

    init(recordProvider: @escaping @Sendable (CKRecord.ID) async -> CKRecord?) {
        let (events, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.recordProvider = recordProvider
    }

    func yield(_ event: CloudKitEngineEvent) { continuation.yield(event) }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(value):
            if let data = try? JSONEncoder().encode(value.stateSerialization) { yield(.stateUpdated(data)) }
        case .willFetchChanges: yield(.willFetch)
        case let .fetchedRecordZoneChanges(value):
            let deletions = value.deletions.map { CloudKitRecordDeletion(recordID: $0.recordID, recordType: $0.recordType) }
            yield(.fetched(modifications: value.modifications.map(\.record), deletions: deletions))
        case .willFetchRecordZoneChanges: yield(.willFetch)
        case .didFetchRecordZoneChanges: yield(.didFetchRecordZoneChanges)
        case .didFetchChanges: yield(.fetchCompleted)
        case .willSendChanges: yield(.willSend)
        case let .sentRecordZoneChanges(value):
            let failures = value.failedRecordSaves.map { CloudKitRecordFailure(record: $0.record, error: $0.error) }
            yield(.sent(saved: value.savedRecords, failed: failures, deleted: value.deletedRecordIDs,
                        failedDeletes: value.failedRecordDeletes))
        case .didSendChanges: yield(.sendCompleted)
        case .accountChange: yield(.accountChanged)
        case .fetchedDatabaseChanges, .sentDatabaseChanges: yield(.ignored)
        @unknown default: yield(.ignored)
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scoped = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: scoped, recordProvider: recordProvider)
    }
}
