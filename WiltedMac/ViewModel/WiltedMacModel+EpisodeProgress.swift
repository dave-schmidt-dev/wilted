import Foundation

extension WiltedMacTranscript {
    /// The cue a tapped transcript line stands for. Looked up by identity and
    /// bounds-checked, rather than indexing `cues` with the line's id: a line
    /// built from a stale transcript must seek nowhere, not trap.
    func cue(forLineID id: Int) -> WiltedMacTranscriptCue? {
        cues.first { $0.id == id }
    }
}
