import Foundation
import WiltedDomain

/// Playback position written by exactly one device (single writer per record).
public struct DevicePlaybackPosition: Codable, Sendable, Equatable {
    public let deviceID: String
    public let entryID: ItemID
    public let revision: RevisionID
    public let positionSeconds: Double
    /// Playback rate; 1 is normal speed.
    public let rate: Double
    public let isPlaying: Bool
    /// Handoff epoch; a takeover sets it to the maximum seen plus one.
    public let epoch: Int
    /// The publishing device's own clock when it wrote the record. Absent on records from
    /// older builds. A reader compares it with the server modification date to derive that
    /// device's clock offset.
    public let publishedAt: Date?

    public init(
        deviceID: String,
        entryID: ItemID,
        revision: RevisionID,
        positionSeconds: Double,
        rate: Double = 1,
        isPlaying: Bool,
        epoch: Int,
        publishedAt: Date? = nil
    ) throws {
        guard !deviceID.isEmpty else { throw DomainError.invalidValue(field: "deviceID", reason: "must not be empty") }
        guard positionSeconds.isFinite, positionSeconds >= 0 else {
            throw DomainError.invalidValue(field: "positionSeconds", reason: "must be finite and non-negative")
        }
        guard rate.isFinite, rate > 0 else {
            throw DomainError.invalidValue(field: "rate", reason: "must be finite and positive")
        }
        guard epoch >= 0 else { throw DomainError.invalidValue(field: "epoch", reason: "must be non-negative") }
        self.deviceID = deviceID
        self.entryID = entryID
        self.revision = revision
        self.positionSeconds = positionSeconds
        self.rate = rate
        self.isPlaying = isPlaying
        self.epoch = epoch
        self.publishedAt = publishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, entryID, revision, positionSeconds, rate, isPlaying, epoch, publishedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            deviceID: c.decode(String.self, forKey: .deviceID),
            entryID: c.decode(ItemID.self, forKey: .entryID),
            revision: c.decode(RevisionID.self, forKey: .revision),
            positionSeconds: c.decode(Double.self, forKey: .positionSeconds),
            rate: c.decode(Double.self, forKey: .rate),
            isPlaying: c.decode(Bool.self, forKey: .isPlaying),
            epoch: c.decode(Int.self, forKey: .epoch),
            publishedAt: c.decodeIfPresent(Date.self, forKey: .publishedAt)
        )
    }
}

/// The one record per device describing what it is playing now.
public typealias NowPlayingRecord = DevicePlaybackPosition

/// Per-entry, per-device position record.
public typealias ProgressRecord = DevicePlaybackPosition

/// A record together with the server modification date the transport observed.
public struct ObservedPlayback: Sendable, Equatable {
    public let record: DevicePlaybackPosition
    public let serverModifiedAt: Date

    public init(record: DevicePlaybackPosition, serverModifiedAt: Date) {
        self.record = record
        self.serverModifiedAt = serverModifiedAt
    }
}
