import CoreFoundation
import Foundation
import WiltedDomain

extension PodcastPreparationPipeline {
    // MARK: - Opening Review Diagnostics

    /// Maximum cue identifiers shown explicitly in the openingReview diagnostic field.
    private static let maximumDiagnosticOpeningReviewIDs = 16

    /// Bounded diagnostic projection of an accepted opening review receipt.
    ///
    /// Validates known summary fields strictly and projects them into a bounded
    /// key-value diagnostic string. Malformed, unsupported, or absent receipts
    /// return `nil` so otherwise valid audio is not failed. Raw text, unknown
    /// fields, and quote collections stay unlogged and unprojected.
    static func openingReviewDiagnosticSummary(_ rawReview: Any?) -> String? {
        guard let review = rawReview as? [String: Any] else { return nil }

        // schemaVersion: 1 (strict integer, unknown version ignored)
        guard let schemaVersion = strictInteger(review["schemaVersion"]),
              schemaVersion == 1 else {
            return nil
        }

        // status: "accepted"
        guard let status = review["status"] as? String,
              status == "accepted" else {
            return nil
        }

        // candidateEndSeconds: finite, 0 < end <= 300
        guard let candidateEnd = strictFiniteDouble(review["candidateEndSeconds"]),
              candidateEnd > 0,
              candidateEnd <= 300 else {
            return nil
        }

        // candidateCueCount: int 1...95
        guard let candidateCueCount = strictInteger(review["candidateCueCount"]),
              (1...95).contains(candidateCueCount) else {
            return nil
        }

        // quoteCount: int 1...95
        guard let quoteCount = strictInteger(review["quoteCount"]),
              (1...95).contains(quoteCount) else {
            return nil
        }

        // coveredCueIDs: sorted unique int array nonempty <= 95 with 0 <= ID < candidateCueCount
        guard let rawIDs = review["coveredCueIDs"] as? [Any],
              !rawIDs.isEmpty,
              rawIDs.count <= 95 else {
            return nil
        }

        var ids: [Int] = []
        ids.reserveCapacity(rawIDs.count)
        for rawID in rawIDs {
            guard let id = strictInteger(rawID),
                  id >= 0,
                  id < candidateCueCount else {
                return nil
            }
            if let last = ids.last {
                guard id > last else {
                    // Strictly ascending: rejects unsorted and duplicates
                    return nil
                }
            }
            ids.append(id)
        }

        // quoteEvidenceDigest: 64 lowercase hex
        guard let digest = strictEvidenceDigest(review["quoteEvidenceDigest"]) else {
            return nil
        }

        // quoteOrigin is optional for receipts emitted before origin tracking.
        let quoteOrigin: String
        if let rawOrigin = review["quoteOrigin"] {
            guard let origin = rawOrigin as? String,
                  ["initial", "literal-repair"].contains(origin) else {
                return nil
            }
            quoteOrigin = origin
        } else {
            quoteOrigin = "unreported"
        }

        let first16 = ids.prefix(maximumDiagnosticOpeningReviewIDs)
        let first16String = first16.map(String.init).joined(separator: ",")
        let omittedCount = max(0, ids.count - first16.count)
        let endString = String(candidateEnd)

        let summary = "end=\(endString);candidateCount=\(candidateCueCount);quoteCount=\(quoteCount);"
            + "quoteOrigin=\(quoteOrigin);coveredIDs=\(first16String);"
            + "omittedIDCount=\(omittedCount);digest=\(digest)"

        guard summary.count <= 256 else { return nil }
        return summary
    }

    /// Assembles audit diagnostics for a worker response, incorporating the
    /// optional openingReview receipt onto cut, noAds, or uncertain outcomes.
    static func auditDiagnostics(
        outcome: String,
        audit: [String: Any]?
    ) -> [String: String] {
        var fields = outcome == "uncertain" ? diagnosticFields(audit ?? [:]) : [:]
        if ["cut", "noAds", "uncertain"].contains(outcome),
           let receipt = openingReviewDiagnosticSummary(audit?["openingReview"]) {
            fields["openingReview"] = receipt
        }
        return fields
    }

    // MARK: - Validation Helpers

    /// Validates that a value is an exact integer value and not a bridged boolean.
    private static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard let integer = value as? Int else { return nil }
        guard number.doubleValue == Double(integer) else { return nil }
        return integer
    }

    /// Validates that a value is a finite double and not a bridged boolean.
    private static func strictFiniteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return double
    }

    /// Validates a 64-character lowercase hexadecimal string.
    private static func strictEvidenceDigest(_ value: Any?) -> String? {
        guard let string = value as? String, string.count == 64 else { return nil }
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39, // '0'...'9'
                 0x61...0x66: // 'a'...'f'
                continue
            default:
                return nil
            }
        }
        return string
    }
}
