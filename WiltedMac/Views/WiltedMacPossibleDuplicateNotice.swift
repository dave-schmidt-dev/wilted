import SwiftUI

/// One line under an episode the feed refresh flagged as a possible duplicate, with the two answers.
/// It shows on Feeds rows and Larder rows alike, and needs no sheet.
struct WiltedMacPossibleDuplicateNotice: View {
    let model: WiltedMacModel
    let episode: WiltedMacEpisode
    let earlierTitle: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Text(earlierTitle.isEmpty ? "Possible duplicate" : "Possible duplicate of “\(earlierTitle)”")
                .lineLimit(1)
                .accessibilityIdentifier("wilted-possible-duplicate-\(episode.id)")
            Button("Same episode") { model.removePossibleDuplicate(episode) }
                .accessibilityIdentifier("wilted-possible-duplicate-same-\(episode.id)")
            Button("Different") { model.clearPossibleDuplicateFlag(episode) }
                .accessibilityIdentifier("wilted-possible-duplicate-different-\(episode.id)")
        }
        .wiltedFont(.utility)
        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        .buttonStyle(.link)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }
}
