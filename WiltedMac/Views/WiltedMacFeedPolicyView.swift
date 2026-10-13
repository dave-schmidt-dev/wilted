import Foundation
import Observation
import SwiftUI
import WiltedDomain
import WiltedProducer

// MARK: - Feed row control

/// The gear on a subscription row and the popover it opens. The match rules
/// open from the popover as a sheet hung on the gear, so the sheet outlives
/// the popover and, from the feed-details sheet, stacks over that sheet.
struct WiltedMacFeedPolicyButton: View {
    let board: WiltedMacFeedPolicyBoard
    let subscription: WiltedMacSubscription
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false
    @State private var isEditingRules = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "gearshape")
                .accessibilityHidden(true)
                .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.borderless)
        .help("Feed settings")
        .accessibilityLabel("Feed settings for \(subscription.title)")
        .accessibilityIdentifier("wilted-feed-policy-button-\(subscription.id)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            WiltedMacFeedPolicyContent(
                board: board, subscription: subscription, dismiss: { isPresented = false },
                openRules: { isPresented = false; isEditingRules = true }
            )
            .padding(WiltedTheme.Spacing.large)
            .background(WiltedTheme.color(.card, scheme: colorScheme))
        }
        .sheet(isPresented: $isEditingRules) {
            WiltedMacFeedRulesView(
                editor: board.rulesEditor(for: subscription.id), subscription: subscription,
                resolved: board.resolved(for: subscription.id), dismiss: { isEditingRules = false }
            )
        }
    }
}

// MARK: - Popover content

/// The four per-feed choices and what they resolve to right now.
struct WiltedMacFeedPolicyContent: View {
    static let width: CGFloat = 460

    let board: WiltedMacFeedPolicyBoard
    let subscription: WiltedMacSubscription
    var dismiss: () -> Void = {}
    /// Closes the popover and opens the rules sheet.
    var openRules: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @State private var limitIsRejected = false

    private var feedID: String { subscription.id }
    private var policy: FeedAutomationPolicy { board.policy(for: feedID) }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text("Feed settings")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Grid(alignment: .leading, horizontalSpacing: WiltedTheme.Spacing.medium,
                 verticalSpacing: WiltedTheme.Spacing.small) {
                overrideRow(
                    "Auto keep", label: "Auto keep for \(subscription.title)",
                    identifier: "wilted-feed-policy-auto-keep",
                    selection: overrideBinding(\.autoKeep) { board.update(feedID, autoKeep: $0) }
                )
                // An article has no file to download, so its feed offers no download choice.
                if !board.isArticleFeed(feedID) {
                    overrideRow(
                        "Auto download", label: "Auto download for \(subscription.title)",
                        identifier: "wilted-feed-policy-auto-download",
                        selection: overrideBinding(\.autoDownload) { board.update(feedID, autoDownload: $0) }
                    )
                }
                overrideRow(
                    "Auto prepare", label: "Auto prepare for \(subscription.title)",
                    identifier: "wilted-feed-policy-auto-prepare",
                    selection: overrideBinding(\.autoPrepare) { board.update(feedID, autoPrepare: $0) }
                )
                keptLimitRows
                if board.isArticleFeed(feedID) { newsRow }
            }
            .disabled(!board.isLoaded(feedID))
            if board.isArticleFeed(feedID) {
                Text("Marks the articles from this feed as news.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if limitIsRejected {
                Text("Enter a whole number of at least 1.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feed-policy-limit-error")
            }
            if board.failedFeedIDs.contains(feedID) {
                Text("Could not save this change. The stored setting is shown.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feed-policy-failed")
            }
            WiltedMacFeedRulesEntry(
                editor: board.rulesEditor(for: feedID), subscription: subscription, isEnabled: board.isLoaded(feedID),
                open: openRules
            )
            Divider()
            Text("A lower limit never removes \(board.isArticleFeed(feedID) ? "an article" : "an episode") already in Larder.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Close feed settings for \(subscription.title)")
                    .accessibilityIdentifier("wilted-feed-policy-done")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-policy-\(subscription.id)")
        .frame(width: Self.width)
    }

    /// Shown only for a feed that lists articles: label in the label column, toggle in the control column.
    private var newsRow: some View {
        GridRow {
            Text("News").wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Toggle("News", isOn: Binding(
                get: { board.isNews(feedID) }, set: { _ = board.setNews($0, for: feedID) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("Treat \(subscription.title) as news")
            .accessibilityIdentifier("wilted-feed-policy-news")
        }
    }

    private func overrideRow(
        _ title: String, label: String, identifier: String, selection: Binding<FeedAutomationOverride>
    ) -> some View {
        GridRow {
            Text(title)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Picker(title, selection: selection) {
                Text("Use global (\(globalValue(title)))").tag(FeedAutomationOverride.useGlobal)
                Text("On").tag(FeedAutomationOverride.on)
                Text("Off").tag(FeedAutomationOverride.off)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
        }
    }

    private func globalValue(_ title: String) -> String {
        WiltedFeedAutomationSummary.globalRows(board.model.automationSettings)
            .first { $0.label == title }?.value ?? "Unknown"
    }

    private var keptLimitRows: some View {
        GridRow {
            Text("Kept limit").wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            HStack(spacing: WiltedTheme.Spacing.small) {
                Picker("Kept limit", selection: limitModeBinding) {
                    Text("Use global (\(globalValue("Kept limit")))").tag(false)
                    Text("Set a limit").tag(true)
                }
                .labelsHidden().pickerStyle(.menu)
                .accessibilityLabel("Kept limit for \(subscription.title)")
                .accessibilityIdentifier("wilted-feed-policy-kept-limit-mode")
                if case let .explicit(count) = policy.keptLimit {
                    TextField("Episodes", value: limitBinding(current: count), format: .number)
                        .frame(width: 48)
                        .accessibilityLabel("Number of episodes kept for \(subscription.title)")
                        .accessibilityIdentifier("wilted-feed-policy-kept-limit")
                    Text("episodes").wiltedFont(.utility)
                    Stepper("Episodes kept", value: limitBinding(current: count), in: 1...999)
                        .labelsHidden()
                        .accessibilityLabel("Adjust episodes kept for \(subscription.title)")
                        .accessibilityIdentifier("wilted-feed-policy-kept-limit-stepper")
                }
            }
        }
    }

    private func overrideBinding(
        _ keyPath: KeyPath<FeedAutomationPolicy, FeedAutomationOverride>,
        set: @escaping (FeedAutomationOverride) -> Bool
    ) -> Binding<FeedAutomationOverride> {
        Binding(get: { policy[keyPath: keyPath] }, set: { _ = set($0) })
    }

    private var limitModeBinding: Binding<Bool> {
        Binding(
            get: { if case .explicit = policy.keptLimit { true } else { false } },
            set: { wantsLimit in
                limitIsRejected = false
                if wantsLimit {
                    // Start from what the feed already keeps, so the limit never opens below it.
                    let kept = board.keptCount(forFeed: feedID)
                    board.update(feedID, keptLimit: .explicit(max(1, kept)))
                } else {
                    board.update(feedID, keptLimit: .useGlobal)
                }
            }
        )
    }

    private func limitBinding(current: Int) -> Binding<Int> {
        Binding(
            get: { current },
            set: { value in limitIsRejected = !board.update(feedID, keptLimit: .explicit(value)) }
        )
    }
}

// MARK: - Settings: global Auto keep and kept limit

/// The two global defaults Settings owns outright. Auto download and Auto
/// prepare keep their existing Larder and Processing controls.
struct WiltedMacGlobalFeedDefaultsControls: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Toggle("Auto keep", isOn: autoKeepBinding)
                .accessibilityLabel("Auto keep for feeds set to Use global")
                .accessibilityIdentifier("wilted-automation-feed-default-auto-keep")
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text("Kept limit")
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer(minLength: WiltedTheme.Spacing.large)
                Picker("Kept limit", selection: limitModeBinding) {
                    Text("No limit").tag(false)
                    Text("Set a limit").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Kept limit for feeds set to Use global")
                .accessibilityIdentifier("wilted-automation-feed-default-kept-limit-mode")
                if let limit = model.automationSettings.keptLimitPerFeed {
                    TextField("Episodes", value: limitBinding(limit), format: .number)
                        .frame(width: 64)
                        .accessibilityLabel("Number of episodes kept for feeds set to Use global")
                        .accessibilityIdentifier("wilted-automation-feed-default-kept-limit")
                    Stepper("Episodes kept", value: limitBinding(limit), in: 1...999)
                        .labelsHidden()
                        .accessibilityLabel("Adjust episodes kept for feeds set to Use global")
                        .accessibilityIdentifier("wilted-automation-feed-default-kept-limit-stepper")
                }
            }
        }
    }

    private var autoKeepBinding: Binding<Bool> {
        Binding(
            get: { model.automationSettings.autoKeepNewEpisodes },
            set: { value in
                model.updateAutomationSettings { $0.settingAutoKeepNewEpisodes(value) }
                releaseWaiting()
            }
        )
    }

    private var limitModeBinding: Binding<Bool> {
        Binding(
            get: { model.automationSettings.keptLimitPerFeed != nil },
            set: { wantsLimit in
                model.updateAutomationSettings { $0.settingKeptLimitPerFeed(wantsLimit ? 5 : nil) }
                releaseWaiting()
            }
        )
    }

    private func limitBinding(_ current: Int) -> Binding<Int> {
        Binding(
            get: { current },
            set: { value in
                // A value below one is refused; the field keeps showing the stored limit.
                guard value >= 1 else { return }
                model.updateAutomationSettings { $0.settingKeptLimitPerFeed(value) }
                releaseWaiting()
            }
        )
    }

    /// A raised limit, or Auto keep switched on, fills open places on feeds
    /// that use the global value, through the same admission a refresh uses.
    private func releaseWaiting() {
        let feedIDs = Set(model.subscriptions.map(\.id))
        Task { await model.releaseWaitingEpisodes(feedIDs: feedIDs) }
    }
}
