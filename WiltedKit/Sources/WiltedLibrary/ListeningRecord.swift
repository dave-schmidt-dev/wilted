import Foundation
import WiltedDomain

/// Item-scoped completion state, independent of audio revision (W-INV-011).
public struct ListeningRecord: Codable, Sendable, Equatable {
    public let itemID: ItemID
    /// Nil means the item is not completed (for example, marked unplayed).
    public let completedAt: Date?
    public let updatedAt: Date
    public let deviceID: String

    public init(itemID: ItemID, completedAt: Date?, updatedAt: Date, deviceID: String) {
        self.itemID = itemID
        self.completedAt = completedAt
        self.updatedAt = updatedAt
        self.deviceID = deviceID
    }

    /// Last-writer-wins by `updatedAt`; equal timestamps break ties by device ID
    /// so every replica converges. Records for different items never merge.
    public static func merge(_ a: ListeningRecord, _ b: ListeningRecord) throws -> ListeningRecord {
        guard a.itemID == b.itemID else {
            throw DomainError.invalidValue(field: "itemID", reason: "cannot merge records for different items")
        }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
        return a.deviceID >= b.deviceID ? a : b
    }

    public var isCompleted: Bool { completedAt != nil }
}
