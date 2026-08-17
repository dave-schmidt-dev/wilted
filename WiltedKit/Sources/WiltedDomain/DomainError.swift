import Foundation

/// A stable validation failure returned at domain boundaries.
public enum DomainError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidURL(String)
    case invalidValue(field: String, reason: String)
}

extension DomainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(value):
            "Invalid identifier: \(value)"
        case let .invalidURL(value):
            "Invalid HTTPS URL: \(value)"
        case let .invalidValue(field, reason):
            "Invalid \(field): \(reason)"
        }
    }
}
