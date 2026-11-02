import Foundation
import Network
import OSLog
import WiltedDomain
import WiltedLibrary

private let directLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryDirectMedia")

/// Why a download did not use the direct path, or stopped using it. Every case is typed so the log and
/// the tests name the cause; none carries a key, an address or an account id (fallback rule 8).
enum LibraryDirectFallback: String, Sendable, Equatable, CaseIterable {
    // Rule 1: the direct path is not attempted and the request goes to iCloud at once.
    case switchOff, localNetworkDenied, noMacKey, noPhoneKey, noOffer, offerNotPrepared, hashlessOffer
    // Rule 1a: the owner is not verified for this launch (D5, W-INV-021), so nothing direct starts.
    case ownerUnverified
    // Rule 2: no Mac answered within the browse and handshake budget.
    case macNotFound, handshakeFailed
    // Rule 3: the Mac answered that it cannot serve this file.
    case macNotReady, macDifferent, macRefused
    // Rule 4: the Mac is busy; one retry after a short wait.
    case macBusy
    // Rule 5: the connection dropped twice. The partial file is kept.
    case connectionDropped
    // Rule 6: the finished file was not the offer's. The partial file is deleted.
    case mismatch
    // Anything else the client reports (storage, a protocol violation): iCloud, and the cause is logged.
    case unexpected

    /// The design's fallback rule number this cause belongs to.
    var rule: String {
        switch self {
        case .switchOff, .localNetworkDenied, .noMacKey, .noPhoneKey, .noOffer, .offerNotPrepared, .hashlessOffer: "1"
        case .ownerUnverified: "1a"
        case .macNotFound, .handshakeFailed: "2"
        case .macNotReady, .macDifferent, .macRefused: "3"
        case .macBusy: "4"
        case .connectionDropped: "5"
        case .mismatch: "6"
        case .unexpected: "-"
        }
    }

    /// The cause a failed fetch is, per rule.
    init(_ error: LANMediaError) {
        switch error {
        case .noEndpoints, .timedOut(.connecting): self = .macNotFound
        case .handshakeFailed, .unexpectedNegotiation: self = .handshakeFailed
        case .notReady: self = .macNotReady
        case .different: self = .macDifferent
        case .refused: self = .macRefused
        case .busy: self = .macBusy
        case .connectionDropped, .timedOut: self = .connectionDropped
        case .mismatch: self = .mismatch
        case .invalidOffer, .partialInUse, .protocolViolation, .storage: self = .unexpected
        }
    }
}

/// What the browse for a Mac found.
enum LocalMacSearch: Sendable, Equatable {
    case found([NWEndpoint])
    /// Nothing answered within the budget.
    case none
    /// The system refused Local Network access. Best effort: the signal is a policy-denied DNS error.
    case denied
}

/// Looks for the Mac on the local network. The live one is `LocalMacLocator`; tests inject their own.
protocol LocalMacLocating: Sendable {
    func locate(within budget: Duration) async -> LocalMacSearch
}

/// Everything a download needs to try the direct path: how to find the Mac, the phone's key, how to build
/// a fetcher, and the scheduler for the background task. Nil on the model means the path is off, which is
/// what every test that does not name it gets.
struct LibraryDirectEnvironment: Sendable {
    /// What a fetcher needs to be built.
    struct Connection: Sendable {
        let endpoints: [NWEndpoint]
        let peer: LANTLSPeer
        let partialDirectory: URL
        let onPhase: @Sendable (LANMediaPhase) -> Void
    }

    var locator: any LocalMacLocating
    var phoneKey: @Sendable () -> LANKeyAgreementKey?
    var makeSource: @Sendable (Connection) -> any DirectMediaSource
    var scheduler: (any LibraryBackgroundTransferScheduling)?
    /// Browse and resolve budget (fallback rule 2).
    var browseBudget: Duration = .seconds(3)
    /// How long a busy Mac is given before the one retry (fallback rule 4).
    var busyRetryDelay: Duration = .seconds(2)

    /// The production wiring: Bonjour browsing and the TLS-PSK client.
    static func live(phoneKey: LibraryPhoneKey, scheduler: (any LibraryBackgroundTransferScheduling)?) -> Self {
        Self(locator: LocalMacLocator(), phoneKey: { phoneKey.key() },
             makeSource: { connection in
                 LANMediaClient(endpoints: connection.endpoints, peer: connection.peer,
                                partialDirectory: connection.partialDirectory, onPhase: connection.onPhase)
             }, scheduler: scheduler)
    }
}

/// This install's LAN key, read from the Keychain once and kept: the key store creates a key on first use,
/// and the announcement and every download ask for it.
final class LibraryPhoneKey: @unchecked Sendable {
    private let store: any LANKeyStore
    private let lock = NSLock()
    private var cached: LANKeyAgreementKey?

    init(store: any LANKeyStore) { self.store = store }

    func key() -> LANKeyAgreementKey? {
        lock.withLock {
            if cached == nil { cached = try? store.currentKey() }
            return cached
        }
    }
}

/// The phone's side of the pairing contract with the Mac (`LANPairingKey.derive`). The Mac derives the
/// same key from these same facts; if either side changes one, the handshake fails and every download
/// falls back to iCloud, so they are named in one place.
///
/// - `ownerBindingTag`: the verified library owner token.
/// - `macDeviceID`: the Mac's device id, `LibraryPublication.writerDeviceID`.
/// - `phoneDeviceID`: this install's library device id.
enum LibraryDirectPairing {
    static func peer(phoneKey: LANKeyAgreementKey, macPublicKey: Data, ownerToken: String,
                     macDeviceID: String, phoneDeviceID: String) -> LANTLSPeer? {
        guard let psk = try? LANPairingKey.derive(
            ownKey: phoneKey, peerPublicKey: macPublicKey, ownerBindingTag: ownerToken,
            macDeviceID: macDeviceID, phoneDeviceID: phoneDeviceID,
            macPublicKey: macPublicKey, phonePublicKey: phoneKey.publicKey) else { return nil }
        return LANTLSPeer(identity: LANPairingKey.identity(phonePublicKey: phoneKey.publicKey), psk: psk)
    }
}

/// What the direct path remembers between launches, stamped with the library owner it was learned under:
/// the Mac's key and device id, and the last set of prepared offers, so a launch without signal can still
/// start a direct download and the person can see why one did not.
struct LibraryDirectSaved: Codable, Equatable, Sendable {
    var version = LibraryDirectStore.version
    var ownerToken: String
    var macKey: Data?
    var macDeviceID: String?
    /// Prepared offers only, by entry, so an unchanged set writes nothing.
    var offers: [LibraryMediaOffer]
}

/// The JSON file beside `media-jobs.json`. It is a cache: a missing, damaged or newer file reads as empty
/// and the next round rewrites it.
struct LibraryDirectStore: Sendable {
    static let version = 1
    let url: URL?

    func load() -> LibraryDirectSaved? {
        guard let url, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(LibraryDirectSaved.self, from: data),
              saved.version == Self.version else { return nil }
        return saved
    }

    func save(_ saved: LibraryDirectSaved) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
        } catch {
            directLog.error("The direct-download cache could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// One fallback, as logged and as the tests read it back.
struct LibraryDirectEvent: Equatable, Sendable {
    let entryID: ItemID
    let cause: LibraryDirectFallback
}

/// The model's direct-path bookkeeping. A class so the model's extension can keep state without stored
/// properties of its own; touched only on the main actor.
@MainActor
final class LibraryDirectState {
    /// Nil leaves the direct path off.
    var environment: LibraryDirectEnvironment?
    var saved: LibraryDirectSaved?
    var loaded = false
    /// Every fallback this session, oldest first.
    private(set) var events: [LibraryDirectEvent] = []
    var transfers: LibraryDirectTransferCoordinator?
    /// Entries whose direct run the system ended while the app was away; they restart on the next foreground.
    var suspended: Set<ItemID> = []
    /// The run that is trying the direct path for each entry.
    var running: [ItemID: UUID] = [:]
    /// Local Network access was refused this session: no more browsing until the app comes to the front again.
    var localNetworkDenied = false

    func record(_ cause: LibraryDirectFallback, entryID: ItemID) {
        events.append(LibraryDirectEvent(entryID: entryID, cause: cause))
        directLog.notice("Direct download not used for \(entryID.rawValue, privacy: .public): rule \(cause.rule, privacy: .public), \(cause.rawValue, privacy: .public)")
    }
}
