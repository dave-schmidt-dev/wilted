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
        isLiveAllowed: Bool = NSClassFromString("XCTestCase") == nil,
        transportFactory: TransportFactory? = nil
    ) -> LibraryAppModel {
        let deviceID = stableDeviceID(defaults: defaults)
        let storeURL = directory.appendingPathComponent("library-state.json")
        let (events, quarantine) = AsyncStream<Void>.makeStream()
        let (built, store) = buildTransport(deviceID: deviceID, storeURL: storeURL, defaults: defaults, isLiveAllowed: isLiveAllowed, factory: transportFactory)
        monitorAccountChanges(built.signals, store: store, quarantine: quarantine)
        let reset = built.reset
        // UserDefaults is documented thread-safe; it just is not annotated Sendable.
        nonisolated(unsafe) let sharedDefaults = defaults
        let recovery = LibraryAccountRecovery(quarantineEvents: events) {
            do {
                try await reset()
                try await store.discard()
                sharedDefaults.removeObject(forKey: ownerTokenKey)
                return FileLibraryStore(url: storeURL)
            } catch {
                try? await store.quarantine()
                throw error
            }
        }
        return LibraryAppModel(
            transport: built.transport, store: store, deviceID: deviceID, recovery: recovery,
            ownPositionsURL: directory.appendingPathComponent("own-positions.json"))
    }

    /// Constructor failure retains the same mirror and expected owner; it never retries unowned.
    private static func buildTransport(
        deviceID: String, storeURL: URL, defaults: UserDefaults, isLiveAllowed: Bool, factory: TransportFactory?
    ) -> (Built, FileLibraryStore) {
        let store = FileLibraryStore(url: storeURL, historicalOwner: defaults.string(forKey: ownerTokenKey))
        do {
            let create = factory ?? makeCloudKitTransport
            let built = try create(deviceID, store.initialCursor, store.initialOwnerToken, isLiveAllowed, store.initialReviewHold)
            return (built, store)
        } catch {
            log.error("Library transport could not start; retained the saved library.")
            return ((UnavailableLibraryTransport(reason: "iCloud library sync could not start."), {}, nil), store)
        }
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

    typealias Built = (transport: any LibraryTransport, reset: @Sendable () async throws -> Void,
                               signals: AsyncStream<CloudKitAccountChangeSignal>?)

    /// Narrow constructor seam; tests can fail construction without any account or cloud access.
    typealias TransportFactory = @MainActor (String, LibraryChangeToken?, String?, Bool, Bool) throws -> Built

    private static func makeCloudKitTransport(
        _ deviceID: String, _ cursor: LibraryChangeToken?, _ owner: String?, _ isLiveAllowed: Bool, _ initialReviewHold: Bool
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
            outbox: outbox, state: cursor, knownOwnerToken: owner, initialReviewHold: initialReviewHold)
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
        let container = CKContainer(identifier: containerIdentifier)
        let database = container.privateCloudDatabase
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
                recordProvider: { outbox.record(for: $0) }, currentAccountResolver: {
                    let recordID = try await container.userRecordID()
                    return CloudKitAccountIdentity(currentOwnerToken: CloudKitAccountIdentity.token(for: recordID.recordName))
                })
        }
    }
#endif

    /// Saves the hold fence before notifying the model; account confirmation never binds legacy content.
    private static func monitorAccountChanges(
        _ signals: AsyncStream<CloudKitAccountChangeSignal>?, store: FileLibraryStore, quarantine: AsyncStream<Void>.Continuation
    ) {
        guard let signals else { return }
        Task {
            for await signal in signals {
                switch signal {
                case .ownershipAdopted, .ownershipConfirmed: break
                case .quarantineRequired:
                    do { try await store.quarantine() }
                    catch { log.error("Account review hold could not be saved; sync remains held locally.") }
                    quarantine.yield()
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
