import Foundation

extension WiltedMacModel {
    /// How far through an episode the listener is, for a Larder row. The live
    /// playhead wins for the episode playing now, so the bar follows it; every
    /// other row reads its saved position. Nil unless partway through.
    func episodeProgress(_ episode: WiltedMacEpisode) -> WiltedMacEpisodeProgress? {
        let position = isPodcastPlayback && currentPodcastEpisodeID == episode.id
            ? playbackPositionSeconds
            : episode.playbackSeconds
        return WiltedMacEpisodeProgress(
            positionSeconds: position,
            durationSeconds: episode.durationSeconds,
            isPlayed: episode.isPlayed
        )
    }
}

extension WiltedMacTranscript {
    /// The cue a tapped transcript line stands for. Looked up by identity and
    /// bounds-checked, rather than indexing `cues` with the line's id: a line
    /// built from a stale transcript must seek nowhere, not trap.
    func cue(forLineID id: Int) -> WiltedMacTranscriptCue? {
        cues.first { $0.id == id }
    }
}
