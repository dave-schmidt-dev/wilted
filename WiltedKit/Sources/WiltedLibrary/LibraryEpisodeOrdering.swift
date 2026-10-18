import Foundation

/// Shared factual ordering for episode lists. The key deliberately contains
/// only facts that every list can carry without consulting another lifecycle
/// record or substituting an intake timestamp for publication.
public enum LibraryEpisodeOrdering {
    public enum Sort: String, CaseIterable, Sendable {
        case length
        case age
        case alphabetical
        case custom
    }

    public enum Direction: String, CaseIterable, Sendable {
        case ascending
        case descending
    }

    public struct Key: Equatable, Sendable {
        public let id: String
        public let title: String
        public let durationSeconds: TimeInterval?
        public let publishedAt: Date?

        public init(id: String, title: String, durationSeconds: TimeInterval?, publishedAt: Date?) {
            self.id = id
            self.title = title
            self.durationSeconds = durationSeconds
            self.publishedAt = publishedAt
        }
    }

    /// Whether `lhs` precedes `rhs` in a calculated order. Unknown length and
    /// publication facts always follow known values, regardless of direction.
    /// The ID tie-break is stable and remains ascending in either direction.
    public static func precedes(
        _ lhs: Key,
        _ rhs: Key,
        sort: Sort,
        direction: Direction
    ) -> Bool {
        let ascending = direction == .ascending
        switch sort {
        case .custom:
            return false
        case .length:
            if let result = compareKnown(
                normalizedDuration(lhs.durationSeconds), normalizedDuration(rhs.durationSeconds),
                ascending: ascending
            ) { return result }
        case .age:
            if let result = compareKnown(lhs.publishedAt, rhs.publishedAt, ascending: !ascending) {
                return result
            }
        case .alphabetical:
            let left = LibrarySortKey.title(lhs.title)
            let right = LibrarySortKey.title(rhs.title)
            let comparison = left.localizedStandardCompare(right)
            if comparison != .orderedSame {
                return comparison == (ascending ? .orderedAscending : .orderedDescending)
            }
        }
        return lhs.id < rhs.id
    }

    /// Sorts keys while retaining the caller's order for Custom.
    public static func ordered(
        _ keys: [Key],
        sort: Sort,
        direction: Direction
    ) -> [Key] {
        guard sort != .custom else { return keys }
        return keys.sorted { precedes($0, $1, sort: sort, direction: direction) }
    }

    private static func normalizedDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Returns an ordering result when both values are known or exactly one
    /// is known. `nil` means both are unknown and the caller should use ID.
    private static func compareKnown<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?,
        ascending: Bool
    ) -> Bool? {
        switch (lhs, rhs) {
        case let (left?, right?) where left != right:
            return ascending ? left < right : left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return nil
        }
    }
}
