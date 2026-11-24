import Foundation
import WiltedDomain

/// Mac-authoritative start offset for new, unplayed episodes from one podcast feed.
public struct LibraryShowStartOffset: Codable, Equatable, Sendable {
    public static let maximumSeconds: Double = 600
    public static let conflictReason = "showStartOffsetConflict"

    public let feedID: ItemID
    public let seconds: Double
    public let revision: Int64

    public init(feedID: ItemID, seconds: Double, revision: Int64) throws {
        guard seconds.isFinite, (0...Self.maximumSeconds).contains(seconds), revision >= 0 else {
            throw LibraryTransportError.transport("show start offset is invalid")
        }
        self.feedID = feedID
        self.seconds = seconds
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case feedID, seconds, revision }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            feedID: values.decode(ItemID.self, forKey: .feedID),
            seconds: values.decode(Double.self, forKey: .seconds),
            revision: values.decode(Int64.self, forKey: .revision)
        )
    }
}

/// Resolves a configured offset only for an episode with no saved playback record.
public enum LibraryShowStartOffsetRules {
    public static func freshStartPosition(
        configuredSeconds: Double,
        playableDurationSeconds: Double?,
        hasSavedPlayback: Bool
    ) -> Double {
        guard !hasSavedPlayback,
              configuredSeconds.isFinite,
              configuredSeconds > 0,
              let playableDurationSeconds,
              playableDurationSeconds.isFinite,
              playableDurationSeconds > configuredSeconds else { return 0 }
        return min(configuredSeconds, LibraryShowStartOffset.maximumSeconds)
    }
}
