import CoreFoundation
import Foundation
import WiltedDomain

extension PodcastPreparationPipeline {
    /// Reply from the worker's transcript-only labelled stage.
    struct TranscriptStagePayload: Sendable {
        var durationSeconds: Double
        var labellerCuesPath: String
        var labellerCuesDigest: String
    }

    /// One proposed break the cut stage left audible.
    struct LabelledLeftInBreak: Equatable, Sendable {
        var startSeconds: Double?
        var endSeconds: Double?
        var kind: String?
        var label: String?
        var reason: String
    }

    private static let labelledLeftInReasons: Set<String> = [
        "acceptable-cut", "house-promotion-disabled", "out-of-range", "malformed",
    ]

    static func decodeTranscriptStage(_ data: Data) throws -> TranscriptStagePayload {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PodcastPreparationError.malformedWorkerResponse("result was not a JSON object")
        }
        if object["ok"] as? Bool != true {
            throw PodcastPreparationError.workerFailed(
                code: object["code"] as? String ?? "unknown",
                message: object["message"] as? String ?? "no message")
        }
        guard object["protocolVersion"] as? Int == 2 else {
            throw PodcastPreparationError.malformedWorkerResponse("unsupported protocolVersion")
        }
        guard object["adStage"] as? String == "transcript",
              object["timing"] as? String == "aligned",
              let duration = labelledNonnegativeDouble(object["durationSeconds"]), duration > 0,
              let path = object["labellerCuesPath"] as? String, !path.isEmpty,
              let digest = object["labellerCuesDigest"] as? String,
              digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw PodcastPreparationError.malformedWorkerResponse("missing or invalid transcript-stage result")
        }
        return TranscriptStagePayload(
            durationSeconds: duration, labellerCuesPath: path, labellerCuesDigest: digest)
    }

    /// Validates a labelled-path audit in place of the local classifier's model and candidate checks.
    static func isLabelledAudit(_ audit: [String: Any], outcome: String) -> Bool {
        guard audit["adEngine"] as? String == "labelled",
              let proposed = labelledNonnegativeInteger(audit["breaksProposed"]),
              let cut = labelledNonnegativeInteger(audit["breaksCut"]),
              let leftInCount = labelledNonnegativeInteger(audit["breaksLeftIn"]),
              let leftIn = audit["leftIn"] as? [[String: Any]],
              leftIn.count == leftInCount,
              let held = audit["heldSpans"] as? [[String: Any]],
              audit["labellerModelID"] is String,
              audit["labellerLevel"] is String,
              audit["labellerPromptVersion"] is String else { return false }
        if cut != 0, cut + leftInCount != proposed { return false }
        guard leftIn.allSatisfy(isWellFormedLeftIn) else { return false }
        guard held.allSatisfy({ span in
            guard let reason = span["reason"] as? String, isKnownHeldReason(reason),
                  let start = labelledNonnegativeDouble(span["startSeconds"]),
                  let end = labelledNonnegativeDouble(span["endSeconds"]),
                  end > start else { return false }
            return true
        }) else { return false }
        if outcome == "uncertain" {
            guard let incomplete = audit["incompleteError"] as? String,
                  !incomplete.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let warning = audit["warning"] as? String,
                  warning.hasPrefix("original audio includes ads:"),
                  warning == "original audio includes ads: \(incomplete)",
                  cut == 0 else { return false }
        } else {
            guard audit["incompleteError"] == nil || audit["incompleteError"] is NSNull,
                  audit["warning"] == nil || audit["warning"] is NSNull else { return false }
        }
        return true
    }

    static func decodeLabelledLeftIn(_ audit: [String: Any]?) -> [LabelledLeftInBreak] {
        guard let leftIn = audit?["leftIn"] as? [[String: Any]] else { return [] }
        return leftIn.compactMap { raw in
            guard let reason = raw["reason"] as? String, labelledLeftInReasons.contains(reason) else { return nil }
            return LabelledLeftInBreak(
                startSeconds: labelledNonnegativeDouble(raw["startSeconds"]),
                endSeconds: labelledNonnegativeDouble(raw["endSeconds"]),
                kind: raw["kind"] as? String,
                label: raw["label"] as? String,
                reason: reason)
        }
    }

    private static func isWellFormedLeftIn(_ raw: [String: Any]) -> Bool {
        guard let reason = raw["reason"] as? String, labelledLeftInReasons.contains(reason),
              raw["advertisers"] is [Any] else { return false }
        let start = raw["startSeconds"]
        let end = raw["endSeconds"]
        if start == nil && end == nil { return true }
        guard let startValue = labelledNonnegativeDouble(start),
              let endValue = labelledNonnegativeDouble(end),
              endValue > startValue else { return false }
        return true
    }

    static func labelledNonnegativeDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0 else { return nil }
        return double
    }

    static func labelledNonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = value as? Int, integer >= 0 else { return nil }
        return integer
    }
}
