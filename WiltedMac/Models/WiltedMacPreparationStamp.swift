import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

/// The Wilted build and ad engine behind one episode's audio, as the info
/// popover states them, so a reader can tell whether a missed advertisement
/// or a failure predates a fix.
///
/// Display order: labelling wait (with the Mac-only phone note), prepared,
/// reason an ad check stopped, earlier ad-finding setting, last failure,
/// failure detail.
///
/// The prepared line names the run that produced the ready revision; the
/// failure line appears only when the newest attempt failed separately from
/// that success, so a retry can never relabel older audio. Waiting lines come
/// only from the current ticket's labelling wait, never from journal rows alone.
struct WiltedMacPreparationStamp: Equatable, Hashable, Sendable {
    /// Labelling-wait sentence with count, when the current ticket is waiting.
    let labellingWait: String?
    /// Mac-only note that the episode is not yet playable on iPhone.
    let phoneNote: String?
    let prepared: String?
    /// When the ready run stopped the labelled path (`ads.label.stop`).
    let stoppedAdCheck: String?
    let passagesLeftIn: [String]
    /// Shown when the ready audio was prepared under an earlier labelled
    /// ad-finding setting than the one now in force.
    let earlierAdFindingSetting: String?
    let lastFailure: String?
    let failureDetail: String?

    /// The popover's lines, or nil when there is nothing to say.
    var displayText: String? {
        let lines = [
            labellingWait, phoneNote, prepared, stoppedAdCheck,
            earlierAdFindingSetting, lastFailure, failureDetail
        ].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    init(
        labellingWait: String? = nil,
        phoneNote: String? = nil,
        prepared: String?,
        stoppedAdCheck: String? = nil,
        passagesLeftIn: [String] = [],
        earlierAdFindingSetting: String? = nil,
        lastFailure: String?,
        failureDetail: String?
    ) {
        self.labellingWait = labellingWait
        self.phoneNote = phoneNote
        self.prepared = prepared
        self.stoppedAdCheck = stoppedAdCheck
        self.passagesLeftIn = passagesLeftIn
        self.earlierAdFindingSetting = earlierAdFindingSetting
        self.lastFailure = lastFailure
        self.failureDetail = failureDetail
    }

#if canImport(WiltedProducer)
    /// Builds the stamp from the snapshot already in hand.
    ///
    /// `outcome` proves the ready revision, and the prepared run is the
    /// successful run whose terminal entry names that same revision -- never
    /// the newest run, because a later failed retry did not produce the audio
    /// currently on the shelf.
    ///
    /// `labelledDigestInForce` is the digest a fresh labelled cut would store
    /// for this episode right now, or nil when it is not sent for labelling. When the newest
    /// finished attempt ran on the current engine and its recorded digest
    /// differs, the earlier-setting line appears.
    ///
    /// `labellingWait` is the current ticket's wait value only; a nil value
    /// (off-peak deferral, non-deferred ticket, or stale journal alone) shows
    /// no waiting lines.
    nonisolated static func make(
        outcome: PodcastPreparationOutcome?,
        readyRevisionID: RevisionID?,
        runs: [PreparationRunSummary],
        labelledDigestInForce: String? = nil,
        labellingWait: LabellingWait? = nil,
        formatTime: (Date) -> String = WiltedMacLabellerWait.defaultFormatTime
    ) -> WiltedMacPreparationStamp? {
        let preparedRun = Self.preparedRun(outcome: outcome, readyRevisionID: readyRevisionID, runs: runs)

        var newestRun: PreparationRunSummary?
        for run in runs {
            if let current = newestRun, !WiltedMacModel.preparationRunIsNewer(run, than: current) { continue }
            newestRun = run
        }

        var waitingSentence: String?
        var phoneNote: String?
        if let labellingWait {
            waitingSentence = WiltedMacLabellerWait.publishedDetail(labellingWait, formatTime: formatTime)
            phoneNote = WiltedMacLabellerWait.phoneNote
        }

        var prepared: String?
        if let outcome, let preparedRun {
            prepared = Self.preparedLine(run: preparedRun, fallbackEngineVersion: outcome.semanticVersion)
        }

        var stoppedAdCheck: String?
        if let preparedRun,
           let stop = preparedRun.entries.last(where: { $0.status.step == "ads.label.stop" }) {
            stoppedAdCheck = "Ad check stopped. " + Self.boundedSingleLine(stop.status.detail)
        }

        var earlierAdFindingSetting: String?
        if let outcome,
           let newestFinished = Self.newestFinishedRun(in: runs),
           Self.engineVersion(of: newestFinished) == PodcastPreparationPipeline.semanticVersion {
            let recorded = Self.policyDigest(of: newestFinished) ?? outcome.policyDigest
            if LabelledPolicyDigestInForce.isStale(
                recordedDigest: recorded, digestInForce: labelledDigestInForce
            ) {
                earlierAdFindingSetting = Self.earlierAdFindingSettingLine
            }
        }

        var lastFailure: String?
        var failureDetail: String?
        if let newestRun, newestRun.outcome == .failed, newestRun != preparedRun {
            lastFailure = Self.failureLine(run: newestRun)
            failureDetail = newestRun.failure.map { Self.boundedSingleLine($0.message) }
        }

        guard waitingSentence != nil || phoneNote != nil || prepared != nil
                || stoppedAdCheck != nil || earlierAdFindingSetting != nil
                || lastFailure != nil || failureDetail != nil else { return nil }
        return WiltedMacPreparationStamp(
            labellingWait: waitingSentence, phoneNote: phoneNote,
            prepared: prepared, stoppedAdCheck: stoppedAdCheck,
            passagesLeftIn: preparedRun.map(Self.passagesKept) ?? [],
            earlierAdFindingSetting: earlierAdFindingSetting,
            lastFailure: lastFailure, failureDetail: failureDetail)
    }

    nonisolated static func preparedRun(
        outcome: PodcastPreparationOutcome?, readyRevisionID: RevisionID?, runs: [PreparationRunSummary]
    ) -> PreparationRunSummary? {
        guard let outcome, let readyRevisionID, outcome.revisionID == readyRevisionID,
              outcome.eligibility != .invalid else { return nil }
        return runs.lazy.filter {
            $0.itemID == outcome.episodeID && $0.producedRevisionID == readyRevisionID
        }.max { WiltedMacModel.preparationRunIsNewer($1, than: $0) }
    }

    /// Times are on the original recording. A rejected passage may have no usable time.
    private static func passagesKept(in run: PreparationRunSummary) -> [String] {
        var passages: [Int: String] = [:]
        for entry in run.entries {
            guard let evidence = entry.status.evidence, evidence.kind == "advertisement-left-in",
                  let ordinal = evidence.fields["ordinal"].flatMap(Int.init), ordinal > 0 else { continue }
            let reason = switch evidence.fields["reason"] {
            case "house-promotion-disabled": "Show promotion removal is off"
            case "acceptable-cut": "Optional cut"
            case "out-of-range": "Timing outside this episode"
            case "malformed": "Unusable break label or timing"
            case "total-share-ceiling": "The cuts would remove too much audio"
            case "cut-unsafe": "The cut could remove part of the show"
            case "programme-boundary", "programme-boundary-conflict", "boundary-review-unresolved",
                 "sponsor-prefix-programme-found", "pod-continuation-bracket": "Ad and show audio overlap or have unclear timing"
            case "credits-boundary-unresolved": "The end of the credits is unclear"
            default: "Reason unavailable"
            }
            var position = "Time unavailable"
            if let start = evidence.fields["startSeconds"].flatMap(Double.init),
               let end = evidence.fields["endSeconds"].flatMap(Double.init),
               start >= 0, end > start, end <= 7 * 24 * 60 * 60 {
                position = "\(WiltedDuration.clock(start))–\(WiltedDuration.clock(end))"
            }
            passages[ordinal] = "\(position) · \(reason)"
        }
        return passages.sorted { $0.key < $1.key }.map(\.value)
    }

    static let earlierAdFindingSettingLine = "Prepared with an earlier ad-finding setting."

    private static func newestFinishedRun(in runs: [PreparationRunSummary]) -> PreparationRunSummary? {
        var newest: PreparationRunSummary?
        for run in runs where run.outcome != .cancelled {
            if let current = newest, !WiltedMacModel.preparationRunIsNewer(run, than: current) { continue }
            newest = run
        }
        return newest
    }

    private static func engineVersion(of run: PreparationRunSummary) -> String? {
        run.entries.lazy.compactMap(\.status.evidence)
            .filter { $0.kind == LocalLibraryStore.pipelineProvenanceEvidenceKind }
            .compactMap { $0.fields["engineVersion"] }.first(where: { !$0.isEmpty })
    }

    private static func policyDigest(of run: PreparationRunSummary) -> String? {
        run.entries.lazy.compactMap(\.status.evidence)
            .filter { $0.kind == LocalLibraryStore.pipelineProvenanceEvidenceKind }
            .compactMap { $0.fields["policyDigest"] }.first
    }

    private static func preparedLine(run: PreparationRunSummary, fallbackEngineVersion: String) -> String {
        if let stamp = run.buildStamp, let appVersion = stamp.appVersion {
            return "Prepared by Wilted \(appVersion) · ad engine "
                + engineLabel(stamp.engineVersion, codeRevision: stamp.codeRevision)
        }
        let engineVersion = run.buildStamp?.engineVersion ?? fallbackEngineVersion
        return "Prepared with ad engine "
            + engineLabel(engineVersion, codeRevision: run.buildStamp?.codeRevision)
            + " · app build not recorded"
    }

    private static func failureLine(run: PreparationRunSummary) -> String {
        if let stamp = run.buildStamp, let appVersion = stamp.appVersion {
            return "Last attempt failed · Wilted \(appVersion) · ad engine "
                + engineLabel(stamp.engineVersion, codeRevision: stamp.codeRevision)
        }
        return "Last attempt failed · build not recorded"
    }

    /// `podcast-preparation-v8` reads as `v8`; a recorded worker checkout
    /// revision rides along as `v8 (d9e8fb14de)`.
    private static func engineLabel(_ engineVersion: String, codeRevision: String?) -> String {
        let name = engineVersion.hasPrefix(engineVersionPrefix)
            ? String(engineVersion.dropFirst(engineVersionPrefix.count))
            : engineVersion
        guard let codeRevision, !codeRevision.isEmpty else { return name }
        return "\(name) (\(codeRevision))"
    }

    /// A failure message reads as one line, bounded so it fits the popover.
    private static func boundedSingleLine(_ message: String) -> String {
        let singleLine = message.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        guard singleLine.count > failureDetailCharacterLimit else { return singleLine }
        return String(singleLine.prefix(failureDetailCharacterLimit - 1)) + "…"
    }

    private static let engineVersionPrefix = "podcast-preparation-"
    private static let failureDetailCharacterLimit = 300
#endif
}
