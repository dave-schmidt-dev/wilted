import SwiftUI
import WiltedDomain
import WiltedLibrary

/// The audio and decision actions of one episode: the audio state line (Get audio, progress,
/// Cancel), Play once the audio is on the phone, and the decision buttons. The Larder row and the
/// episode detail both render this, so the two never drift apart.
struct LibraryEpisodeActions: View {
    let row: LibraryRow
    var media: LibraryMediaState?
    /// True while this episode's audio is the one playing, so its button pauses.
    var isPlaying = false
    var onMedia: (LibraryMediaAction) -> Void = { _ in }
    /// Plays or pauses the cached audio; only offered once the audio is on the phone.
    var onPlay: (() -> Void)?
    var decisionActions: [LibraryDecisionAction] = []
    var decisionStatus: LibraryDecisionStatus?
    var onDecision: (LibraryDecisionAction) -> Void = { _ in }
    var onCancelDecision: () -> Void = {}

    var body: some View {
        if let media {
            LibraryMediaControl(entryID: row.id, state: media, perform: onMedia)
            if media == .onPhone, let onPlay { playButton(onPlay) }
        }
        LibraryDecisionControl(
            entryID: row.id, actions: decisionActions, status: decisionStatus,
            perform: onDecision, cancel: onCancelDecision)
    }

    private func playButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(playTitle, systemImage: isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
        .accessibilityIdentifier("wilted-library-play-\(row.id.rawValue)")
    }

    /// "Resume 12:34" when the Mac left off partway, so the button says where it will start.
    private var playTitle: String {
        if isPlaying { return "Pause" }
        return row.resumeSeconds.map { "Resume \(LibraryClockFormat.duration($0))" } ?? "Play"
    }
}
