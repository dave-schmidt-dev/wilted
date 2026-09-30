import Foundation
import OSLog
#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif
import WiltedCloudKit
import WiltedCloudKitLibrary
import WiltedDomain
import WiltedLibrary

/// Builds the production library stack: `CloudKitLibraryTransport` on `WiltedLibraryZone`
/// (created on first use by the engine driver), a store persisted under Application Support
/// whose cursor is the CKSyncEngine state serialization, and a stable per-install device id.
///
/// Tests and previews inject their own transport into `LibraryAppModel`; nothing here
/// falls back to an in-memory backend. Without `WILTED_CLOUDKIT_LIVE`, or under XCTest, the
/// transport reports that sync is unavailable rather than touching an iCloud account.
@MainActor
enum LibraryEnvironment {
    static let containerIdentifier = "iCloud.com.zerodelta.wilted"
    static let zoneName = "WiltedLibraryZone"
    nonisolated static let deviceIDKey = "wilted.library.deviceID"
    nonisolated static let ownerTokenKey = "wilted.library.ownerToken"
    private static let log = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryEnvironment")

    static func makeModel(
        defaults: UserDefaults = .standard,
        directory: URL = defaultDirectory(),
        isLiveAllowed: Bool = NSClassFromString("XCTestCase") == nil
    ) -> LibraryAppModel {
        let deviceID = stableDeviceID(defaults: defaults)
        let storeURL = directory.appendingPathComponent("library-state.json")
        let (events, quarantine) = AsyncStream<Void>.makeStream()
        let (built, store) = buildTransport(deviceID: deviceID, storeURL: storeURL, defaults: defaults, isLiveAllowed: isLiveAllowed)
        monitorAccountChanges(built.signals, defaults: defaults, quarantine: quarantine)
        let reset = built.reset
        // UserDefaults is documented thread-safe; it just is not annotated Sendable.
        nonisolated(unsafe) let sharedDefaults = defaults
        let recovery = LibraryAccountRecovery(quarantineEvents: events) {
            await reset()
            sharedDefaults.removeObject(forKey: ownerTokenKey)
            store.discard()
            return FileLibraryStore(url: storeURL)
        }
        return LibraryAppModel(transport: built.transport, store: store, deviceID: deviceID, recovery: recovery)
    }

    /// Tries the persisted cursor first, then a clean start; a cursor the engine cannot read is
    /// dropped along with the content it belongs to.
    private static func buildTransport(
        deviceID: String, storeURL: URL, defaults: UserDefaults, isLiveAllowed: Bool
    ) -> (Built, FileLibraryStore) {
        var store = FileLibraryStore(url: storeURL)
        var owner = defaults.string(forKey: ownerTokenKey)
        for _ in 0..<2 {
            do {
                let built = try makeCloudKitTransport(
                    deviceID: deviceID, cursor: store.initialCursor, owner: owner, isLiveAllowed: isLiveAllowed)
                return (built, store)
            } catch {
                log.error("Library transport unavailable: \(String(describing: error), privacy: .public)")
                store.discard()
                store = FileLibraryStore(url: storeURL)
                owner = nil
            }
        }
        return ((UnavailableLibraryTransport(reason: "iCloud library sync could not start."), {}, nil), store)
    }

    /// A random id created once per install and kept in UserDefaults.
    static func stableDeviceID(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty { return existing }
        let created = "iphone-\(UUID().uuidString)"
        defaults.set(created, forKey: deviceIDKey)
        return created
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wilted", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    private typealias Built = (transport: any LibraryTransport, reset: @Sendable () async -> Void,
                               signals: AsyncStream<CloudKitAccountChangeSignal>?)

    private static func makeCloudKitTransport(
        deviceID: String, cursor: LibraryChangeToken?, owner: String?, isLiveAllowed: Bool
    ) throws -> Built {
#if WILTED_CLOUDKIT_LIVE
        guard isLiveAllowed else {
            return (UnavailableLibraryTransport(reason: "iCloud sync is off in tests."), {}, nil)
        }
        let outbox = CloudKitLibraryOutbox()
        let factory = makeDriverFactory(outbox: outbox)
        let state = try cursor.map { token -> Data in
            guard let data = Data(base64Encoded: token.rawValue) else { throw CloudKitSyncError.stateCorrupt }
            return data
        }
        let transport = try CloudKitLibraryTransport(
            deviceID: deviceID, isLibraryWriter: false, driver: try factory(state), driverFactory: factory,
            outbox: outbox, state: cursor, knownOwnerToken: owner)
        return (transport, { await transport.resetAfterAccountChange() }, transport.accountChanges)
#else
        return (UnavailableLibraryTransport(reason: "iCloud sync is not enabled in this build."), {}, nil)
#endif
    }

#if WILTED_CLOUDKIT_LIVE
    /// Live engines on the private database, each bootstrapping `WiltedLibraryZone`. The package's own
    /// `makeLiveFactory` is compiled out because the package target does not carry the live flag, so
    /// the same construction is done here from public API.
    private static func makeDriverFactory(outbox: CloudKitLibraryOutbox) -> CloudKitEngineDriverFactory {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let zoneID = LibraryRecordMapper().zoneID
        return { stateData in
            let serialization = try stateData.map { data -> CKSyncEngine.State.Serialization in
                guard let decoded = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data) else {
                    throw CloudKitSyncError.stateCorrupt
                }
                return decoded
            }
            return LiveCloudKitEngineDriver(
                database: database, stateSerialization: serialization,
                zoneBootstrap: LiveCloudKitZoneBootstrap(database: database, zoneID: zoneID),
                recordProvider: { outbox.record(for: $0) })
        }
    }
#endif

    /// Persists an adopted owner and turns a quarantine into a model event.
    private static func monitorAccountChanges(
        _ signals: AsyncStream<CloudKitAccountChangeSignal>?, defaults: UserDefaults, quarantine: AsyncStream<Void>.Continuation
    ) {
        guard let signals else { return }
        Task {
            for await signal in signals {
                switch signal {
                case let .ownershipAdopted(token): defaults.set(token, forKey: ownerTokenKey)
                case .quarantineRequired: quarantine.yield()
                case .ownershipConfirmed: break
                }
            }
        }
    }
}

/// Stands in when CloudKit cannot run; every operation fails with the reason.
struct UnavailableLibraryTransport: LibraryTransport {
    let reason: String
    private var failure: LibraryTransportError { .transport(reason) }

    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { throw failure }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { throw failure }
    func send(intent: LibraryIntent) async throws { throw failure }
    func listIntents() async throws -> [LibraryIntent] { throw failure }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { throw failure }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { throw failure }
    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws { throw failure }
    func mediaOffers() async throws -> [LibraryMediaOffer] { throw failure }
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL { throw failure }
    func removeMedia(entryID: ItemID) async throws { throw failure }
}

/// Read-only mirror persisted as JSON. The iPhone queues no local changes, so content, per-record
/// versions and the cursor are all there is to keep; the cursor is written in the same file as the
/// content it describes, so a launch can never resume from a position its content does not match.
actor FileLibraryStore: LibraryStore {
    private struct Versioned: Codable { let key: LibraryRecordKey; let version: UInt64 }
    private struct Persisted: Codable {
        var sources: [LibrarySource]
        var entries: [LibraryEntry]
        var slots: [QueueSlot]
        var listening: [ListeningRecord]
        var versions: [Versioned]
        var cursor: LibraryChangeToken?
    }

    private let url: URL
    private var current = LibraryStoreState()
    nonisolated let initialCursor: LibraryChangeToken?

    init(url: URL) {
        self.url = url
        var loaded = LibraryStoreState()
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            loaded.content = LibrarySnapshot(sources: saved.sources, entries: saved.entries, slots: saved.slots, listening: saved.listening)
            loaded.versions = Dictionary(saved.versions.map { ($0.key, $0.version) }, uniquingKeysWith: { _, last in last })
            loaded.cursor = saved.cursor
        }
        current = loaded
        initialCursor = loaded.cursor
    }

    nonisolated func discard() { try? FileManager.default.removeItem(at: url) }

    func state() -> LibraryStoreState { current }

    func commit(_ staged: StagedLibraryBatch) throws {
        guard current.revision == staged.priorState.revision else { throw LibraryTransportError.staleStagedBatch }
        var next = staged.nextState
        next.revision += 1
        try write(next)
        current = next
    }

    func enqueue(_ change: LibraryChange) throws { throw LibraryTransportError.ownershipViolation("The iPhone does not edit the library") }
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) throws {}
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) throws {}

    private func write(_ state: LibraryStoreState) throws {
        let content = state.content
        let saved = Persisted(
            sources: Array(content.sources.values), entries: Array(content.entries.values), slots: Array(content.slots.values),
            listening: Array(content.listening.values), versions: state.versions.map { Versioned(key: $0.key, version: $0.value) },
            cursor: state.cursor)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
    }
}
