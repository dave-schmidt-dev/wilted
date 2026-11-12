import Foundation
import WiltedProducer

extension WiltedMacModel {
    /// Labels already-prepared episodes from transcripts still stored on this
    /// Mac. Returns nil when the store or shadow recorder is unavailable, so
    /// tests and fixtures never reach the provider.
    func runAdLabellerBackfill(
        onProgress: @escaping @Sendable (LabellerBackfill.Progress) -> Void
    ) async -> LabellerBackfill.Summary? {
        guard let store, let recorder = adLabellerShadowRecorder else { return nil }
        let backfill = LabellerBackfill(
            store: store,
            recorder: recorder,
            runner: podcastPipelineRunnerFactory?() ?? SubprocessPodcastPipelineRunner(),
            workDirectory: mediaDirectory.appendingPathComponent("preparation", isDirectory: true)
        )
        return await backfill.run(onProgress: onProgress)
    }
}
