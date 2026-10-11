import SwiftUI

/// Facts for one followed feed, kept with its own history and settings.
struct WiltedMacFeedDetailsView: View {
    let model: WiltedMacModel
    let board: WiltedMacFeedPolicyBoard
    let subscription: WiltedMacSubscription
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WiltedMacDestination(
            title: subscription.title,
            identifier: "wilted-mac-feed-details-\(subscription.id)",
            contentWidth: 760
        ) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                sourceDetails
                settings
                WiltedMacFeedHistoryView(model: model, feedID: subscription.id)
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Source and status").wiltedFont(.title)
            factRow("Publisher", value: subscription.publisherTitle ?? "Publisher not provided")
            factRow("Followed", value: subscription.subscribedAt.formatted(date: .abbreviated, time: .shortened))
            factRow("Visibility", value: subscription.enabled ? "Shown in Feeds" : "Hidden from Feeds")
            factRow("Refresh status", value: model.feedRowStatus(subscription.id) ?? "Not currently refreshing")
            factRow("Last refreshed", value: model.lastPodcastRefreshExactText)
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
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-details-source-facts-\(subscription.id)")
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack {
                Text("Current settings").wiltedFont(.title)
                Spacer()
                WiltedMacFeedPolicyButton(board: board, subscription: subscription)
            }
            if let failure = board.loadFailureMessage {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .wiltedFont(.utility)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("wilted-feed-details-settings-error")
                Button("Retry settings") { Task { await board.retryReload() } }
                    .disabled(!board.canRetry)
                    .accessibilityIdentifier("wilted-feed-details-settings-retry")
            }
            if board.isLoaded(subscription.id) {
                ForEach(board.summary(for: subscription.id), id: \.label) { row in
                    factRow(row.label, value: row.value)
                }
            } else if board.loadFailureMessage == nil {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text("Loading saved settings…").wiltedFont(.utility)
                }
                .accessibilityIdentifier("wilted-feed-details-settings-loading")
            }
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-details-settings-\(subscription.id)")
    }

    private func factRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.medium) {
            Text(label)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .frame(width: 118, alignment: .leading)
            Text(value)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-feed-details-value-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
    }
}
