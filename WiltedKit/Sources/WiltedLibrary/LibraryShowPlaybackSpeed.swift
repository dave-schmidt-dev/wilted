import Foundation
import WiltedDomain

/// The Mac-authoritative playback-rate choice for one podcast feed.
/// A nil rate is a revisioned reset to the listener's device default.
public struct LibraryShowPlaybackSpeed: Codable, Equatable, Sendable {
    public let feedID: ItemID
    public let speed: Double?
    public let revision: Int64

    public init(feedID: ItemID, speed: Double?, revision: Int64) throws {
        guard revision >= 0 else {
            throw DomainError.invalidValue(field: "revision", reason: "must be non-negative")
        }
        if let speed, !PlaybackSpeeds.contains(speed) {
            throw DomainError.invalidValue(field: "speed", reason: "must be an offered playback speed")
        }
        self.feedID = feedID
        self.speed = speed
        self.revision = revision
    }
}
