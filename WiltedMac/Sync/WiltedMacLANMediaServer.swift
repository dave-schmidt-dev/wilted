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
    private var desiredPeersByDeviceID: [String: LANTLSPeer] = [:]
    private var peersByDeviceID: [String: LANTLSPeer] = [:]
    private var peerRefreshGeneration: UInt64 = 0
    private var listenerUpdateTask: Task<Void, Never>?
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
            peerRefreshGeneration &+= 1
            await stopListener()
            desiredPeersByDeviceID.removeAll()
            peersByDeviceID.removeAll()
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
        peerRefreshGeneration &+= 1
        await stopListener()
        desiredPeersByDeviceID.removeAll()
        peersByDeviceID.removeAll()
        endServingActivity()
    }

    /// Drops direct download capabilities for one device ("Stop direct downloads for this iPhone").
    public func stopDirectDownloads(for deviceID: String) async {
        stoppedPhones.insert(deviceID)
        preferences.insertStoppedPhone(deviceID)
        await links.stopDirectDownloads(for: deviceID)
        try? await refreshPeers()
    }

    /// Keeps a removed device stopped and revokes its listener key after DeviceLinks has removed
    /// its cached link. An unrelated listener update is avoided when it was never an allowed peer.
    public func removeDevice(_ deviceID: String) async {
        stoppedPhones.insert(deviceID)
        preferences.insertStoppedPhone(deviceID)
        let hadDesiredPeer = desiredPeersByDeviceID.removeValue(forKey: deviceID) != nil
        let hadAppliedPeer = peersByDeviceID.removeValue(forKey: deviceID) != nil
        let hadPeer = hadDesiredPeer || hadAppliedPeer
        if let directory = cachedDirectory {
            cachedDirectory = LibraryDeviceDirectory(
                devices: directory.devices.filter { $0.deviceID != deviceID })
        }
        guard hadPeer else { return }

        peerRefreshGeneration &+= 1
        let generation = peerRefreshGeneration
        let peers = isStarted && isDirectDownloadsEnabled && accountGate.isOpen
            ? desiredPeersByDeviceID
            : [:]
        do {
            _ = try await updateListenerPeers(Array(peers.values))
            guard generation == peerRefreshGeneration else { return }
            desiredPeersByDeviceID = peers
            peersByDeviceID = peers
        } catch {
            guard generation == peerRefreshGeneration else { return }
            await stopListener()
            desiredPeersByDeviceID.removeAll()
            peersByDeviceID.removeAll()
            endServingActivity()
        }
    }

    /// Whether any LAN transfer is active. The TLS transport does not expose a device identity,
    /// so this is an aggregate signal for removal confirmation copy.
    public nonisolated var hasActiveTransfers: Bool { server.activeTransferCount > 0 }

    /// Rotates this install's LAN key agreement key on account change; the caller republishes links.
    private func rotateKey() throws {
        ownKey = try keyStore.rotate()
        let removedDevices = Set(preferences.deviceRemovalDates.keys)
        stoppedPhones = removedDevices
        preferences.replaceStoppedPhonesKeepingRemovalTombstones([])
        lanLog.notice("Rotated the LAN key for a new library owner")
    }

    /// Refreshes allowed peers from the device directory and updates the listener.
    public func updateDirectory(_ directory: LibraryDeviceDirectory?) async throws {
        let removedIDs = preferences.deviceRemovalDates.keys
        cachedDirectory = directory.map {
            LibraryDeviceDirectory(devices: $0.devices.filter { !removedIDs.contains($0.deviceID) })
        }
        try await refreshPeers()
    }

    /// The port currently listening, if any.
    public var listeningPort: UInt16? {
        server.port
    }

    // MARK: - Internal peer derivation

    private func refreshPeers() async throws {
        guard isDirectDownloadsEnabled, isStarted else { return }
        peerRefreshGeneration &+= 1
        let generation = peerRefreshGeneration
        guard accountGate.isOpen else {
            _ = try await updateListenerPeers([])
            guard generation == peerRefreshGeneration else { return }
            desiredPeersByDeviceID.removeAll()
            peersByDeviceID.removeAll()
            return
        }
        let owner = await ownerTokenProvider()
        guard generation == peerRefreshGeneration else { return }
        guard let ownerToken = owner, !ownerToken.isEmpty else {
            _ = try await updateListenerPeers([])
            guard generation == peerRefreshGeneration else { return }
            desiredPeersByDeviceID.removeAll()
            peersByDeviceID.removeAll()
            return
        }
        guard let directory = cachedDirectory else {
            _ = try await updateListenerPeers([])
            guard generation == peerRefreshGeneration else { return }
            desiredPeersByDeviceID.removeAll()
            peersByDeviceID.removeAll()
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
        guard generation == peerRefreshGeneration else { return }
        let peers = Self.derivePeers(
            directory: directory, macDeviceID: macDeviceID, macKey: currentOwnKey,
            ownerToken: ownerToken, stoppedPhones: stoppedPhones)
        guard generation == peerRefreshGeneration else { return }
        desiredPeersByDeviceID = peers
        _ = try await updateListenerPeers(Array(peers.values))
        guard generation == peerRefreshGeneration else { return }
        peersByDeviceID = peers
    }

    private func updateListenerPeers(_ peers: [LANTLSPeer]) async throws -> (port: UInt16?, restarted: Bool) {
        let previous = listenerUpdateTask
        let server = self.server
        let update = Task {
            await previous?.value
            return try await server.updatePeers(peers)
        }
        listenerUpdateTask = Task { _ = try? await update.value }
        return try await update.value
    }

    private func stopListener() async {
        let previous = listenerUpdateTask
        let server = self.server
        let stop = Task {
            await previous?.value
            await server.stop()
        }
        listenerUpdateTask = stop
        await stop.value
    }

    private static func derivePeers(
        directory: LibraryDeviceDirectory, macDeviceID: String?, macKey: LANKeyAgreementKey,
        ownerToken: String, stoppedPhones: Set<String>
    ) -> [String: LANTLSPeer] {
        var peers: [String: LANTLSPeer] = [:]
        for device in directory.devices {
            guard device.deviceID != macDeviceID, !stoppedPhones.contains(device.deviceID),
                  let phonePublicKey = device.lanPublicKey else { continue }
            do {
                let psk = try LANPairingKey.derive(
                    ownKey: macKey, peerPublicKey: phonePublicKey, ownerBindingTag: ownerToken,
                    macDeviceID: macDeviceID ?? "", phoneDeviceID: device.deviceID,
                    macPublicKey: macKey.publicKey, phonePublicKey: phonePublicKey)
                let identity = LANPairingKey.identity(phonePublicKey: phonePublicKey)
                peers[device.deviceID] = LANTLSPeer(identity: identity, psk: psk)
            } catch {
                lanLog.error("Failed to derive peer PSK: \(String(describing: error), privacy: .public)")
            }
        }
        return peers
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
    /// Whether any current LAN audio transfer may be interrupted by removing a device.
    var hasActiveLANTransfer: Bool {
        librarySyncController?.inbound?.lanServer?.hasActiveTransfers == true
    }

    /// Whether direct downloads from this Mac are enabled.
    var isDirectDownloadsEnabled: Bool {
        access(keyPath: \.isDirectDownloadsEnabled)
        return librarySyncController?.inbound?.lanServer?.isDirectDownloadsEnabled
            ?? (preferences.object(forKey: WiltedMacLANMediaServer.directDownloadsEnabledKey) as? Bool ?? true)
    }

    /// Sets whether direct downloads from this Mac are enabled.
    func setDirectDownloadsEnabled(_ enabled: Bool) {
        withMutation(keyPath: \.isDirectDownloadsEnabled) {
            preferences.set(enabled, forKey: WiltedMacLANMediaServer.directDownloadsEnabledKey)
        }
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
