import Foundation
import SwiftUI
import WiltedDomain
import WiltedListener
import WiltedSync

#if WILTED_CLOUDKIT_LIVE
import CloudKit
import WiltedCloudKit
#endif

public enum ListenerAppStatus: Equatable, Sendable {
    case idle
    case refreshing(String)
    case sending(String)
    case ready
    case offline(String)
    case playing
    case paused
    case deleted(String)
    case incompatible(String)
    case failed(String, retryable: Bool)

    public var message: String {
        switch self {
        case .idle: "Ready"
        case let .refreshing(message), let .sending(message), let .offline(message),
             let .deleted(message), let .incompatible(message): message
        case .ready: "Larder ready"
        case .playing: "Playing offline"
        case .paused: "Playback paused"
        case let .failed(message, _): message
        }
    }

    public var isBusy: Bool {
        switch self {
        case .refreshing, .sending: true
        default: false
        }
    }
}

public enum ListenerItemState: Equatable, Sendable {
    case downloaded
    case metadataOnly
    case deleted
    case incompatibleRevision
    case unavailable

    public var label: String {
        switch self {
        case .downloaded: "Downloaded"
        case .metadataOnly: "Metadata available; download required"
        case .deleted: "Deleted remotely"
        case .incompatibleRevision: "Incompatible revision"
        case .unavailable: "Audio unavailable offline"
        }
    }
}

/// The bounded, account-free states used by the shipping listener pixel tests.
/// They describe presentation only and never enable a transport, repository,
/// cache, or audio engine.
public enum ListenerPixelFixtureState: String, Sendable {
    case library
    case nowPlaying
    case emptyNowPlaying
    case terminalFailure
}

public struct ListenerLibraryItem: Identifiable, Equatable, Sendable {
    public let itemID: ItemID
    public let title: String
    public let source: String
    public let revisionID: RevisionID?
    public let durationSeconds: Double?
    public let asset: WiltedAsset?
    public let state: ListenerItemState

    public var id: ItemID { itemID }

    public init(itemID: ItemID, title: String, source: String, revisionID: RevisionID?,
                durationSeconds: Double?, asset: WiltedAsset?, state: ListenerItemState) {
        self.itemID = itemID
        self.title = title
        self.source = source
        self.revisionID = revisionID
        self.durationSeconds = durationSeconds
        self.asset = asset
        self.state = state
    }
}

public typealias ListenerAssetLoader = @Sendable (WiltedRecordID, WiltedAsset) async throws -> URL
public typealias ListenerAudioChunkLoader = @Sendable (ItemID, RevisionID, AudioChunkManifest) async throws -> Data

public enum ListenerAccountChangeType: String, Codable, Sendable {
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

public enum ListenerAccountChange: Sendable {
    case quarantined(ListenerAccountChangeType)
    /// A first sign-in on a device whose local work no account had claimed. Recorded and
    /// carried on, because there is no second account for the listener to review against.
    case ownershipAdopted(token: String)

    /// Compatibility spelling for callers that do not need the transition type.
    public static var quarantined: Self { .quarantined(.switchAccounts) }
}

public protocol ListenerSyncSession: Sendable {
    var transport: any SyncTransport { get }
    var assetLoader: ListenerAssetLoader { get }
    var audioChunkLoader: ListenerAudioChunkLoader { get }
    var accountChanges: AsyncStream<ListenerAccountChange> { get }
    func cancel() async
    func resetAfterAccountChange() async
}

public typealias ListenerSyncSessionFactory = @Sendable (Data?) async throws -> any ListenerSyncSession

enum ListenerDefaultSessionMode: Equatable {
    case localOnly
    case liveCloudKit
}

/// Main-actor presentation model for the iPhone listener.
///
/// The default initializer has no transport and therefore cannot construct or
/// contact CloudKit. A live transport and asset loader are supplied explicitly
/// by the attended live build composition.
