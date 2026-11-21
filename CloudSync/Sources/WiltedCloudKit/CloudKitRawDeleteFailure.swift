import CloudKit
import Foundation

/// Whether a raw delete already achieved the requested state despite CloudKit's error result.
enum CloudKitRawDeleteFailure {
    static func isIdempotent(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .unknownItem || error.code == .zoneNotFound { return true }
        guard error.code == .partialFailure,
              let failures = error.partialErrorsByItemID,
              !failures.isEmpty else { return false }
        return failures.values.allSatisfy { ($0 as? CKError)?.code == .unknownItem }
    }
}
