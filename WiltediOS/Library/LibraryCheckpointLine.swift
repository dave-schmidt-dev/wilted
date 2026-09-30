import SwiftUI
import WiltedDomain

/// The "where it was left" line of an episode. The Mac's checkpoint text stands until this phone
/// takes the episode over: once it is loaded in the phone's player the line speaks for the phone
/// ("Playing on this iPhone at 04:12", "Paused on this iPhone at 04:12"), so a stale "Paused on Mac"
/// never sits next to an episode being played right here.
struct LibraryCheckpointLine: View {
    let row: LibraryRow
    var player: LibraryPlayer?
    var identifier: String

    var body: some View {
        if let player {
            Observed(row: row, player: player, identifier: identifier)
        } else if let text = row.checkpointText {
            LibraryCheckpointText(text: text, identifier: identifier)
        }
    }

    /// Watches the player so the position moves while the episode plays.
    private struct Observed: View {
        let row: LibraryRow
        @ObservedObject var player: LibraryPlayer
        let identifier: String

        var body: some View {
            if let text = Self.text(row: row, player: player) {
                LibraryCheckpointText(text: text, identifier: identifier)
            }
        }

        static func text(row: LibraryRow, player: LibraryPlayer) -> String? {
            guard player.item?.entryID == row.id, player.status != .idle else { return row.checkpointText }
            return LibraryCheckpointLine.localText(isPlaying: player.isPlaying, position: player.position)
        }
    }

    /// "Playing on this iPhone at 04:12" / "Paused on this iPhone at 04:12".
    static func localText(isPlaying: Bool, position: TimeInterval) -> String {
        "\(isPlaying ? "Playing" : "Paused") on this iPhone at \(LibraryClockFormat.duration(position))"
    }
}

private struct LibraryCheckpointText: View {
    let text: String
    let identifier: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.progress, scheme: colorScheme))
            .accessibilityIdentifier(identifier)
    }
}
