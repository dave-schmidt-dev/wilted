import Foundation
import SwiftData
import WiltedDomain

/// One episode the label-only backfill may label from a stored transcript.
public struct LabellerBackfillCandidate: Equatable, Sendable {
    public let episodeID: ItemID
    public let sourceHash: String
    /// The attempt's worker-result `adRemovalOutcome`, or "unknown".
    public let engineOutcome: String
    public let engineVersion: String?
    /// The attempt's terminal timeline `removed`, in seconds on the original
    /// clock; empty when the journal kept no timeline.
    public let engineCutSpans: [LabellerShadowRecorder.ShadowSpan]
    /// The largest end over the attempt's timeline kept+removed, 0 when none.
    public let timelineEndSeconds: Double

    public init(
        episodeID: ItemID, sourceHash: String, engineOutcome: String,
        engineVersion: String?, engineCutSpans: [LabellerShadowRecorder.ShadowSpan],
        timelineEndSeconds: Double
    ) {
        self.episodeID = episodeID
        self.sourceHash = sourceHash
        self.engineOutcome = engineOutcome
        self.engineVersion = engineVersion
        self.engineCutSpans = engineCutSpans
        self.timelineEndSeconds = timelineEndSeconds
    }
}

extension LocalLibraryStore {
    /// One candidate per episode that is not retired and has a finished
    /// (terminal, not cancelled) preparation attempt whose provenance
    /// `sourceHash` is in `sourceHashes`; sorted by episode ID.
    ///
    /// The attempt chosen per episode is the newest of those whose worker
    /// report names an ad-removal outcome, or the newest of them when none carries it
    /// (then `engineOutcome` is "unknown"). When no attempt matches but one of
    /// the episode's stored revisions has a `contentHash` in the set, that
    /// revision yields a candidate with outcome "unknown" and no spans.
    ///
    /// Read-only: one `ModelContext`, no saves.
    public func labellerBackfillCandidates(sourceHashes: Set<String>) throws -> [LabellerBackfillCandidate] {
        guard !sourceHashes.isEmpty else { return [] }
        let context = ModelContext(container)
        let attemptsByEpisode = try journalAttemptsByEpisode(in: context)
        var revisionsByEpisode: [String: [LocalLibrarySchemaV3Models.RevisionRecord]] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        where sourceHashes.contains(record.contentHash) {
            revisionsByEpisode[record.itemID, default: []].append(record)
        }
        var candidates: [LabellerBackfillCandidate] = []
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        where record.retiredAt == nil {
            guard let itemID = try? ItemID(rawValue: record.id) else { continue }
            if let candidate = Self.backfillCandidate(
                itemID: itemID, attempts: attemptsByEpisode[record.id] ?? [], sourceHashes: sourceHashes
            ) {
                candidates.append(candidate)
                continue
            }
            // No attempt matches; a stored revision whose content hash the
            // worker exported still identifies the audio the transcript
            // came from.
            if let revision = revisionsByEpisode[record.id]?.max(by: { $0.createdAt < $1.createdAt }) {
                candidates.append(LabellerBackfillCandidate(
                    episodeID: itemID, sourceHash: revision.contentHash, engineOutcome: "unknown",
                    engineVersion: nil, engineCutSpans: [], timelineEndSeconds: 0))
            }
        }
        return candidates.sorted { $0.episodeID.rawValue < $1.episodeID.rawValue }
    }

    /// The candidate one episode's journalled attempts yield, or nil when none
    /// of them finished on a source the worker exported. `attempts` are oldest
    /// first, so `last` is the newest.
    private static func backfillCandidate(
        itemID: ItemID, attempts: [JournalAttempt], sourceHashes: Set<String>
    ) -> LabellerBackfillCandidate? {
        let finished: [(attempt: JournalAttempt, sourceHash: String)] = attempts.compactMap { attempt in
            guard let terminal = attempt.terminal,
                  terminal.terminalResult?.outcome != .cancelled,
                  let hash = attempt.sourceHash, sourceHashes.contains(hash) else { return nil }
            return (attempt, hash)
        }
        guard let chosen = finished.last(where: { $0.attempt.adRemovalOutcome != nil }) ?? finished.last else { return nil }
        let timeline = chosen.attempt.terminal?.timeline
        return LabellerBackfillCandidate(
            episodeID: itemID,
            sourceHash: chosen.sourceHash,
            engineOutcome: chosen.attempt.adRemovalOutcome ?? "unknown",
            engineVersion: chosen.attempt.engineVersion,
            engineCutSpans: (timeline?.removed ?? []).map {
                LabellerShadowRecorder.ShadowSpan(start: $0.originalStartSeconds, end: $0.originalEndSeconds)
            },
            timelineEndSeconds: timelineEndSeconds(timeline))
    }

    /// The largest end over the timeline's kept and removed spans, 0 when none.
    private static func timelineEndSeconds(_ timeline: PreparationStatus.PreparationTimeline?) -> Double {
        guard let timeline else { return 0 }
        let ends = timeline.removed.map(\.originalEndSeconds) + timeline.kept.map(\.originalEndSeconds)
        return max(0, ends.max() ?? 0)
    }
}
