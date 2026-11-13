import CryptoKit
import CoreFoundation
import Foundation
import WiltedDomain

private let maximumDiagnosticCandidateRecords = 8
private let maximumDiagnosticSeedIDs = 16
private let maximumDiagnosticFieldCharacters = 256

extension PodcastPreparationPipeline {
    // MARK: Worker response

    struct WorkerPayload: Sendable {
        var timing: TranscriptTiming
        var cues: [TranscriptCue]
        var text: String?
        var languageCode: String?
        var audioPath: String
        var audioChanged: Bool
        var durationSeconds: Double?
        var adSegments: [PodcastAdSegment]
        var removedSeconds: Double
        var keepIntervals: [PodcastKeepInterval]
        var adRemovalOutcome: String
        var warning: String? = nil
        var adAuditDiagnostics: [String: String] = [:]
        var timeline: PreparationStatus.PreparationTimeline
        var droppedCueCount: Int = 0
        /// Long pauses the worker shortened, on the original clock. They are
        /// never advertisements, so they stay out of `adSegments`,
        /// `removedSeconds` and the timeline's removed list. A worker that
        /// predates silence trimming sends none.
        var silenceTrims: [Range<Double>] = []
        var adProfileObservation: PodcastAdProfileObservation? = nil
        var adProfileStatus: String = "absent"
        var adProfileRequestedDigest: String? = nil
        var adProfileAppliedDigest: String? = nil
        /// The canonical aligned cue list the worker exported for the
        /// labelling model, when the request asked for one. Absent otherwise.
        var labellerCuesPath: String? = nil
        var labellerCuesDigest: String? = nil
        /// Breaks the labelled cut stage left audible. Empty on the local path.
        var labelledLeftIn: [LabelledLeftInBreak] = []
    }

    static func decode(_ data: Data) throws -> WorkerPayload {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PodcastPreparationError.malformedWorkerResponse("result was not a JSON object")
        }
        if object["ok"] as? Bool != true {
            throw PodcastPreparationError.workerFailed(code: object["code"] as? String ?? "unknown",
                                                       message: object["message"] as? String ?? "no message")
        }
        guard object["protocolVersion"] as? Int == 2 else {
            throw PodcastPreparationError.malformedWorkerResponse("unsupported protocolVersion")
        }
        guard let report = object["report"] as? [String: Any],
              let outcome = report["outcome"] as? String,
              ["disabled", "noAds", "cut", "uncertain"].contains(outcome),
              let nominations = report["rawNominations"] as? [[String: Any]],
              nominations.allSatisfy(isWellFormedNomination) else {
            throw PodcastPreparationError.malformedWorkerResponse("missing or invalid ad-removal report")
        }
        // A detector that examined every window and found nothing, and one
        // that never reached the model at all, both report `noAds`. Only the
        // audit separates them, so an outcome that claims the detector ran is
        // refused unless the evidence for that claim arrives with it.
        let auditObject = report["audit"] as? [String: Any]
        let isLabelled = auditObject?["adEngine"] as? String == "labelled"
        if outcome == "disabled" {
            guard !(report["audit"] is [String: Any]) else {
                throw PodcastPreparationError.malformedWorkerResponse("disabled ad removal reported detector evidence")
            }
        } else if isLabelled {
            guard let auditObject, isLabelledAudit(auditObject, outcome: outcome) else {
                throw PodcastPreparationError.malformedWorkerResponse("missing or invalid labelled ad-removal audit")
            }
            if outcome == "uncertain" {
                guard let warning = report["warning"] as? String,
                      warning.hasPrefix("original audio includes ads:"),
                      !warning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      warning == auditObject["warning"] as? String,
                      let changed = object["audioChanged"] as? NSNumber,
                      CFGetTypeID(changed) == CFBooleanGetTypeID(), !changed.boolValue,
                      let removed = object["removedSeconds"] as? NSNumber,
                      CFGetTypeID(removed) != CFBooleanGetTypeID(), removed.doubleValue == 0,
                      let ads = object["adSegments"] as? [[String: Any]], ads.isEmpty,
                      let keeps = object["keepIntervals"] as? [[String: Any]], keeps.isEmpty,
                      let duration = object["durationSeconds"] as? NSNumber,
                      CFGetTypeID(duration) != CFBooleanGetTypeID(),
                      duration.doubleValue.isFinite, duration.doubleValue > 0 else {
                    throw PodcastPreparationError.malformedWorkerResponse("invalid uncertain ad-removal evidence")
                }
            }
        } else if outcome == "uncertain" {
            guard let audit = auditObject,
                  isDiagnosticAudit(audit),
                  let warning = report["warning"] as? String,
                  warning.hasPrefix("original audio includes ads:"),
                  !warning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  warning == audit["warning"] as? String,
                  let changed = object["audioChanged"] as? NSNumber,
                  CFGetTypeID(changed) == CFBooleanGetTypeID(), !changed.boolValue,
                  let removed = object["removedSeconds"] as? NSNumber,
                  CFGetTypeID(removed) != CFBooleanGetTypeID(), removed.doubleValue == 0,
                  let ads = object["adSegments"] as? [[String: Any]], ads.isEmpty,
                  let keeps = object["keepIntervals"] as? [[String: Any]], keeps.isEmpty,
                  let duration = object["durationSeconds"] as? NSNumber,
                  CFGetTypeID(duration) != CFBooleanGetTypeID(),
                  duration.doubleValue.isFinite, duration.doubleValue > 0 else {
                throw PodcastPreparationError.malformedWorkerResponse("invalid uncertain ad-removal evidence")
            }
        } else {
            guard let audit = auditObject,
                  let modelRequests = audit["modelRequests"] as? Int, modelRequests > 0,
                  let modelFailures = audit["modelFailures"] as? Int, modelFailures >= 0,
                  let experimentalRequests = audit["experimentalRequests"] as? Int, experimentalRequests == 0,
                  let unresolvedIdentifiers = audit["unresolvedIds"] as? [Int], unresolvedIdentifiers.isEmpty,
                  audit["incompleteError"] == nil || audit["incompleteError"] is NSNull,
                  audit["warning"] == nil || audit["warning"] is NSNull else {
                throw PodcastPreparationError.malformedWorkerResponse("missing or unresolved ad-removal audit")
            }
        }
        guard let audioPath = object["audioPath"] as? String, !audioPath.isEmpty else {
            throw PodcastPreparationError.malformedWorkerResponse("no audioPath")
        }
        guard let timing = TranscriptTiming(rawValue: object["timing"] as? String ?? "none") else {
            throw PodcastPreparationError.malformedWorkerResponse("unknown timing")
        }
        var cues: [TranscriptCue] = []
        var droppedCueCount = 0
        let rawCues = object["cues"] as? [[String: Any]] ?? []
        for raw in rawCues {
            guard let start = raw["startSeconds"] as? Double, let end = raw["endSeconds"] as? Double,
                  let text = raw["text"] as? String else {
                throw PodcastPreparationError.malformedWorkerResponse("malformed cue")
            }
            // Absent for speech-to-text and for any published transcript whose
            // publisher named nobody, which is most of them.
            let speaker = raw["speaker"] as? String
            guard let cue = try? TranscriptCue(
                startSeconds: start,
                endSeconds: end,
                text: text,
                speaker: speaker
            ) else {
                droppedCueCount += 1
                continue
            }
            cues.append(cue)
        }
        let totalCueCount = rawCues.count
        // A handful of degenerate cues (zero-length, empty text) is normal
        // transcript noise and costs only those lines; more than that means
        // the worker and app disagree about the cue contract and the stored
        // timing would be wrong.
        if droppedCueCount > max(20, totalCueCount / 20) {
            throw PodcastPreparationError.malformedWorkerResponse(
                "\(droppedCueCount) of \(totalCueCount) transcript cues were malformed"
            )
        }
        let rawAds = try intervalObjects(named: "adSegments", in: object)
        // The worker's kind is external input, so an unrecognised one reads as
        // paid rather than throwing: refusing a prepared episode over a
        // display string would discard finished audio work.
        let adKinds = rawAds.map { raw -> String in
            let reported = raw["kind"] as? String ?? ""
            return PodcastAdSegment.recognisedKinds.contains(reported) ? reported : PodcastAdSegment.defaultKind
        }
        let removed = try rawAds.map { raw -> PreparationStatus.PreparationTimeline.RemovedInterval in
            guard let start = raw["startSeconds"] as? Double, let end = raw["endSeconds"] as? Double,
                  let label = raw["label"] as? String, let confidence = raw["confidence"] as? Double else {
                throw PodcastPreparationError.malformedWorkerResponse("malformed advertisement interval")
            }
            do {
                return try PreparationStatus.PreparationTimeline.RemovedInterval(
                    originalStartSeconds: start, originalEndSeconds: end, label: label, confidence: confidence
                )
            } catch {
                throw PodcastPreparationError.malformedWorkerResponse("invalid preparation timeline")
            }
        }
        let rawKeeps = try intervalObjects(named: "keepIntervals", in: object)
        let kept = try rawKeeps.map { raw -> PreparationStatus.PreparationTimeline.KeptInterval in
            guard let start = raw["startSeconds"] as? Double, let end = raw["endSeconds"] as? Double,
                  let output = raw["outputStartSeconds"] as? Double else {
                throw PodcastPreparationError.malformedWorkerResponse("malformed kept interval")
            }
            do {
                return try PreparationStatus.PreparationTimeline.KeptInterval(
                    originalStartSeconds: start, originalEndSeconds: end, outputStartSeconds: output
                )
            } catch {
                throw PodcastPreparationError.malformedWorkerResponse("invalid preparation timeline")
            }
        }
        let timeline: PreparationStatus.PreparationTimeline
        do {
            timeline = try PreparationStatus.PreparationTimeline(removed: removed, kept: kept)
        } catch {
            throw PodcastPreparationError.malformedWorkerResponse("invalid preparation timeline")
        }
        let removedSeconds = object["removedSeconds"] as? Double ?? 0
        guard removedSeconds.isFinite, removedSeconds >= 0 else {
            throw PodcastPreparationError.malformedWorkerResponse("invalid removedSeconds")
        }
        let durationSeconds: Double?
        if let rawDuration = object["durationSeconds"] {
            guard let duration = rawDuration as? Double, duration.isFinite, duration >= 0 else {
                throw PodcastPreparationError.malformedWorkerResponse("invalid durationSeconds")
            }
            durationSeconds = duration > 0 ? duration : nil
        } else {
            durationSeconds = nil
        }
        let changed = object["audioChanged"] as? Bool ?? false
        let silenceTrims = try silenceIntervals(in: object)
        let adProfileResult = decodeAdProfileResult(from: object)
        let consistent: Bool
        switch outcome {
        case "cut":
            consistent = changed && !removed.isEmpty && !kept.isEmpty
        case "noAds" where changed:
            // Only long pauses came out: new audio, and still no advertisement.
            consistent = removed.isEmpty && removedSeconds == 0 && !kept.isEmpty && !silenceTrims.isEmpty
        case "uncertain":
            // W-INV-013: an uncertain result keeps the whole original.
            consistent = !changed && removedSeconds == 0 && removed.isEmpty && kept.isEmpty && silenceTrims.isEmpty
        default:
            consistent = !changed && removed.isEmpty && kept.isEmpty && silenceTrims.isEmpty
        }
        if !consistent {
            logReportConsistencyRejection(.outcomeShape,
                                          removedCount: removed.count,
                                          keptCount: kept.count,
                                          silenceCount: silenceTrims.count)
            throw PodcastPreparationError.malformedWorkerResponse("inconsistent ad-removal report")
        }
        if !timelineMatchesKeepMap(removed: removed, kept: kept, silence: silenceTrims) {
            logReportConsistencyRejection(.keepMap,
                                          removedCount: removed.count,
                                          keptCount: kept.count,
                                          silenceCount: silenceTrims.count)
            throw PodcastPreparationError.malformedWorkerResponse("inconsistent ad-removal report")
        }
        return WorkerPayload(
            timing: cues.isEmpty ? .none : timing,
            cues: cues,
            text: object["text"] as? String,
            languageCode: object["languageCode"] as? String,
            audioPath: audioPath,
            audioChanged: changed,
            durationSeconds: durationSeconds,
            adSegments: removed.enumerated().map { index, interval in
                PodcastAdSegment(startSeconds: interval.originalStartSeconds, endSeconds: interval.originalEndSeconds,
                                 label: interval.label, confidence: interval.confidence,
                                 kind: adKinds.indices.contains(index) ? adKinds[index] : PodcastAdSegment.defaultKind)
            },
            removedSeconds: removedSeconds,
            keepIntervals: kept.map { PodcastKeepInterval(startSeconds: $0.originalStartSeconds, endSeconds: $0.originalEndSeconds,
                                                          outputStartSeconds: $0.outputStartSeconds) },
            adRemovalOutcome: outcome,
            warning: outcome == "uncertain" ? (report["warning"] as? String).map { String($0.prefix(768)) } : nil,
            adAuditDiagnostics: auditDiagnostics(outcome: outcome, audit: report["audit"] as? [String: Any]),
            timeline: timeline,
            droppedCueCount: droppedCueCount,
            silenceTrims: silenceTrims,
            adProfileObservation: adProfileResult.observation,
            adProfileStatus: adProfileResult.status,
            adProfileRequestedDigest: adProfileResult.requestedDigest,
            adProfileAppliedDigest: adProfileResult.appliedDigest,
            labellerCuesPath: object["labellerCuesPath"] as? String,
            labellerCuesDigest: object["labellerCuesDigest"] as? String,
            labelledLeftIn: isLabelled ? decodeLabelledLeftIn(auditObject) : []
        )
    }


    /// Pieces of the original the keep map drops that are not advertisements.
    /// Each lies in a gap between kept intervals, beside at most the ads in
    /// that gap, so their count is bounded by the timeline's own limits.
    private static func silenceIntervals(in object: [String: Any]) throws -> [Range<Double>] {
        let raw = try intervalObjects(named: "silenceTrims", in: object)
        let limit = PreparationStatus.PreparationTimeline.maximumKeptIntervals
            + PreparationStatus.PreparationTimeline.maximumRemovedIntervals + 1
        guard raw.count <= limit else {
            throw PodcastPreparationError.malformedWorkerResponse("too many silence intervals")
        }
        var previousEnd = 0.0
        return try raw.map { interval in
            guard let start = interval["startSeconds"] as? Double, let end = interval["endSeconds"] as? Double,
                  start.isFinite, end.isFinite, start >= previousEnd, end > start else {
                throw PodcastPreparationError.malformedWorkerResponse("malformed silence interval")
            }
            previousEnd = end
            return start..<end
        }
    }

    static func diagnosticFields(_ audit: [String: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for key in ["modelRequests", "modelFailures", "classifierValidRequests", "classifierInvalidRequests"] {
            if let count = audit[key] as? Int { fields[key] = String(count) }
        }
        if let ids = audit["unresolvedIds"] as? [Int] {
            let value = ids.map(String.init).joined(separator: ",")
            fields["unresolvedIds"] = value.count > 256 ? String(value.prefix(253)) + "..." : value
        }
        if let reason = audit["incompleteError"] as? String {
            fields["incompleteError"] = String(reason.prefix(256))
        }
        fields["heldSpans"] = heldSpanDiagnosticSummary(audit)
        fields["declinedCommercialEvidenceSeeds"] = declinedSeedDiagnosticSummary(audit)
        return fields
    }

    /// A bounded, content-free projection of the worker's held spans.
    ///
    /// The reasons are the worker's fixed vocabulary rather than free text, so
    /// an unknown one is a diagnostic omission, not something to publish. A
    /// record is only ever emitted whole: when the character budget cannot
    /// hold another one, the counts say so rather than clipping a number.
    private static func heldSpanDiagnosticSummary(_ audit: [String: Any]) -> String {
        let spans = audit["heldSpans"] as? [[String: Any]] ?? []
        let examined = Array(spans.prefix(maximumDiagnosticCandidateRecords))
        var records: [String] = []
        var invalid = 0
        for span in examined {
            guard let reason = span["reason"] as? String,
                  isKnownHeldReason(reason),
                  let interval = diagnosticInterval(span) else {
                invalid += 1
                continue
            }
            records.append("\(reason)@\(diagnosticNumber(interval.0))-\(diagnosticNumber(interval.1))")
        }
        let countOmitted = spans.count - examined.count
        for shown in stride(from: records.count, through: 0, by: -1) {
            let lengthOmitted = records.count - shown
            let summary = "total=\(spans.count);examined=\(examined.count);omittedByCount=\(countOmitted);"
                + "invalid=\(invalid);omittedByLength=\(lengthOmitted);shown=\(shown);"
                + "spans=[\(records.prefix(shown).joined(separator: "|"))]"
            if summary.count <= maximumDiagnosticFieldCharacters { return summary }
        }
        return "total=\(spans.count);examined=\(examined.count);omittedByCount=\(countOmitted);"
            + "invalid=\(invalid);omittedByLength=\(records.count);shown=0;spans=[]"
    }

    /// The same bounded projection for declined commercial-evidence seeds.
    ///
    /// These are the only audit records that carry cue identifiers. A seed
    /// retains at most sixteen of its own IDs, and both the record and ID
    /// omission counts are explicit so a truncated summary never reads as
    /// complete coverage.
    private static func declinedSeedDiagnosticSummary(_ audit: [String: Any]) -> String {
        let seeds = audit["declinedCommercialEvidenceSeeds"] as? [[String: Any]] ?? []
        let examined = Array(seeds.prefix(maximumDiagnosticCandidateRecords))
        var records: [String] = []
        var retainedIDCounts: [Int] = []
        var extraIDCounts: [Int] = []
        var invalid = 0
        for seed in examined {
            guard let reason = seed["reason"] as? String,
                  isKnownDeclinedReason(reason),
                  let interval = diagnosticInterval(seed),
                  let rawIDs = seed["ids"] as? [Any], !rawIDs.isEmpty else {
                invalid += 1
                continue
            }
            var ids: [Int] = []
            for rawID in rawIDs.prefix(maximumDiagnosticSeedIDs) {
                guard let id = diagnosticNonnegativeInteger(rawID) else {
                    ids.removeAll()
                    break
                }
                ids.append(id)
            }
            guard !ids.isEmpty else {
                invalid += 1
                continue
            }
            records.append("\(reason)@\(diagnosticNumber(interval.0))-\(diagnosticNumber(interval.1))"
                + "#\(ids.map(String.init).joined(separator: ","))")
            retainedIDCounts.append(ids.count)
            extraIDCounts.append(max(0, rawIDs.count - ids.count))
        }
        let countOmitted = seeds.count - examined.count
        let idsCountOmitted = extraIDCounts.reduce(0, +)
        for shown in stride(from: records.count, through: 0, by: -1) {
            let lengthOmitted = records.count - shown
            let idsShown = retainedIDCounts.prefix(shown).reduce(0, +)
            let idsLengthOmitted = retainedIDCounts.dropFirst(shown).reduce(0, +)
            let summary = "total=\(seeds.count);examined=\(examined.count);omittedByCount=\(countOmitted);"
                + "invalid=\(invalid);omittedByLength=\(lengthOmitted);shown=\(shown);"
                + "idsShown=\(idsShown);idsOmittedByCount=\(idsCountOmitted);"
                + "idsOmittedByLength=\(idsLengthOmitted);"
                + "seeds=[\(records.prefix(shown).joined(separator: "|"))]"
            if summary.count <= maximumDiagnosticFieldCharacters { return summary }
        }
        return "total=\(seeds.count);examined=\(examined.count);omittedByCount=\(countOmitted);"
            + "invalid=\(invalid);omittedByLength=\(records.count);shown=0;idsShown=0;"
            + "idsOmittedByCount=\(idsCountOmitted);"
            + "idsOmittedByLength=\(retainedIDCounts.reduce(0, +));seeds=[]"
    }

    private static func isKnownDeclinedReason(_ reason: String) -> Bool {
        ["review-declined", "review-unresolved", "dropped-after-proposal"].contains(reason)
    }

    private static func diagnosticInterval(_ record: [String: Any]) -> (Double, Double)? {
        guard let start = diagnosticNonnegativeDouble(record["startSeconds"]),
              let end = diagnosticNonnegativeDouble(record["endSeconds"]),
              end > start else { return nil }
        return (start, end)
    }

    /// Worker numbers are external input. Booleans bridge to `NSNumber` too,
    /// so they have to be excluded by type rather than trusted as zero or one.
    private static func diagnosticNonnegativeDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0 else { return nil }
        return double
    }

    private static func diagnosticNonnegativeInteger(_ value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard let integer = value as? Int, integer >= 0 else { return nil }
        return integer
    }

    /// `String(Double)` is shortest-round-trip and stays compact for very
    /// large finite values, where a fixed decimal format would blow the field.
    private static func diagnosticNumber(_ value: Double) -> String {
        return value == 0 ? "0.0" : String(value)
    }

    /// Diagnostic evidence may describe no model work, but cannot claim clean coverage.
    private static func isDiagnosticAudit(_ audit: [String: Any]) -> Bool {
        func count(_ key: String) -> Int? {
            guard let number = audit[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = audit[key] as? Int, value >= 0 else { return nil }
            return value
        }
        let countKeys = ["classifierRequests", "classifierValidRequests", "classifierInvalidRequests",
                         "exhaustedSingletonLineages", "modelRequests", "modelFailures", "experimentalRequests"]
        guard countKeys.allSatisfy({ count($0) != nil }), count("experimentalRequests") == 0,
              let ids = audit["unresolvedIds"] as? [Int], ids.allSatisfy({ $0 >= 0 }),
              Set(ids).count == ids.count,
              let reason = audit["incompleteError"] as? String,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let candidates = audit["candidates"] as? [[String: Any]],
              let declined = audit["declinedCommercialEvidenceSeeds"] as? [[String: Any]],
              let held = audit["heldSpans"] as? [[String: Any]] else { return false }
        guard count("classifierValidRequests")! + count("classifierInvalidRequests")! <= count("classifierRequests")! else {
            return false
        }
        guard candidates.allSatisfy({ candidate in
            guard let kind = candidate["kind"] as? String, !kind.isEmpty,
                  candidate["detail"] is String, let ids = candidate["ids"] as? [Int] else { return false }
            return ids.allSatisfy { $0 >= 0 }
        }) else { return false }
        return (declined + held).allSatisfy { span in
            guard let reason = span["reason"] as? String, !reason.isEmpty,
                  let start = span["startSeconds"] as? Double, let end = span["endSeconds"] as? Double else { return false }
            return start.isFinite && end.isFinite && start >= 0 && end > start
        } && declined.allSatisfy { span in
            guard span["status"] as? String == "declined", let ids = span["ids"] as? [Int], !ids.isEmpty else { return false }
            return ids.allSatisfy { $0 >= 0 }
        }
    }

    /// A nomination is review material, so it is type-checked rather than
    /// trusted: a malformed one would be shown to a listener as evidence.
    private static func isWellFormedNomination(_ raw: [String: Any]) -> Bool {
        guard let start = raw["startSeconds"] as? Double, let end = raw["endSeconds"] as? Double,
              raw["label"] is String, let confidence = raw["confidence"] as? Double else { return false }
        return start.isFinite && end.isFinite && confidence.isFinite && start >= 0 && end > start
    }

    private static func intervalObjects(named name: String, in object: [String: Any]) throws -> [[String: Any]] {
        guard let value = object[name] else { return [] }
        guard let intervals = value as? [[String: Any]] else {
            throw PodcastPreparationError.malformedWorkerResponse("malformed \(name)")
        }
        return intervals
    }

}
