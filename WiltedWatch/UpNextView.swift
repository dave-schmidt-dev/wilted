import SwiftUI

/// The Watch's Up Next screen: the queued episodes from the last phone snapshot.
///
/// Tapping a row asks the phone to play that episode. The list keeps rendering
/// the last snapshot while the phone is unreachable, with its rows disabled and
/// the same one-line note as Now Playing.
struct UpNextView: View {
    /// The state the screen renders and controls.
    let model: WatchViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            queue
            status
        }
        .navigationTitle("Up Next")
    }

    private var rows: [UpNextRow] { model.snapshot?.upNext ?? [] }

    @ViewBuilder private var queue: some View {
        if rows.isEmpty {
            Text("Nothing queued")
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        } else {
            ForEach(rows, id: \.episodeID) { row in
                Button {
                    model.play(episodeID: row.episodeID)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .lineLimit(1)
                        Text(row.showTitle)
                            .font(.caption)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
                }
                .disabled(!model.controlsEnabled)
                .accessibilityLabel("Play \(row.title), \(row.showTitle)")
            }
        }
    }

    private var status: some View {
        Section {
            if let note = model.unreachableNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            Text(model.ageText)
                .font(.caption2)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
    }
}
