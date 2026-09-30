import SwiftUI
import WiltedDomain
import WiltedLibrary

/// The controls of one episode, as a row of SF Symbol buttons: download or delete the phone's copy,
/// play or pause, and mark completed. Delete and Mark completed ask first. The Larder row and the
/// episode detail both render this, so the two never drift apart. Larder management (removing an
/// episode from the Mac's Larder) is deliberately not offered here.
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

    @State private var isConfirmingDelete = false
    @State private var isConfirmingCompletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WiltedTheme.Spacing.small) {
                if let media {
                    LibraryDownloadControl(
                        entryID: row.id, state: media, perform: onMedia, isConfirmingDelete: $isConfirmingDelete)
                    if media == .onPhone, let onPlay {
                        LibraryIconButton(
                            symbol: isPlaying ? "pause.circle.fill" : "play.circle.fill", label: playLabel,
                            identifier: "wilted-library-play-\(row.id.rawValue)", action: onPlay)
                    }
                }
                if decisionActions.contains(.markDone) {
                    LibraryIconButton(
                        symbol: LibraryDecisionAction.markDone.systemImage, label: LibraryDecisionAction.markDone.title,
                        identifier: "wilted-library-action-done-\(row.id.rawValue)") { isConfirmingCompletion = true }
                }
                Spacer(minLength: 0)
            }
            LibraryStatusLine(entryID: row.id, media: media, decision: decisionStatus, cancelDecision: onCancelDecision)
        }
        .confirmationDialog("Delete the download?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete download", role: .destructive) { onMedia(.removeFromPhone) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The episode stays in the Larder to download again.")
        }
        .confirmationDialog("Mark completed?", isPresented: $isConfirmingCompletion, titleVisibility: .visible) {
            Button("Mark completed") { onDecision(.markDone) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is marked completed on the Mac too.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-media-\(row.id.rawValue)")
    }

    /// "Resume 12:34" when the Mac left off partway, so VoiceOver says where it will start.
    private var playLabel: String {
        if isPlaying { return "Pause" }
        return row.resumeSeconds.map { "Resume from \(LibraryClockFormat.duration($0))" } ?? "Play"
    }
}
