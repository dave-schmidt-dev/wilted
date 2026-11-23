import SwiftUI

/// Every link an earlier version made, each with its Unlink. A link can leave a pair with no row in
/// the Larder (finished, or not waiting) and none in Feeds, so this list does not depend on any row.
/// It is empty, and invisible, for a library that never had a link.
struct WiltedMacLinkedEpisodesSection: View {
    @Bindable var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var review: WiltedMacLinkedEpisodeUnlink?

    var body: some View {
        let pairs = model.linkedEpisodePairs
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Text("Linked episodes")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Text("An earlier version linked these episodes so they share progress and choices. Unlinking keeps every episode and gives each its own.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pairs.enumerated()), id: \.element.id) { index, pair in
                        if index > 0 { Divider() }
                        HStack(spacing: WiltedTheme.Spacing.medium) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pair.title)
                                    .lineLimit(2)
                                if pair.association.isTerminal {
                                    Text("Finished")
                                        .wiltedFont(.utility)
                                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Unlink\u{2026}") {
                                Task { review = await model.prepareLinkedEpisodeUnlink(for: pair.association) }
                            }
                            .accessibilityIdentifier("wilted-linked-unlink-\(pair.id.uuidString)")
                        }
                        .padding(.vertical, WiltedTheme.Spacing.small)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("wilted-linked-pair-\(pair.id.uuidString)")
                    }
                }
                .wiltedCard(colorScheme)
            }
            .alert(
                "Unlink these episodes?",
                isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } }),
                presenting: review
            ) { review in
                Button("Unlink", role: .destructive) { Task { await model.unlinkEpisodes(review) } }
                Button("Cancel", role: .cancel) {}
            } message: { review in
                Text(review.summary)
            }
        }
    }
}
