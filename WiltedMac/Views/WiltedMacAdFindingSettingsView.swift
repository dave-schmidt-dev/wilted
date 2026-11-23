import SwiftUI
import WiltedDomain
import WiltedProducer

// MARK: - Settings card

/// The Ad finding card in Settings: the provider key, global switch, consent summary,
/// and today's request count. Per-show consent lives on each Show settings page.
struct WiltedMacAdFindingSettingsView: View {
    private let appModel: WiltedMacModel
    private let board: WiltedMacFeedPolicyBoard
    @Environment(\.colorScheme) private var colorScheme
    @State private var presentedDestination: Destination?

    private enum Destination: Identifiable {
        case allShows
        case showSettings(String)

        var id: String {
            switch self {
            case .allShows: "all-shows"
            case let .showSettings(feedID): "show-settings-\(feedID)"
            }
        }
    }

    init(model appModel: WiltedMacModel, board: WiltedMacFeedPolicyBoard) {
        self.appModel = appModel
        self.board = board
    }

    private var model: WiltedMacAdFindingSettings { appModel.adFinding }
    private var subscriptions: [WiltedMacSubscription] { appModel.subscriptions }

    private var podcastSubscriptions: [WiltedMacSubscription] {
        subscriptions.filter { !WiltedMacFeedKind.isArticleSubscription($0) }
    }

    private var allowedPodcastShowCount: Int {
        let allowed = board.confirmedAdFeedIDs
        return podcastSubscriptions.filter { allowed.contains($0.id) }.count
    }

    var body: some View {
        WiltedSettingsCard(title: "Ad finding") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Toggle("Find ads with the online labeller", isOn: Binding(
                    get: { model.isOnlineFindingOn }, set: { model.setOnlineFinding($0) }
                ))
                .accessibilityIdentifier("wilted-ad-finding-switch")
                if let message = model.switchMessage {
                    Text(message)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-ad-finding-switch-message")
                }
                Divider()
                WiltedMacAdFindingModelSection(model: appModel)
                Divider()
                Button {
                    presentedDestination = .allShows
                } label: {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                        Text("\(allowedPodcastShowCount) of \(podcastSubscriptions.count) shows allowed for ad finding")
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: WiltedTheme.Spacing.xSmall) {
                            Text("All shows")
                                .wiltedFont(.utility)
                                .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                            Image(systemName: "chevron.right")
                                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(allowedPodcastShowCount) of \(podcastSubscriptions.count) shows allowed for ad finding. All shows")
                .accessibilityIdentifier("wilted-ad-finding-consent-summary")
                if let paused = model.providerPausedSentence {
                    WiltedSettingsRow(
                        "Provider",
                        value: paused,
                        identifier: "wilted-ad-finding-provider-paused"
                    )
                }
                Divider()
                WiltedSettingsRow(
                    "Requests today",
                    value: "\(model.requestsToday) of \(model.dailyCap)",
                    identifier: "wilted-ad-finding-requests"
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            WiltedMacHelpButton(content: help, identifier: "wilted-ad-finding-help")
                .padding(WiltedTheme.Spacing.medium)
        }
        .sheet(item: $presentedDestination) { destination in
            switch destination {
            case .allShows:
                allShowsPage
            case let .showSettings(feedID):
                showSettingsPage(feedID: feedID)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.isConfirming }, set: { if !$0 { model.cancel() } }
        )) {
            WiltedMacAdFindingConfirmSheet(model: model, board: board) {
                board.refreshAdPreferences()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-ad-finding-controls")
    }

    var allShowsPage: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Text("All shows")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                Button("Done") { presentedDestination = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("wilted-settings-all-shows-done")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(podcastSubscriptions.enumerated()), id: \.element.id) { index, subscription in
                        if index > 0 { Divider() }
                        Button {
                            presentedDestination = .showSettings(subscription.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                                    Text(subscription.title)
                                        .wiltedFont(.body)
                                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                                    Text(WiltedMacFeedKind.isArticleSubscription(subscription) ? "Article feed" : "Podcast")
                                        .wiltedFont(.utility)
                                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wilted-settings-all-show-\(subscription.id)")
                        .padding(.vertical, WiltedTheme.Spacing.small)
                    }
                }
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 560, height: 620)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-settings-all-shows-page")
    }

    @ViewBuilder private func showSettingsPage(feedID: String) -> some View {
        if let subscription = appModel.subscriptions.first(where: { $0.id == feedID }) {
            VStack(spacing: 0) {
                HStack {
                    Button("All shows") { presentedDestination = .allShows }
                        .accessibilityIdentifier("wilted-settings-all-shows-back")
                    Spacer()
                    Button("Done") { presentedDestination = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("wilted-feed-sheet-done")
                }
                .padding(.horizontal, WiltedTheme.Spacing.large)
                .padding(.top, WiltedTheme.Spacing.small)

                WiltedMacShowSettingsView(model: appModel, board: board, subscription: subscription)
            }
        }
    }

    private var help: WiltedMacHelpContent {
        WiltedMacHelpContent(title: "Ad finding", text:
            "Only shows allowed on their Show settings pages are sent: their transcripts go to the online labeller to find ads. "
            + "Shows added later are not sent until turned on in Show settings.")
    }
}

// MARK: - Confirm sheet

/// The confirm sheet's content, on its own so a headless test can render it
/// without presenting it.
struct WiltedMacAdFindingConfirmSheet: View {
    let model: WiltedMacAdFindingSettings
    private let board: WiltedMacFeedPolicyBoard?
    private let onConfirm: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(
        model: WiltedMacAdFindingSettings,
        board: WiltedMacFeedPolicyBoard? = nil,
        onConfirm: @escaping () -> Void = {}
    ) {
        self.model = model
        self.board = board
        self.onConfirm = onConfirm
    }

    var body: some View {
        let _ = board?.confirmedAdFeedIDs
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text("Turn on online ad finding?")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text("The online labeller receives transcripts from these shows to find ads.")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            ScrollView {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                    group("Transcripts will be sent", shows: model.sheetSentShows)
                    Divider()
                    group("Not sent", shows: model.sheetNotSentShows)
                    Text("Shows you add later are not sent until you turn them on in Show settings.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Cancel") { model.cancel() }
                    .accessibilityIdentifier("wilted-ad-finding-sheet-cancel")
                Spacer()
                Button("Confirm") {
                    model.confirm()
                    onConfirm()
                }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("wilted-ad-finding-sheet-confirm")
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 460, height: 520)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-ad-finding-sheet")
    }

    /// A read-only preview of the show's route and owner choices.
    private func group(_ title: String, shows: [WiltedMacAdFindingSettings.Show]) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text(title)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            ForEach(shows) { show in
                HStack(alignment: .top, spacing: WiltedTheme.Spacing.small) {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                        Text(show.title)
                            .wiltedFont(.body)
                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        if title == "Not sent" {
                            Text(model.confirmationNotSentMessage(for: show))
                                .wiltedFont(.utility)
                                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: WiltedTheme.Spacing.large)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wilted-ad-finding-confirm-show-\(show.feedID)")
            }
        }
    }
}
