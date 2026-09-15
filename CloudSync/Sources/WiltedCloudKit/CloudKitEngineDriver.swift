import CloudKit
import CryptoKit
import Foundation

/// The account transition reported by CKSyncEngine without exposing account IDs.
public enum CloudKitAccountChangeType: String, Codable, Sendable {
    case signIn
    case signOut
    case switchAccounts

    var userFacingName: String {
        switch self {
        case .signIn: "iCloud sign-in"
        case .signOut: "iCloud sign-out"
        case .switchAccounts: "iCloud account switch"
        }
    }
}

/// Who an account change moved between, reduced to a device-local token.
///
/// `CKRecord.ID`s for iCloud users never leave this adapter. A sign-in carries a
/// non-reversible token derived from the current user record so ownership can be
/// compared across launches, which is the only way to tell a first adoption apart
/// from a switch that happened while engine state was missing.
public struct CloudKitAccountIdentity: Equatable, Sendable {
    public let currentOwnerToken: String?
    public let hadPreviousOwner: Bool

    public init(currentOwnerToken: String? = nil, hadPreviousOwner: Bool = false) {
        self.currentOwnerToken = currentOwnerToken
        self.hadPreviousOwner = hadPreviousOwner
    }

    /// Derives the stored token for a user record.
    ///
    /// Hashed rather than stored raw so the persisted library never holds an account
    /// identifier, and prefixed so a future scheme change is distinguishable.
    public static func token(for recordName: String) -> String {
        "sha256:" + SHA256.hash(data: Data(recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// How a reported account change resolves against the owner recorded on this device.
public enum CloudKitAccountOwnership: Equatable, Sendable {
    /// No account had claimed the local work, so this one takes it without review.
    case adopt(token: String)
    /// The recorded owner signed in again, which is what a lost engine state looks like.
    case confirmed
    /// Ambiguous or genuinely different: hold the work until the owner reviews it.
    case quarantine

    /// Classifies an account change against the owner this device already recorded.
    ///
    /// Only a first sign-in can resolve without review, and only when it names a current
    /// user and no previous one. Sign-outs, switches, and any sign-in that disagrees with
    /// the recorded owner stay quarantined: local work may belong to another account and
    /// CloudKit cannot answer that after the fact.
    public static func resolve(changeType: CloudKitAccountChangeType,
                               identity: CloudKitAccountIdentity,
                               recordedOwnerToken: String?) -> CloudKitAccountOwnership {
        guard changeType == .signIn, !identity.hadPreviousOwner, let token = identity.currentOwnerToken else {
            return .quarantine
        }
        guard let recordedOwnerToken else { return .adopt(token: token) }
        return recordedOwnerToken == token ? .confirmed : .quarantine
    }
}

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
    case accountChanged(CloudKitAccountChangeType, identity: CloudKitAccountIdentity)
    case ignored

    /// Compatibility spelling for callers that do not need the transition type.
    public static var accountChanged: Self { .accountChanged(.switchAccounts, identity: .init()) }

    /// Compatibility spelling for callers that do not exercise account identity.
    public static func accountChanged(_ changeType: CloudKitAccountChangeType) -> Self {
        .accountChanged(changeType, identity: .init())
    }
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
    /// Fetches records by identity for explicit, on-demand asset retrieval.
    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord]
    func sendChanges() async throws
    func cancelOperations() async
    func resetZoneBootstrap() async
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async
    nonisolated func isValidStateData(_ data: Data) -> Bool
}

/// Reconstructs an engine from the last committed serialization.
public typealias CloudKitEngineDriverFactory = @Sendable (Data?) throws -> any CloudKitEngineDriver

public extension CloudKitEngineDriver {
    func ensureZone() async throws {}
    func resetZoneBootstrap() async {}
    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
        guard ids.isEmpty else { throw CloudKitSyncError.cloudKit(code: -1, message: "Explicit record fetch is unavailable") }
        return []
    }
}

actor CloudKitRecordFetchCoordinator {
    typealias RecordFetcher = @Sendable ([CKRecord.ID]) async throws -> [CKRecord]

    private let recordFetcher: RecordFetcher
    private var sequence: UInt64 = 0
    private var activeFetches: [UInt64: Task<[CKRecord], Error>] = [:]

    init(recordFetcher: @escaping RecordFetcher) { self.recordFetcher = recordFetcher }

    func fetch(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
        guard !ids.isEmpty else { return [] }
        sequence &+= 1
        let fetchID = sequence
        let recordFetcher = self.recordFetcher
        let fetchTask = Task { try await recordFetcher(ids) }
        activeFetches[fetchID] = fetchTask

        do {
            let records = try await withTaskCancellationHandler {
                try await fetchTask.value
            } onCancel: {
                // Cancel the exact task this invocation created. Dispatching an
                // unbound actor callback here could cancel a later fetch after
                // this cancellation handler finally gets scheduled.
                fetchTask.cancel()
            }
            guard activeFetches.removeValue(forKey: fetchID) != nil,
                  !fetchTask.isCancelled else {
                throw CancellationError()
            }
            return records
        } catch {
            activeFetches.removeValue(forKey: fetchID)
            throw error
        }
    }

    func cancelAll() {
        let fetches = Array(activeFetches.values)
        activeFetches.removeAll()
        for fetch in fetches { fetch.cancel() }
    }
}

/// The production driver. It does not expose CKSyncEngine to WiltedSync or tests.
///
/// The state serialization is fixed when the engine is constructed. CKSyncEngine
/// resets its live state for account-change events; other recovery that
/// intentionally discards state must create a new driver with `nil` state.
public actor LiveCloudKitEngineDriver: CloudKitEngineDriver {
    private let database: CKDatabase
    private let engine: CKSyncEngine
    private let delegate: CloudKitEngineDelegateProxy
    private let zoneBootstrap: any CloudKitZoneBootstrap
    private let recordFetchCoordinator: CloudKitRecordFetchCoordinator

    public init(database: CKDatabase, stateSerialization: CKSyncEngine.State.Serialization? = nil,
                automaticallySync: Bool = false,
                zoneBootstrap: (any CloudKitZoneBootstrap)? = nil,
                recordProvider: @escaping @Sendable (CKRecord.ID) async -> CKRecord? = { _ in nil },
                recordFetcher: (@Sendable ([CKRecord.ID]) async throws -> [CKRecord])? = nil) {
        self.database = database
        self.recordFetchCoordinator = CloudKitRecordFetchCoordinator(recordFetcher: recordFetcher ?? { ids in
            let results = try await database.records(for: ids)
            return try results.map { try $0.value.get() }
        })
        let delegate = CloudKitEngineDelegateProxy(recordProvider: recordProvider)
        self.delegate = delegate
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: stateSerialization, delegate: delegate)
        configuration.automaticallySync = automaticallySync
        self.engine = CKSyncEngine(configuration)
        self.zoneBootstrap = zoneBootstrap ?? LiveCloudKitZoneBootstrap(database: database)
    }

    /// The production recovery constructor. Each call creates a new delegate,
    /// event stream, zone bootstrap, and CKSyncEngine from committed state.
    public nonisolated static func makeFactory(
        database: CKDatabase,
        automaticallySync: Bool = false,
        recordProvider: @escaping @Sendable (CKRecord.ID) async -> CKRecord? = { _ in nil }
    ) -> CloudKitEngineDriverFactory {
        { stateData in
            let serialization: CKSyncEngine.State.Serialization?
            if let stateData {
                guard let decoded = try? JSONDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: stateData
                ) else {
                    throw CloudKitSyncError.stateCorrupt
                }
                serialization = decoded
            } else {
                serialization = nil
            }
            return LiveCloudKitEngineDriver(
                database: database,
                stateSerialization: serialization,
                automaticallySync: automaticallySync,
                recordProvider: recordProvider
            )
        }
    }

    public var events: AsyncStream<CloudKitEngineEvent> { get async { delegate.events } }
    public func ensureZone() async throws { try await zoneBootstrap.ensureZone() }
    public func fetchChanges() async throws { try await engine.fetchChanges() }
    public func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
        try await recordFetchCoordinator.fetch(ids)
    }
    public func sendChanges() async throws {
        try await engine.sendChanges()
    }
    public func cancelOperations() async {
        await recordFetchCoordinator.cancelAll()
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
        case let .accountChange(value):
            // The Swift-refined event carries the user records on the case itself, so the
            // token is derived here and the identifiers stop at this boundary.
            switch value.changeType {
            case let .signIn(currentUser):
                yield(.accountChanged(.signIn, identity: .init(
                    currentOwnerToken: CloudKitAccountIdentity.token(for: currentUser.recordName),
                    hadPreviousOwner: false)))
            case .signOut:
                yield(.accountChanged(.signOut, identity: .init(currentOwnerToken: nil, hadPreviousOwner: true)))
            case let .switchAccounts(_, currentUser):
                yield(.accountChanged(.switchAccounts, identity: .init(
                    currentOwnerToken: CloudKitAccountIdentity.token(for: currentUser.recordName),
                    hadPreviousOwner: true)))
            @unknown default:
                yield(.accountChanged(.switchAccounts, identity: .init()))
            }
        case .fetchedDatabaseChanges, .sentDatabaseChanges: yield(.ignored)
        @unknown default: yield(.ignored)
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scoped = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: scoped, recordProvider: recordProvider)
    }
}
