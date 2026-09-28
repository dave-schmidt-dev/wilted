import CryptoKit
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
        var timeline: PreparationStatus.PreparationTimeline
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
              ["disabled", "noAds", "cut"].contains(outcome),
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
        } else {
            guard let audit = report["audit"] as? [String: Any],
                  let modelRequests = audit["modelRequests"] as? Int, modelRequests > 0,
                  let modelFailures = audit["modelFailures"] as? Int, modelFailures >= 0,
                  let experimentalRequests = audit["experimentalRequests"] as? Int, experimentalRequests == 0,
                  let unresolvedIdentifiers = audit["unresolvedIds"] as? [Int], unresolvedIdentifiers.isEmpty,
                  !(audit["incompleteError"] is String) else {
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
        for raw in object["cues"] as? [[String: Any]] ?? [] {
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
            ) else { continue }
            cues.append(cue)
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
        let timelineMatchesMap = timelineMatchesKeepMap(removed: removed, kept: kept)
        guard timelineMatchesMap,
              (outcome == "disabled" && !changed && removed.isEmpty && kept.isEmpty)
                || (outcome == "noAds" && !changed && removed.isEmpty && kept.isEmpty)
                || (outcome == "cut" && changed && !removed.isEmpty && !kept.isEmpty) else {
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
            timeline: timeline
        )
    }

    /// A nomination is review material, so it is type-checked rather than
    /// trusted: a malformed one would be shown to a listener as evidence.
    private static func isWellFormedNomination(_ raw: [String: Any]) -> Bool {
        guard let start = raw["startSeconds"] as? Double, let end = raw["endSeconds"] as? Double,
              raw["label"] is String, let confidence = raw["confidence"] as? Double else { return false }
        return start.isFinite && end.isFinite && confidence.isFinite && start >= 0 && end > start
    }

    private static func timelineMatchesKeepMap(
        removed: [PreparationStatus.PreparationTimeline.RemovedInterval],
        kept: [PreparationStatus.PreparationTimeline.KeptInterval]
    ) -> Bool {
        guard !removed.isEmpty || !kept.isEmpty else { return true }
        let orderedKept = kept.sorted { $0.originalStartSeconds < $1.originalStartSeconds }
        let orderedRemoved = removed.sorted { $0.originalStartSeconds < $1.originalStartSeconds }
        var expected: [(Double, Double)] = []
        var cursor = 0.0
        for keep in orderedKept {
            if keep.originalStartSeconds > cursor { expected.append((cursor, keep.originalStartSeconds)) }
            cursor = keep.originalEndSeconds
        }
        let end = max(cursor, orderedRemoved.last?.originalEndSeconds ?? 0)
        if cursor < end { expected.append((cursor, end)) }
        return expected.count == orderedRemoved.count && zip(expected, orderedRemoved).allSatisfy {
            abs($0.0 - $1.originalStartSeconds) <= 0.001 && abs($0.1 - $1.originalEndSeconds) <= 0.001
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
