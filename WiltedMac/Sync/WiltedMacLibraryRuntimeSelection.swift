import Foundation
import ObjectiveC
import WiltedCloudKit
import WiltedCloudKitLibrary
import WiltedDomain
import WiltedLibrary
#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

// MARK: - Build facts

/// What this binary was compiled as and where it runs. Production reads `current`; Debug model
/// tests inject any combination, so every selector branch runs outside conditional compilation.
struct WiltedMacLibraryBuildFacts: Equatable, Sendable {
    /// Compiled with `WILTED_CLOUDKIT_LIVE` (the Development and Release configurations).
    var compiledLive: Bool
    /// Running inside an XCTest host, which must never reach an iCloud account.
    var hostsTests: Bool

    static var current: Self {
        // The same XCTest marker `WiltedMacModel.hostsTests` reads, without its actor isolation.
        let hostsTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
#if WILTED_CLOUDKIT_LIVE
        return Self(compiledLive: true, hostsTests: hostsTests)
#else
        return Self(compiledLive: false, hostsTests: hostsTests)
#endif
    }
}

// MARK: - Selection

/// Which sync engine this launch runs. Exactly one is ever selected, so the library publisher and
/// the legacy article engine never run together.
///
/// A normal live build (Development or Release, outside a test host and fixture mode) selects the
/// library publisher by default. `WILTED_LIBRARY_SYNC=1` forces it on; any other non-empty value
/// forces it off, which keeps the legacy engine as before. Test hosts, non-live builds and
/// fixtures keep the legacy engine, inert without a live transport.
struct WiltedMacLibraryRuntimeSelection: Equatable, Sendable {
    enum Engine: Equatable, Sendable { case libraryPublisher, legacy, none }
    enum Reason: String, Equatable, Sendable {
        case explicitOn, explicitOff, liveDefault, nonLiveBuild, testHost, fixture
    }
    enum Override: Equatable, Sendable { case on, off, unset }

    static let environmentKey = "WILTED_LIBRARY_SYNC"

    let engine: Engine
    let reason: Reason

    static func override(in environment: [String: String]) -> Override {
        guard let value = environment[environmentKey], !value.isEmpty else { return .unset }
        return value == "1" ? .on : .off
    }

    static func select(environment: [String: String], facts: WiltedMacLibraryBuildFacts, fixtureMode: Bool) -> Self {
        switch override(in: environment) {
        case .on:
            // Fixture runs never publish, even when asked to (unchanged from the flag-only era).
            return fixtureMode ? Self(engine: .none, reason: .fixture) : Self(engine: .libraryPublisher, reason: .explicitOn)
        case .off:
            return Self(engine: .legacy, reason: .explicitOff)
        case .unset:
            if fixtureMode { return Self(engine: .legacy, reason: .fixture) }
            if facts.hostsTests { return Self(engine: .legacy, reason: .testHost) }
            if !facts.compiledLive { return Self(engine: .legacy, reason: .nonLiveBuild) }
            return Self(engine: .libraryPublisher, reason: .liveDefault)
        }
    }

    /// Whether the publisher may start on a transport. The default needs a managed transport
    /// (one that reports account changes, as the live CloudKit transport always does), so a live
    /// build never defaults to the unavailable stand-in or to unbound sending. An explicit `1`
    /// keeps today's behavior for attended and test runs.
    func admits(managedTransport: Bool) -> Bool {
        guard engine == .libraryPublisher else { return false }
        return reason == .explicitOn || managedTransport
    }
}

#if canImport(WiltedProducer)
import WiltedProducer

// MARK: - Model integration

private final class WiltedMacLibraryBuildFactsBox {
    let facts: WiltedMacLibraryBuildFacts
    init(_ facts: WiltedMacLibraryBuildFacts) { self.facts = facts }
}

private nonisolated(unsafe) var libraryBuildFactsKey: UInt8 = 0

extension WiltedMacModel {
    /// The build facts the selector reads; `current` unless a test injected others before bootstrap.
    var librarySyncBuildFacts: WiltedMacLibraryBuildFacts {
        get { (objc_getAssociatedObject(self, &libraryBuildFactsKey) as? WiltedMacLibraryBuildFactsBox)?.facts ?? .current }
        set { objc_setAssociatedObject(self, &libraryBuildFactsKey, WiltedMacLibraryBuildFactsBox(newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func libraryRuntimeSelection(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WiltedMacLibraryRuntimeSelection {
        .select(environment: environment, facts: librarySyncBuildFacts, fixtureMode: fixtureMode)
    }
}

// MARK: - Transports

/// Stands in when this build or process may not reach CloudKit. Every operation fails, so a
/// unit-test host or a non-live build never touches an iCloud account.
struct WiltedMacUnavailableLibraryTransport: LibraryTransport {
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

enum WiltedMacLibraryTransports {
    static let containerIdentifier = "iCloud.com.zerodelta.wilted"

    /// `CloudKitLibraryTransport` as the library writer on `WiltedLibraryZone`, or the
    /// unavailable stand-in without `WILTED_CLOUDKIT_LIVE` or under XCTest.
    static func production(deviceID: String, hostsTests: Bool) -> any LibraryTransport {
#if WILTED_CLOUDKIT_LIVE
        guard !hostsTests else { return WiltedMacUnavailableLibraryTransport(reason: "iCloud sync is off in tests.") }
        do {
            let outbox = CloudKitLibraryOutbox()
            let factory = driverFactory(outbox: outbox)
            return try CloudKitLibraryTransport(
                deviceID: deviceID, isLibraryWriter: true, driver: try factory(nil), driverFactory: factory, outbox: outbox
            )
        } catch {
            return WiltedMacUnavailableLibraryTransport(reason: "iCloud library sync could not start.")
        }
#else
        _ = (deviceID, hostsTests)
        return WiltedMacUnavailableLibraryTransport(reason: "iCloud sync is not enabled in this build.")
#endif
    }

#if WILTED_CLOUDKIT_LIVE
    private static func driverFactory(outbox: CloudKitLibraryOutbox) -> CloudKitEngineDriverFactory {
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

#if WILTED_CLOUDKIT_LIVE
    /// A read-only account check: the account status, then the user record name, hashed exactly
    /// as the CloudKit adapter hashes it. No record is written and no zone is touched.
    static func accountProbe() -> (@Sendable () async -> WiltedMacLibraryAccountProbeResult)? {
        { await probeAccount(container: CKContainer(identifier: containerIdentifier)) }
    }

    private static func probeAccount(container: CKContainer) async -> WiltedMacLibraryAccountProbeResult {
        do {
            switch try await container.accountStatus() {
            case .available:
                let recordID = try await container.userRecordID()
                return .signedIn(token: CloudKitAccountIdentity.token(for: recordID.recordName))
            case .noAccount, .restricted:
                return .noAccount
            case .couldNotDetermine, .temporarilyUnavailable:
                return .unavailable
            @unknown default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }
#else
    /// Non-live builds never check an account.
    static func accountProbe() -> (@Sendable () async -> WiltedMacLibraryAccountProbeResult)? { nil }
#endif
}
#endif
