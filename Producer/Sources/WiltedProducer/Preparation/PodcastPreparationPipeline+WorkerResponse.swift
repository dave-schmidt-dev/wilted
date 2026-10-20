import CryptoKit
import CoreFoundation
import Foundation
import WiltedDomain

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
        if outcome == "disabled" {
            guard !(report["audit"] is [String: Any]) else {
                throw PodcastPreparationError.malformedWorkerResponse("disabled ad removal reported detector evidence")
            }
        } else if outcome == "uncertain" {
            guard let audit = report["audit"] as? [String: Any],
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
            guard let audit = report["audit"] as? [String: Any],
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
        guard consistent, timelineMatchesKeepMap(removed: removed, kept: kept, silence: silenceTrims) else {
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
            adAuditDiagnostics: outcome == "uncertain" ? diagnosticFields(report["audit"] as? [String: Any] ?? [:]) : [:],
            timeline: timeline,
            droppedCueCount: droppedCueCount,
            silenceTrims: silenceTrims
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

    private static func diagnosticFields(_ audit: [String: Any]) -> [String: String] {
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
        return fields
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

    /// Every gap in the keep map must be exactly the advertisements and
    /// trimmed pauses inside it. A pause beside an ad shares that ad's gap,
    /// so touching pieces join only when one of them is a pause; two touching
    /// ads stay separate pieces and still fail, as they always have.
    private static func timelineMatchesKeepMap(
        removed: [PreparationStatus.PreparationTimeline.RemovedInterval],
        kept: [PreparationStatus.PreparationTimeline.KeptInterval],
        silence: [Range<Double>] = []
    ) -> Bool {
        guard !removed.isEmpty || !kept.isEmpty else { return true }
        let orderedKept = kept.sorted { $0.originalStartSeconds < $1.originalStartSeconds }
        let pieces = (removed.map { (start: $0.originalStartSeconds, end: $0.originalEndSeconds, pause: false) }
            + silence.map { (start: $0.lowerBound, end: $0.upperBound, pause: true) })
            .sorted { $0.start < $1.start }
        var dropped: [(start: Double, end: Double)] = []
        var previousWasPause = false
        for piece in pieces {
            if let last = dropped.last, abs(piece.start - last.end) <= 0.001, previousWasPause || piece.pause {
                dropped[dropped.count - 1].end = piece.end
            } else {
                dropped.append((piece.start, piece.end))
            }
            previousWasPause = piece.pause
        }
        var expected: [(Double, Double)] = []
        var cursor = 0.0
        for keep in orderedKept {
            if keep.originalStartSeconds > cursor { expected.append((cursor, keep.originalStartSeconds)) }
            cursor = keep.originalEndSeconds
        }
        let end = max(cursor, dropped.last?.end ?? 0)
        if cursor < end { expected.append((cursor, end)) }
        return expected.count == dropped.count && zip(expected, dropped).allSatisfy {
            abs($0.0 - $1.start) <= 0.001 && abs($0.1 - $1.end) <= 0.001
        }
    }

    private static func intervalObjects(named name: String, in object: [String: Any]) throws -> [[String: Any]] {
        guard let value = object[name] else { return [] }
        guard let intervals = value as? [[String: Any]] else {
            throw PodcastPreparationError.malformedWorkerResponse("malformed \(name)")
        }
        return intervals
    }

}
