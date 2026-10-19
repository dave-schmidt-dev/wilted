import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

/// The Wilted build and ad engine behind one episode's audio, as the info
/// popover states them, so a reader can tell whether a missed advertisement
/// or a failure predates a fix.
///
/// The prepared line names the run that produced the ready revision; the
/// failure line appears only when the newest attempt failed separately from
/// that success, so a retry can never relabel older audio.
struct WiltedMacPreparationStamp: Equatable, Hashable, Sendable {
    let prepared: String?
    let lastFailure: String?
    let failureDetail: String?

    /// The popover's up-to-three lines, or nil when there is nothing to say.
    var displayText: String? {
        let lines = [prepared, lastFailure, failureDetail].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

#if canImport(WiltedProducer)
    /// Builds the stamp from the snapshot already in hand.
    ///
    /// `outcome` proves the ready revision, and the prepared run is the
    /// successful run whose terminal entry names that same revision -- never
    /// the newest run, because a later failed retry did not produce the audio
    /// currently on the shelf.
    nonisolated static func make(
        outcome: PodcastPreparationOutcome?,
        readyRevisionID: RevisionID?,
        runs: [PreparationRunSummary]
    ) -> WiltedMacPreparationStamp? {
        var preparedRun: PreparationRunSummary?
        if let outcome, let readyRevisionID,
           outcome.revisionID == readyRevisionID,
           outcome.eligibility != .invalid {
            preparedRun = runs.first { run in
                guard run.outcome == .succeeded else { return false }
                return run.entries.contains { $0.status.terminalResult?.revisionID == outcome.revisionID }
            }
        }

        var newestRun: PreparationRunSummary?
        for run in runs {
            if let current = newestRun, !WiltedMacModel.preparationRunIsNewer(run, than: current) { continue }
            newestRun = run
        }

        var prepared: String?
        if let outcome, let preparedRun {
            prepared = Self.preparedLine(run: preparedRun, fallbackEngineVersion: outcome.semanticVersion)
        }

        var lastFailure: String?
        var failureDetail: String?
        if let newestRun, newestRun.outcome == .failed, newestRun != preparedRun {
            lastFailure = Self.failureLine(run: newestRun)
            failureDetail = newestRun.failure.map { Self.boundedSingleLine($0.message) }
        }

        guard prepared != nil || lastFailure != nil || failureDetail != nil else { return nil }
        return WiltedMacPreparationStamp(
            prepared: prepared, lastFailure: lastFailure, failureDetail: failureDetail)
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
