import SwiftUI

/// The immutable source facts and episode history shown at the end of Show settings.
struct WiltedMacFeedDetailsSection: View {
    let model: WiltedMacModel
    let subscription: WiltedMacSubscription
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
            sourceDetails
            WiltedMacFeedHistoryView(model: model, feedID: subscription.id)
        }
        .accessibilityIdentifier("wilted-feed-details-\(subscription.id)")
    }

    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Source and status").wiltedFont(.title)
            factRow("Publisher", value: subscription.publisherTitle ?? "Publisher not provided")
            factRow("Followed", value: subscription.subscribedAt.formatted(date: .abbreviated, time: .shortened))
            factRow("Visibility", value: subscription.enabled ? "Shown in Feeds" : "Hidden from Feeds")
            factRow("Refresh status", value: model.feedRowStatus(subscription.id) ?? "Not currently refreshing")
            factRow(
                "Global podcast refresh",
                value: model.lastPodcastRefreshAt?.formatted(date: .complete, time: .standard) ?? "Never"
            )
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text("Source URL").wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                Link(subscription.feedURL.absoluteString, destination: subscription.feedURL)
                    .wiltedFont(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Feed source URL")
                    .accessibilityIdentifier("wilted-feed-details-source-\(subscription.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-details-source-facts-\(subscription.id)")
    }

    private func factRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.medium) {
            Text(label)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .frame(width: 150, alignment: .leading)
            Text(value)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(
                    "wilted-feed-details-value-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
                )
        }
    }
}
