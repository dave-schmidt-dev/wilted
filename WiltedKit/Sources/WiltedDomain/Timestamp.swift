import Foundation

/// A thread-safe cache of ISO 8601 formatters and precompiled validation regex.
private final class TimestampFormatters: @unchecked Sendable {
    static let shared = TimestampFormatters()

    private let lock = NSLock()
    private let standardFormatter: ISO8601DateFormatter
    private let fractionalFormatter: ISO8601DateFormatter
    private let validationRegex: NSRegularExpression

    init() {
        let standard = ISO8601DateFormatter()
        standard.timeZone = TimeZone(secondsFromGMT: 0)
        standard.formatOptions = [.withInternetDateTime]

        let fractional = ISO8601DateFormatter()
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        self.standardFormatter = standard
        self.fractionalFormatter = fractional
        self.validationRegex = try! NSRegularExpression(
            pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"#
        )
    }

    func isValidFormat(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return validationRegex.firstMatch(in: value, options: [], range: range) != nil
    }

    func parse(iso8601 value: String) -> Date? {
        lock.withLock {
            if value.contains(".") {
                return fractionalFormatter.date(from: value)
            } else {
                return standardFormatter.date(from: value)
            }
        }
    }

    func format(date: Date) -> String {
        lock.withLock {
            if date.timeIntervalSince1970.rounded() == date.timeIntervalSince1970 {
                return standardFormatter.string(from: date)
            } else {
                return fractionalFormatter.string(from: date)
            }
        }
    }
}

/// A UTC ISO 8601 timestamp whose encoded representation always ends in `Z`.
public struct Timestamp: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public init(iso8601 value: String) throws {
        guard TimestampFormatters.shared.isValidFormat(value) else {
            throw DomainError.invalidValue(field: "timestamp", reason: "must be UTC ISO 8601 ending in Z")
        }
        guard let parsed = TimestampFormatters.shared.parse(iso8601: value) else {
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
        TimestampFormatters.shared.format(date: date)
    }

    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool { lhs.date < rhs.date }

}
