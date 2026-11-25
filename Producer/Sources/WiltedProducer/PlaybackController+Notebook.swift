import Foundation
import WiltedDomain

extension PlaybackController {
    /// Loads the exact immutable revision saved by a Notebook clip without
    /// changing the podcast queue or falling forward to a newer revision.
    public func loadNotebookClip(_ stored: StoredAudioRevision, startSeconds: TimeInterval) async throws {
        guard startSeconds.isFinite, startSeconds >= 0,
              startSeconds < stored.revision.durationSeconds,
              FileManager.default.fileExists(atPath: stored.mediaURL.path) else {
            throw PlaybackControllerError.podcastMediaUnavailable(stored.revision.itemID)
        }
        if currentRevision != nil { try await checkpoint() }
        _ = try await loadRevision(
            stored.revision, mediaURL: stored.mediaURL, isPodcast: true
        )
        try await seek(to: startSeconds, checkpointing: false)
    }
}
