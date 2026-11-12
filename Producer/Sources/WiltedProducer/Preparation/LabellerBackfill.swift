import Foundation
import WiltedDomain

/// Labels already-prepared episodes with the online ad labeller in shadow
/// mode, from cue files the worker exports out of its stored aligned
/// transcripts.
///
/// The backfill writes shadow records only. It never touches the preparation
/// journal, revisions, playback state, outcomes, tickets, ad profiles or
/// audio, and it deletes exactly the worker's export directory on the way
/// out.
public struct LabellerBackfill: Sendable {
    /// How far the batch has got.
    public struct Progress: Equatable, Sendable {
        /// Episodes attempted so far.
        public var done: Int
        /// Episodes the batch set out to label.
        public var total: Int
        public var recorded: Int
        public var failed: Int

        public init(done: Int, total: Int, recorded: Int, failed: Int) {
            self.done = done
            self.total = total
            self.recorded = recorded
            self.failed = failed
        }
    }

    /// How the batch ended.
    public enum Ending: Equatable, Sendable {
        /// Every pending episode was attempted.
        case finished
        /// No stored transcript belongs to an unlabelled episode that may be sent.
        case nothingToLabel
        case cancelled
        case dailyCapReached
        /// A ``LabellerFailure`` kind other than unusable-answer.
        case stopped(kind: String)
        /// The switch or shadow flag is off.
        case inactive
        /// The worker export failed.
        case unavailable
    }

    /// What the batch did and what is left.
    public struct Summary: Equatable, Sendable {
        public var recorded: Int
        public var failed: Int
        /// Pending episodes not attempted.
        public var remaining: Int
        public var ending: Ending

        public init(recorded: Int, failed: Int, remaining: Int, ending: Ending) {
            self.recorded = recorded
            self.failed = failed
            self.remaining = remaining
            self.ending = ending
        }
    }

    /// Where the worker always writes its cue exports, under the work
    /// directory, and the only thing the backfill deletes.
    static let exportDirectoryPath = "wilted-pipeline/labeller-backfill"

    private let store: LocalLibraryStore
    private let recorder: LabellerShadowRecorder
    private let runner: any PodcastPipelineRunning
    private let workDirectory: URL

    public init(
        store: LocalLibraryStore,
        recorder: LabellerShadowRecorder,
        runner: any PodcastPipelineRunning,
        workDirectory: URL
    ) {
        self.store = store
        self.recorder = recorder
        self.runner = runner
        self.workDirectory = workDirectory
    }

    /// Runs the whole backfill: one worker call that exports cue files, then
    /// one awaited labelling request per pending episode, in episode-ID order.
    ///
    /// Nothing is sent while shadow is inactive or the day's cap is spent. A
    /// failure that says nothing about the next episode (unusable answer,
    /// missing cues) counts and continues; any other failure stops the batch.
    public func run(onProgress: @escaping @Sendable (Progress) -> Void = { _ in }) async -> Summary {
        guard await recorder.wantsCues else {
            return Summary(recorded: 0, failed: 0, remaining: 0, ending: .inactive)
        }
        guard await recorder.requestsRemaining > 0 else {
            return Summary(recorded: 0, failed: 0, remaining: 0, ending: .dailyCapReached)
        }
        // The worker is called from here on, so every exit below removes
        // exactly its export directory.
        defer { Self.removeExportDirectory(workDirectory) }
        do {
            let exports = try await fetchExports()
            return try await labelPending(exports: exports, onProgress: onProgress)
        } catch {
            // A stop during the export or the matching is a stop, not a
            // failure to read the stored transcripts.
            return Summary(recorded: 0, failed: 0, remaining: 0,
                           ending: Task.isCancelled ? .cancelled : .unavailable)
        }
    }

    // MARK: Steps

    /// One cue export the worker reports: the stored transcript's source hash,
    /// the cue file it wrote, and where that transcript ends.
    private struct CuesExport: Decodable {
        let sourceHash: String
        let cuesPath: String
        let cuesDigest: String
        let cueCount: Int
        let lastCueEnd: Double
    }

    /// The worker's reply to the cue-export operation.
    private struct CuesResponse: Decodable {
        let ok: Bool
        let operation: String?
        let protocolVersion: Int?
        let exports: [CuesExport]?
    }

    /// Why the export step failed. Carries no detail: the worker's message
    /// may quote private transcript text.
    private enum ExportError: Error {
        case exportFailed
    }

    /// Step 2: one worker call that exports cue files for every stored
    /// transcript. Any transport error, `ok == false` or malformed reply
    /// throws; `run` maps all of those to `.unavailable`.
    private func fetchExports() async throws -> [CuesExport] {
        let request = try JSONSerialization.data(withJSONObject: [
            "operation": "labellerCues", "protocolVersion": 2, "workDir": workDirectory.path,
        ])
        let data = try await runner.run(request: request) { _ in }
        let response = try JSONDecoder().decode(CuesResponse.self, from: data)
        guard response.ok, response.operation == "labellerCues", response.protocolVersion == 2,
              let exports = response.exports else {
            throw ExportError.exportFailed
        }
        return exports
    }

    /// Steps 3 and 4: match the exports to stored episodes, then label the
    /// pending ones in episode-ID order. Only store reads throw; `run` maps
    /// that to `.unavailable`.
    private func labelPending(
        exports: [CuesExport], onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> Summary {
        let exportsByHash = Dictionary(exports.map { ($0.sourceHash, $0) },
                                        uniquingKeysWith: { first, _ in first })
        let candidates = try await store.labellerBackfillCandidates(sourceHashes: Set(exportsByHash.keys))
        var pending: [LabellerShadowRecorder.ShadowInput] = []
        for candidate in candidates {
            guard let episode = try await store.podcastEpisode(for: candidate.episodeID),
                  let feed = try await store.podcastFeed(for: episode.feedID),
                  let export = exportsByHash[candidate.sourceHash] else { continue }
            let input = LabellerShadowRecorder.ShadowInput(
                episodeID: candidate.episodeID.rawValue,
                feedID: episode.feedID.rawValue,
                feedURL: feed.canonicalURL,
                feedTitle: feed.title,
                audioURL: episode.enclosureURL,
                // The feed's stated length can be short; the cues and the
                // journal's timeline follow the real audio.
                durationSeconds: max(episode.durationSeconds ?? 0,
                                     candidate.timelineEndSeconds, export.lastCueEnd),
                cuesPath: export.cuesPath,
                cuesDigest: export.cuesDigest,
                engineOutcome: candidate.engineOutcome,
                engineCutSpans: candidate.engineCutSpans,
                source: "backfill",
                engineVersion: candidate.engineVersion)
            if await recorder.hasLabelledRecord(episodeID: candidate.episodeID.rawValue) { continue }
            if await recorder.localReason(for: input) != nil { continue }
            pending.append(input)
        }
        guard !pending.isEmpty else {
            return Summary(recorded: 0, failed: 0, remaining: 0, ending: .nothingToLabel)
        }

        let total = pending.count
        var done = 0
        var recorded = 0
        var failed = 0
        onProgress(Progress(done: 0, total: total, recorded: 0, failed: 0))
        for input in pending {
            if Task.isCancelled {
                return Summary(recorded: recorded, failed: failed,
                               remaining: total - done, ending: .cancelled)
            }
            if await recorder.requestsRemaining == 0 {
                return Summary(recorded: recorded, failed: failed,
                               remaining: total - done, ending: .dailyCapReached)
            }
            let outcome = await recorder.label(input)
            done += 1
            var ending: Ending?
            switch outcome {
            case .recorded:
                recorded += 1
            case .failed(let kind):
                failed += 1
                // An unusable answer or missing cues says nothing about the
                // next episode; anything else does.
                if kind != LabellerFailure.unusableAnswer.kind && kind != LabellerShadowRecorder.cuesUnavailableKind {
                    ending = .stopped(kind: kind)
                }
            case .notRouted(.dailyCapReached):
                ending = .dailyCapReached
            case .notRouted:
                break
            case .inactive:
                ending = .inactive
            case .cancelled:
                ending = .cancelled
            }
            onProgress(Progress(done: done, total: total, recorded: recorded, failed: failed))
            if let ending {
                return Summary(recorded: recorded, failed: failed,
                               remaining: total - done, ending: ending)
            }
        }
        return Summary(recorded: recorded, failed: failed, remaining: 0, ending: .finished)
    }

    /// Removes exactly the worker's export directory and nothing else.
    private static func removeExportDirectory(_ workDirectory: URL) {
        let url = workDirectory.appendingPathComponent(Self.exportDirectoryPath, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }
}
