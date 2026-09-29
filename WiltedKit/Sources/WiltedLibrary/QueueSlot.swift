import Foundation
import WiltedDomain

/// Larder membership: an entry is queued exactly when a slot for it exists.
public struct QueueSlot: Codable, Sendable, Equatable, Identifiable {
    public let entryID: ItemID
    /// Fractional sort key; ascending order is queue order.
    public let sortKey: Double

    public var id: ItemID { entryID }

    public init(entryID: ItemID, sortKey: Double) throws {
        guard sortKey.isFinite else {
            throw DomainError.invalidValue(field: "sortKey", reason: "must be finite")
        }
        self.entryID = entryID
        self.sortKey = sortKey
    }

    private enum CodingKeys: String, CodingKey { case entryID, sortKey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(entryID: c.decode(ItemID.self, forKey: .entryID), sortKey: c.decode(Double.self, forKey: .sortKey))
    }

    /// Key that sorts strictly between `lower` and `upper`; either bound may be absent.
    ///
    /// Returns nil when the neighbours are out of order or so close that no
    /// distinct double lies between them; the single writer then rebalances.
    public static func sortKey(after lower: Double?, before upper: Double?) -> Double? {
        let key: Double
        switch (lower, upper) {
        case (nil, nil): key = 0
        case let (lower?, nil): key = lower + 1
        case let (nil, upper?): key = upper - 1
        case let (lower?, upper?):
            guard lower < upper else { return nil }
            key = lower + (upper - lower) / 2
        }
        guard key.isFinite else { return nil }
        if let lower, key <= lower { return nil }
        if let upper, key >= upper { return nil }
        return key
    }

    /// Queue order: ascending key, entry ID as a deterministic tie-break.
    public static func ordered(_ slots: [QueueSlot]) -> [QueueSlot] {
        slots.sorted { ($0.sortKey, $0.entryID.rawValue) < ($1.sortKey, $1.entryID.rawValue) }
    }

    /// Evenly spaced replacement keys, for when `sortKey(after:before:)` runs out of room.
    public static func rebalanced(_ slots: [QueueSlot]) -> [QueueSlot] {
        ordered(slots).enumerated().map { QueueSlot(unchecked: $0.element.entryID, sortKey: Double($0.offset)) }
    }

    private init(unchecked entryID: ItemID, sortKey: Double) {
        self.entryID = entryID
        self.sortKey = sortKey
    }
}
