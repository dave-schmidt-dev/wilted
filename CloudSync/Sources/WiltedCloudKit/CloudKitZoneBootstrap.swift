import CloudKit
import Foundation

/// Ensures Wilted's private custom zone exists before CKSyncEngine can save records into it.
public protocol CloudKitZoneBootstrap: Sendable {
    func ensureZone() async throws
    /// Cancels only an in-flight save. An already ensured zone remains valid.
    func cancel() async
    /// Invalidates the cached result so the next operation must save the zone again.
    func invalidate() async
}

/// A deterministic offline bootstrap used by injected drivers and tests.
public struct NoopCloudKitZoneBootstrap: CloudKitZoneBootstrap {
    public init() {}
    public func ensureZone() async throws {}
    public func cancel() async {}
    public func invalidate() async {}
}

/// Actor-isolated state machine for a one-time zone save.
///
/// The operation is injected so cancellation and account/zone invalidation can
/// be tested without contacting CloudKit.
public actor CloudKitZoneBootstrapState {
    private let saveOperation: @Sendable () async throws -> Void
    private var saveTask: Task<Void, Error>?
    private var saveGeneration = 0
    private var ensured = false

    public init(saveOperation: @escaping @Sendable () async throws -> Void) {
        self.saveOperation = saveOperation
    }

    public func ensureZone() async throws {
        if ensured { return }
        if let saveTask {
            _ = try await saveTask.value
            return
        }
        saveGeneration &+= 1
        let generation = saveGeneration
        let task = Task {
            try await saveOperation()
        }
        saveTask = task
        do {
            _ = try await task.value
            // A canceled/invalidated generation may finish after a replacement
            // save. It must not publish success into the newer bootstrap state.
            if saveGeneration == generation { ensured = true }
        } catch {
            if saveGeneration == generation { saveTask = nil }
            throw error
        }
        if saveGeneration == generation { saveTask = nil }
    }

    public func cancel() async {
        saveGeneration &+= 1
        saveTask?.cancel()
        saveTask = nil
    }

    public func invalidate() async {
        await cancel()
        ensured = false
    }
}

/// Saves the custom zone once per bootstrap instance. CloudKit zone saves are idempotent.
public actor LiveCloudKitZoneBootstrap: CloudKitZoneBootstrap {
    private let state: CloudKitZoneBootstrapState

    public init(database: CKDatabase, zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "WiltedZone", ownerName: CKCurrentUserDefaultName)) {
        let zone = CKRecordZone(zoneID: zoneID)
        self.state = CloudKitZoneBootstrapState {
            _ = try await database.save(zone)
        }
    }

    public func ensureZone() async throws { try await state.ensureZone() }
    public func cancel() async { await state.cancel() }
    public func invalidate() async { await state.invalidate() }
}
