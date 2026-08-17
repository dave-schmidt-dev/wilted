import Foundation

/// A UTC ISO 8601 timestamp whose encoded representation always ends in `Z`.
public struct Timestamp: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public init(iso8601 value: String) throws {
        guard value.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#,
            options: .regularExpression
        ) != nil else {
            throw DomainError.invalidValue(field: "timestamp", reason: "must be UTC ISO 8601 ending in Z")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let parsed = formatter.date(from: value) else {
            throw DomainError.invalidValue(field: "timestamp", reason: "invalid calendar date")
        }
        date = parsed
    }

    public init(from decoder: Decoder) throws {
        try self.init(iso8601: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = date.timeIntervalSince1970.rounded() == date.timeIntervalSince1970
            ? [.withInternetDateTime]
            : [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool { lhs.date < rhs.date }
}
