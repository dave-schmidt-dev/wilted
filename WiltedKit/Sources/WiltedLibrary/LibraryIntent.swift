import Foundation
import WiltedDomain

/// Append-only request from a follower device to the library's single writer.
///
/// `id` is the idempotency key: the writer applies each id at most once.
public struct LibraryIntent: Codable, Sendable, Equatable, Identifiable {
    public enum Action: Codable, Sendable, Equatable {
        /// Ask the Mac to make audio for `entryID` available to this device.
        case requestMedia(entryID: ItemID)
    }

    public let id: String
    public let deviceID: String
    public let createdAt: Date
    public let action: Action

    public init(id: String, deviceID: String, createdAt: Date, action: Action) throws {
        guard !id.isEmpty else { throw DomainError.invalidValue(field: "id", reason: "must not be empty") }
        guard !deviceID.isEmpty else { throw DomainError.invalidValue(field: "deviceID", reason: "must not be empty") }
        self.id = id
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.action = action
    }

    /// Request for media with a fresh idempotency id.
    public static func requestMedia(
        entryID: ItemID,
        deviceID: String,
        createdAt: Date = Date(),
        id: String = UUID().uuidString
    ) throws -> LibraryIntent {
        try LibraryIntent(id: id, deviceID: deviceID, createdAt: createdAt, action: .requestMedia(entryID: entryID))
    }

    private enum CodingKeys: String, CodingKey { case id, deviceID, createdAt, action }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            deviceID: c.decode(String.self, forKey: .deviceID),
            createdAt: c.decode(Date.self, forKey: .createdAt),
            action: c.decode(Action.self, forKey: .action)
        )
    }
}
