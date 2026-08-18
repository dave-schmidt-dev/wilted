import CloudKit
import Foundation
import WiltedSync

/// Failures at the CloudKit boundary. The neutral sync layer never sees CloudKit types.
public enum CloudKitSyncError: Error, Equatable, Sendable {
    case invalidRecordIdentity
    case invalidZone(String)
    case unsupportedRecordType(String)
    case missingField(String)
    case invalidField(String)
    case systemFieldsCorrupt
    case assetUnavailable(String)
    case assetCopyFailed(String)
    case accountChanged
    case quarantined
    case cancelled
    case stateCorrupt
    case operationInProgress
    case serverRecordChanged
    case cloudKit(code: Int, message: String)
}

extension CloudKitSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRecordIdentity: "CloudKit record identity does not match Wilted's contract"
        case let .invalidZone(zone): "Unexpected CloudKit zone: \(zone)"
        case let .unsupportedRecordType(type): "Unsupported CloudKit record type: \(type)"
        case let .missingField(field): "Missing CloudKit field: \(field)"
        case let .invalidField(field): "Invalid CloudKit field: \(field)"
        case .systemFieldsCorrupt: "CloudKit system fields could not be decoded"
        case let .assetUnavailable(id): "CloudKit asset is unavailable: \(id)"
        case let .assetCopyFailed(message): "CloudKit asset copy failed: \(message)"
        case .accountChanged: "The iCloud account changed; local sync state is quarantined"
        case .quarantined: "CloudKit sync is quarantined until the account change is explicitly reset"
        case .cancelled: "CloudKit sync was cancelled"
        case .stateCorrupt: "Persisted CloudKit sync state is corrupt"
        case .operationInProgress: "A CloudKit operation is already in progress"
        case .serverRecordChanged: "CloudKit reported a server record conflict"
        case let .cloudKit(code, message): "CloudKit error \(code): \(message)"
        }
    }
}

extension CloudKitSyncError {
    /// Converts a CloudKit failure without exposing CloudKit to the neutral layer.
    public static func map(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? CKError {
            if error.code == .serverRecordChanged { return .serverRecordChanged }
            return .cloudKit(code: error.code.rawValue, message: error.localizedDescription)
        }
        if let error = error as? WiltedSyncError, error == .missingEngineState {
            return .stateCorrupt
        }
        if (error as NSError).code == NSUserCancelledError { return .cancelled }
        return .cloudKit(code: (error as NSError).code, message: error.localizedDescription)
    }
}

/// A successful send can acknowledge records while returning per-record failures.
public struct CloudKitSendDisposition: Equatable, Sendable {
    public let acknowledged: [WiltedRecordID]
    public let failures: [WiltedRecordID: CloudKitSyncError]

    public init(acknowledged: [WiltedRecordID] = [], failures: [WiltedRecordID: CloudKitSyncError] = [:]) {
        self.acknowledged = acknowledged
        self.failures = failures
    }
}

/// A deliberately data-free signal. Account identifiers never cross the adapter boundary.
public enum CloudKitAccountChangeSignal: Codable, Equatable, Sendable {
    case quarantineRequired(CloudKitAccountChangeType)

    /// Compatibility spelling for callers that do not need the transition type.
    public static var quarantineRequired: Self { .quarantineRequired(.switchAccounts) }

    /// The account transition requiring explicit review.
    public var changeType: CloudKitAccountChangeType {
        switch self {
        case let .quarantineRequired(type): return type
        }
    }
}
