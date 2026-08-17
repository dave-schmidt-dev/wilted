import Foundation
import WiltedSync

public enum ListenerError: Error, Equatable, Sendable {
    case stateCorrupt
    case staleStage
    case cacheUnavailable(String)
    case cacheHashMismatch(String)
    case cacheCopyFailed(String)
    case metadataCorrupt
    case operationInProgress
    case cancelled
    case playbackUnavailable(String)
}

extension ListenerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .stateCorrupt: "Listener repository state is corrupt"
        case .staleStage: "The staged sync batch is stale"
        case .cacheUnavailable(let id): "Audio asset is unavailable: \(id)"
        case .cacheHashMismatch(let id): "Audio asset hash mismatch: \(id)"
        case .cacheCopyFailed(let message): "Audio asset copy failed: \(message)"
        case .metadataCorrupt: "Optional listener metadata is corrupt"
        case .operationInProgress: "A listener operation is already in progress"
        case .cancelled: "Listener operation was cancelled"
        case .playbackUnavailable(let message): "Playback is unavailable: \(message)"
        }
    }
}

public struct ListenerMetadata: Codable, Equatable, Sendable {
    public let lastPlayedRecordID: WiltedRecordID?
    public let lastPositionSeconds: Double?

    public init(lastPlayedRecordID: WiltedRecordID? = nil, lastPositionSeconds: Double? = nil) {
        self.lastPlayedRecordID = lastPlayedRecordID
        self.lastPositionSeconds = lastPositionSeconds
    }
}
