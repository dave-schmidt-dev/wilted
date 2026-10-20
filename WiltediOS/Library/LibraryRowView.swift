import SwiftUI
import WiltedDomain
import WiltedLibrary

/// A named VoiceOver action on a Larder row.
struct LibraryRowVoiceAction {
    let name: String
    let perform: () -> Void
}

struct LibraryRowView: View {
    let row: LibraryRow
    var media: LibraryMediaState?
    /// True while this row's audio is the one playing, so its button pauses.
    var isPlaying = false
    var onMedia: (LibraryMediaAction) -> Void = { _ in }
    /// False until the Mac has linked this device; the row then offers no request for audio.
    var canRequestAudio = true
    /// Plays or pauses the cached audio; only offered once the audio is on the phone.
    var onPlay: (() -> Void)?
    /// Decision buttons for this row, and what its decision in flight says.
    var decisionActions: [LibraryDecisionAction] = []
    var decisionStatus: LibraryDecisionStatus?
    var onDecision: (LibraryDecisionAction) -> Void = { _ in }
    var onCancelDecision: () -> Void = {}
    /// Lets the checkpoint line speak for this phone once it has the episode loaded.
    var player: LibraryPlayer?
    /// Where the listener is in the episode on any device (this phone or one synced from the Mac), and
    /// whether it is finished; the same data the car rows use.
    var progress: EpisodeProgress?
    var isCompleted = false
    /// Offered to VoiceOver on the title, where the row's swipe actions are not reachable.
    var voiceOverActions: [LibraryRowVoiceAction] = []
    /// When false, the detail line leaves out the show, which a feed section header already names.
    var showsShowName = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
            LibraryArtwork(url: row.artworkURL)
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text(row.title)
                    .wiltedFont(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityActions {
                        ForEach(voiceOverActions, id: \.name) { action in Button(action.name, action: action.perform) }
                    }
                    .accessibilityIdentifier("wilted-library-title-\(row.id.rawValue)")
                LibraryRowMetadataView(row: row, namesShow: showsShowName)
                if let status = Self.listeningStatus(row: row, progress: progress, completed: isCompleted) {
                    Text(status)
                        .wiltedFont(.utility)
                        .foregroundStyle(secondary)
                        .accessibilityIdentifier("wilted-library-listening-status-\(row.id.rawValue)")
                }
                if isCompleted {
                    Text("Played")
                        .wiltedFont(.utility)
                        .foregroundStyle(secondary)
                        .accessibilityIdentifier("wilted-library-completed-\(row.id.rawValue)")
                }
                if !isCompleted, let fraction = CarEpisodeList.fraction(progress, duration: row.durationSeconds) {
                    ProgressView(value: fraction)
                        .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                        .accessibilityLabel("Listened")
                        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                        .accessibilityIdentifier("wilted-library-progress-\(row.id.rawValue)")
                }
                if let removal = row.removalText {
                    Text(removal)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
                        .accessibilityIdentifier("wilted-library-removal-\(row.id.rawValue)")
                }
                LibraryCheckpointLine(row: row, player: player, identifier: "wilted-library-checkpoint-\(row.id.rawValue)")
                LibraryEpisodeActions(
                    row: row, media: media, isPlaying: isPlaying, onMedia: onMedia, canRequestAudio: canRequestAudio,
                    onPlay: onPlay, decisionActions: decisionActions, decisionStatus: decisionStatus,
                    onDecision: onDecision, onCancelDecision: onCancelDecision)
            }
        }
        .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-row-\(row.id.rawValue)")
    }

    /// Playback status stays separate from the factual metadata line. Nil means duration or
    /// progress data is not safe to present; completion has its existing, separate Played label.
    static func listeningStatus(row: LibraryRow, progress: EpisodeProgress?, completed: Bool) -> String? {
        guard !completed, let duration = row.durationSeconds,
              duration.isFinite, duration > 0, duration < Double(Int.max / 2) else { return nil }
        guard let progress else { return "New" }
        let position = progress.positionSeconds
        guard position.isFinite, position >= 0 else { return nil }
        let remaining = max(0, duration - position)
        guard remaining.isFinite else { return nil }
        return "\(LibraryClockFormat.duration(remaining)) left"
    }

    private var secondary: Color { WiltedTheme.color(.secondaryText, scheme: colorScheme) }
}
