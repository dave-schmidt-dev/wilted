import Foundation
import Network
import OSLog
import WiltedDomain
import WiltedLibrary

private let lanLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacLANMediaServer")

/// Seam for the underlying LAN server so tests can assert behavior without live networking.
public protocol LANMediaServing: Sendable {
    func start(peers: [LANTLSPeer]) async throws -> UInt16?
    func updatePeers(_ peers: [LANTLSPeer]) async throws -> (port: UInt16?, restarted: Bool)
    func cancelAll() async
    func stop() async
    var port: UInt16? { get }
    var activeTransferCount: Int { get }
    var connectionCount: Int { get }
}

extension LANMediaServer: LANMediaServing {}

/// Thread-safe wrapper for UserDefaults for direct download preferences.
final class WiltedMacLANPreferences: @unchecked Sendable {
    static let stoppedPhonesKey = "wilted.mac.directDownloadsStoppedPhones"
    static let ownerFingerprintKey = "wilted.mac.directDownloadsOwnerFingerprint"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isDirectDownloadsEnabled: Bool {
        defaults.object(forKey: WiltedMacLANMediaServer.directDownloadsEnabledKey) as? Bool ?? true
    }

    func setDirectDownloadsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: WiltedMacLANMediaServer.directDownloadsEnabledKey)
    }

    /// Phones whose direct downloads the owner stopped; kept across launches until the key rotates.
    var stoppedPhones: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.stoppedPhonesKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.stoppedPhonesKey) }
    }

    /// A one-way fingerprint of the owner the current key was used for, so an account change rotates it.
    var ownerFingerprint: String? {
        get { defaults.string(forKey: Self.ownerFingerprintKey) }
        set { defaults.set(newValue, forKey: Self.ownerFingerprintKey) }
    }
}

/// Lets the server's source closure, built before the actor exists, report that a transfer began.
private final class WiltedMacLANServeHook: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    func set(_ handler: @escaping @Sendable () -> Void) { lock.withLock { self.handler = handler } }
    func fire() { lock.withLock { handler }?() }
}

/// Coordinates the Mac's LAN media server: manages Bonjour advertising, allowed phone keys derived
/// from the device directory and bound iCloud owner, gate-holding admission checks, ProcessInfo activity,
/// and device link key publishing.
actor WiltedMacLANMediaServer {
    static let directDownloadsEnabledKey = "wilted.mac.directDownloadsEnabled"
    static let serviceType = "_wilted-media._tcp"
    static let serviceName = "Wilted"
    static let serviceTXTVersion = "1"

    private let readySource: any WiltedMacReadyAudioSource
    private let accountGate: WiltedMacLibraryAccountGate
    private let links: WiltedMacDeviceLinks
    private let macDeviceID: String?
    private let ownerTokenProvider: @Sendable () async -> String?
    private let keyStore: any LANKeyStore
    private let preferences: WiltedMacLANPreferences
    private let server: any LANMediaServing

    private var isStarted = false
    private var stoppedPhones: Set<String>
    private var cachedDirectory: LibraryDeviceDirectory?
    private var servingActivity: NSObjectProtocol?
    private var activityMonitorTask: Task<Void, Never>?
    private var ownKey: LANKeyAgreementKey?

    init(
        readySource: any WiltedMacReadyAudioSource,
        accountGate: WiltedMacLibraryAccountGate,
        links: WiltedMacDeviceLinks,
        deviceID: String? = nil,
        ownerTokenProvider: @escaping @Sendable () async -> String?,
        keyStore: (any LANKeyStore)? = nil,
        preferences: WiltedMacLANPreferences = WiltedMacLANPreferences(),
        server: (any LANMediaServing)? = nil,
        binding: LANInterfaceBinding = .any
    ) {
        self.readySource = readySource
        self.accountGate = accountGate
        self.links = links
        self.macDeviceID = deviceID
        self.ownerTokenProvider = ownerTokenProvider
        let store = keyStore ?? KeychainLANKeyStore()
        self.keyStore = store
        self.preferences = preferences
        self.stoppedPhones = preferences.stoppedPhones
        let hook = WiltedMacLANServeHook()

        if let server {
            self.server = server
        } else {
            let config = Self.makeConfiguration(binding: binding)
            self.server = LANMediaServer(
                configuration: config,
                isHeld: { !accountGate.isOpen },
                source: { request in
                    guard accountGate.isOpen else { return .refused }
                    do {
                        guard let audio = try await readySource.readyAudio(for: request.entryID) else {
                            return .notReady
                        }
                        hook.fire()
                        return .ready(LANServedFile(
                            fileURL: audio.fileURL,
                            revisionID: audio.revisionID,
                            contentHash: audio.contentHash,
                            byteCount: audio.byteCount
                        ))
                    } catch {
                        return .notReady
                    }
                }
            )
        }

        hook.set { [weak self] in Task { [weak self] in await self?.noteTransferStarted() } }
        accountGate.addInvalidationHandler { [weak self] in
            Task { [weak self] in
                await self?.handleGateInvalidated()
            }
        }
    }

    /// Whether the Mac direct download switch is on. Defaults to true.
    public nonisolated var isDirectDownloadsEnabled: Bool {
        preferences.isDirectDownloadsEnabled
    }

    /// Toggles the Mac direct download switch and starts or stops the listener accordingly.
    public func setEnabled(_ enabled: Bool) async {
        preferences.setDirectDownloadsEnabled(enabled)
        if enabled {
            try? await refreshPeers()
        } else {
            await server.stop()
            endServingActivity()
        }
    }

    /// Starts the LAN server if direct downloads are enabled.
    public func start() async {
        isStarted = true
        for deviceID in stoppedPhones { await links.stopDirectDownloads(for: deviceID) }
        guard isDirectDownloadsEnabled else { return }
        try? await refreshPeers()
    }

    /// Stops the server during quit drain or disable.
    public func stop() async {
        isStarted = false
        await server.stop()
        endServingActivity()
    }

    /// Drops direct download capabilities for one device ("Stop direct downloads for this iPhone").
    public func stopDirectDownloads(for deviceID: String) async {
        stoppedPhones.insert(deviceID)
        preferences.stoppedPhones = stoppedPhones
        await links.stopDirectDownloads(for: deviceID)
        try? await refreshPeers()
    }

    /// Rotates this install's LAN key agreement key on account change; the caller republishes links.
    private func rotateKey() throws {
        ownKey = try keyStore.rotate()
        stoppedPhones.removeAll()
        preferences.stoppedPhones = []
        lanLog.notice("Rotated the LAN key for a new library owner")
    }

    /// Refreshes allowed peers from the device directory and updates the listener.
    public func updateDirectory(_ directory: LibraryDeviceDirectory?) async throws {
        cachedDirectory = directory
        try await refreshPeers()
    }

    /// The port currently listening, if any.
    public var listeningPort: UInt16? {
        server.port
    }

    // MARK: - Internal peer derivation

    private func refreshPeers() async throws {
        guard isDirectDownloadsEnabled, isStarted else { return }
        guard accountGate.isOpen else {
            _ = try await server.updatePeers([])
            return
        }
        guard let ownerToken = await ownerTokenProvider(), !ownerToken.isEmpty else {
            _ = try await server.updatePeers([])
            return
        }
        guard let directory = cachedDirectory else {
            _ = try await server.updatePeers([])
            return
        }

        // A different owner than the key was last used for is an account change: a new key, and the
        // previous library's stopped phones no longer apply. The first owner ever seen keeps the key.
        let ownerFingerprint = LANPairingKey.fingerprint(of: Data(ownerToken.utf8))
        if let previous = preferences.ownerFingerprint, previous != ownerFingerprint { try rotateKey() }
        if preferences.ownerFingerprint != ownerFingerprint { preferences.ownerFingerprint = ownerFingerprint }

        let currentOwnKey: LANKeyAgreementKey
        if let held = ownKey {
            currentOwnKey = held
        } else {
            let loaded = try keyStore.currentKey()
            ownKey = loaded
            currentOwnKey = loaded
        }
        await links.setMacLANPublicKey(currentOwnKey.publicKey)

        var peers: [LANTLSPeer] = []
        for device in directory.devices {
            guard device.deviceID != macDeviceID else { continue }
            guard !stoppedPhones.contains(device.deviceID) else { continue }
            guard let phonePublicKey = device.lanPublicKey else { continue }
            do {
                let psk = try LANPairingKey.derive(
                    ownKey: currentOwnKey,
                    peerPublicKey: phonePublicKey,
                    ownerBindingTag: ownerToken,
                    macDeviceID: macDeviceID ?? "",
                    phoneDeviceID: device.deviceID,
                    macPublicKey: currentOwnKey.publicKey,
                    phonePublicKey: phonePublicKey
                )
                let identity = LANPairingKey.identity(phonePublicKey: phonePublicKey)
                peers.append(LANTLSPeer(identity: identity, psk: psk))
            } catch {
                lanLog.error("Failed to derive peer PSK: \(String(describing: error), privacy: .public)")
            }
        }
        _ = try await server.updatePeers(peers)
    }

    private func handleGateInvalidated() async {
        await server.cancelAll()
        endServingActivity()
    }

    // MARK: - Activity

    private func noteTransferStarted() {
        guard servingActivity == nil else { return }
        servingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Serving LAN media"
        )
        monitorServingActivity()
    }

    private func monitorServingActivity() {
        activityMonitorTask?.cancel()
        activityMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let active = self.server.activeTransferCount
                if active == 0 {
                    await self.endServingActivity()
                    return
                }
            }
        }
    }

    private func endServingActivity() {
        if let activity = servingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            servingActivity = nil
        }
        activityMonitorTask?.cancel()
        activityMonitorTask = nil
    }

    // MARK: - Configuration

    public static func makeBonjourService() -> NWListener.Service {
        let txt = NetService.data(fromTXTRecord: ["v": Data(serviceTXTVersion.utf8)])
        return NWListener.Service(
            name: serviceName,
            type: serviceType,
            domain: nil,
            txtRecord: txt
        )
    }

    public static func makeConfiguration(
        binding: LANInterfaceBinding = .any,
        service: NWListener.Service? = makeBonjourService()
    ) -> LANMediaServer.Configuration {
        LANMediaServer.Configuration(
            binding: binding,
            deadlines: .standard,
            maximumActiveTransfers: 2,
            maximumConnections: 8,
            chunkBytes: 1 << 20,
            service: service,
            requestedPort: nil
        )
    }
}

#if canImport(AppKit)
extension WiltedMacModel {
    /// Whether direct downloads from this Mac are enabled.
    var isDirectDownloadsEnabled: Bool {
        librarySyncController?.inbound?.lanServer?.isDirectDownloadsEnabled
            ?? (preferences.object(forKey: WiltedMacLANMediaServer.directDownloadsEnabledKey) as? Bool ?? true)
    }

    /// Sets whether direct downloads from this Mac are enabled.
    func setDirectDownloadsEnabled(_ enabled: Bool) {
        preferences.set(enabled, forKey: WiltedMacLANMediaServer.directDownloadsEnabledKey)
        Task { @MainActor in
            await librarySyncController?.inbound?.lanServer?.setEnabled(enabled)
        }
    }

    /// Drops direct download capabilities for one follower device.
    func stopDirectDownloads(for deviceID: String) {
        Task { @MainActor in
            await librarySyncController?.inbound?.stopDirectDownloads(for: deviceID)
        }
    }
}
#endif
