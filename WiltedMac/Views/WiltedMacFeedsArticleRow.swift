import SwiftUI

/// One offered post of an article feed in the Feeds inbox, with the same Keep and Skip
/// answers as a podcast episode row.
struct WiltedMacFeedsArticleRow: View {
    @Bindable var model: WiltedMacModel
    let article: WiltedMacOfferedArticle
    @Environment(\.colorScheme) private var colorScheme

    private var isPending: Bool { model.pendingFeedDecisionIDs.contains(article.id) }

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(2)
                    .accessibilityIdentifier("wilted-feeds-article-title-\(article.id)")
                Text(detail)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feeds-article-metadata-\(article.id)")
                if isPending {
                    HStack(spacing: WiltedTheme.Spacing.xSmall) {
                        ProgressView().controlSize(.small)
                        Text("Saving decision…")
                    }
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feeds-decision-pending-\(article.id)")
                }
                if model.failedFeedDecisionIDs.contains(article.id) {
                    Text("Could not save this decision. Try again.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-feeds-decision-failed-\(article.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Keep") { model.keepOfferedArticle(article) }
                .buttonStyle(.borderedProminent)
                .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                .accessibilityLabel("Keep \(article.title)")
                .accessibilityIdentifier("wilted-feeds-keep-\(article.id)")
                .disabled(isPending)
            Button("Skip") { model.skipOfferedArticle(article) }
                .buttonStyle(WiltedMacOutlinedButtonStyle())
                .accessibilityLabel("Skip \(article.title)")
                .accessibilityIdentifier("wilted-feeds-skip-\(article.id)")
                .disabled(isPending)
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feeds-row-\(article.id)")
    }

    private var detail: String {
        guard let date = article.publishedAt else { return "Article · \(article.feedTitle)" }
        return "Article · \(article.feedTitle) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}
