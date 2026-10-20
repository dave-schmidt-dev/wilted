import SwiftUI
import WiltedDomain

/// The "where it was left" line of an episode. The Mac's checkpoint text stands until this device
/// takes the episode over: once it is loaded in this device's player the line speaks for it
/// ("Playing on this iPad at 04:12", "Paused on this iPhone at 04:12"), so a stale "Paused on Mac"
/// never sits next to an episode being played right here.
struct LibraryCheckpointLine: View {
    let row: LibraryRow
    var player: LibraryPlayer?
    /// "iPad" or "iPhone", from `LibraryAppModel.deviceKind`.
    let deviceKind: String
    var identifier: String

    var body: some View {
        if let player {
            Observed(row: row, player: player, deviceKind: deviceKind, identifier: identifier)
        } else if let text = row.checkpointText {
            LibraryCheckpointText(text: text, identifier: identifier)
        }
    }

    /// Watches the player so the position moves while the episode plays.
    private struct Observed: View {
        let row: LibraryRow
        @ObservedObject var player: LibraryPlayer
        let deviceKind: String
        let identifier: String

        var body: some View {
            if let text = Self.text(row: row, player: player, deviceKind: deviceKind) {
                LibraryCheckpointText(text: text, identifier: identifier)
            }
        }

        static func text(row: LibraryRow, player: LibraryPlayer, deviceKind: String) -> String? {
            guard let loaded = player.item?.entryID, (loaded == row.id || row.memberIDs.contains(loaded)), player.status != .idle else { return row.checkpointText }
            return LibraryCheckpointLine.localText(isPlaying: player.isPlaying, position: player.position, deviceKind: deviceKind)
        }
    }

    /// "Playing on this iPad at 04:12" / "Paused on this iPhone at 04:12".
    static func localText(isPlaying: Bool, position: TimeInterval, deviceKind: String) -> String {
        "\(isPlaying ? "Playing" : "Paused") on this \(deviceKind) at \(LibraryClockFormat.duration(position))"
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
