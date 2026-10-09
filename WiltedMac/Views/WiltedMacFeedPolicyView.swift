import Foundation
import Observation
import SwiftUI
import WiltedDomain
import WiltedProducer

// MARK: - Board

/// Per-feed automation policies as the Feeds page needs them, read and written
/// through the library store.
///
/// The model keeps no copy of a feed's policy, so this board holds the loaded
/// values for the views. A choice shows at once and is written in order; the
/// board never edits a value it has not loaded, so a failed read cannot be
/// overwritten with defaults. `reload()` and `settle()` are awaitable so a
/// test (or a caller that needs the stored result) does not race the writer.
@MainActor @Observable
final class WiltedMacFeedPolicyBoard {
    let model: WiltedMacModel
    private(set) var policies: [String: FeedAutomationPolicy] = [:]
    private(set) var failedFeedIDs: Set<String> = []
    @ObservationIgnored private var rules: [String: EpisodeMatchRules] = [:]
    @ObservationIgnored private var editors: [String: WiltedMacFeedRulesEditor] = [:]
    @ObservationIgnored private var writeChain: Task<Void, Never>?

    init(model: WiltedMacModel) {
        self.model = model
    }

    func isLoaded(_ feedID: String) -> Bool { policies[feedID] != nil }

    func policy(for feedID: String) -> FeedAutomationPolicy { policies[feedID] ?? FeedAutomationPolicy() }

    /// The feed's choices resolved against the same global defaults admission uses.
    func resolved(for feedID: String) -> EffectiveFeedAutomationPolicy {
        policy(for: feedID).resolved(using: model.automationSettings.feedAutomationDefaults)
    }

    func summary(for feedID: String) -> [WiltedFeedAutomationSummary.Row] {
        WiltedFeedAutomationSummary.rows(resolved(for: feedID))
    }

    /// Reads every subscription's policy and match rules from the store.
    func reload() async {
        await settle()
        guard let store = model.store else { return }
        var loaded: [String: FeedAutomationPolicy] = [:]
        var loadedRules: [String: EpisodeMatchRules] = [:]
        for subscription in model.subscriptions {
            guard let feedID = try? ItemID(rawValue: subscription.id),
                  let policy = try? await store.feedAutomationPolicy(for: feedID) else { continue }
            loaded[subscription.id] = policy
            loadedRules[subscription.id] = (try? await store.episodeMatchRules(for: feedID)) ?? EpisodeMatchRules()
        }
        policies = loaded
        rules = loadedRules
    }

    // MARK: Match rules

    /// The feed's saved rules, in order.
    func rules(for feedID: String) -> EpisodeMatchRules { rules[feedID] ?? EpisodeMatchRules() }

    /// The feed's rules editor, kept so a draft survives closing the popover.
    func rulesEditor(for feedID: String) -> WiltedMacFeedRulesEditor {
        if let editor = editors[feedID] { return editor }
        let editor = WiltedMacFeedRulesEditor(board: self, feedID: feedID)
        editors[feedID] = editor
        return editor
    }

    /// Saves a feed's whole ordered rule set. Returns false, changing nothing,
    /// when the feed is not loaded or a pattern is invalid.
    @discardableResult
    func replaceRules(_ next: EpisodeMatchRules, for feedID: String) -> Bool {
        guard isLoaded(feedID), (try? next.validate()) != nil else { return false }
        rules[feedID] = next
        failedFeedIDs.remove(feedID)
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            await self?.persist(rules: next, feedID)
        }
        return true
    }

    private func persist(rules next: EpisodeMatchRules, _ feedID: String) async {
        guard let store = model.store, !model.isClosingTemporaryState,
              let id = try? ItemID(rawValue: feedID) else { return }
        do {
            try await store.replaceEpisodeMatchRules(next, for: id)
        } catch {
            failedFeedIDs.insert(feedID)
            if let stored = try? await store.episodeMatchRules(for: id) { rules[feedID] = stored }
        }
    }

    /// Waits for every accepted choice to reach the store.
    func settle() async {
        while let pending = writeChain {
            await pending.value
            if writeChain == pending { writeChain = nil }
        }
    }

    /// Applies one or more choices to a feed. Returns false, changing nothing,
    /// when the feed is not loaded or a kept limit is below one.
    @discardableResult
    func update(
        _ feedID: String,
        autoKeep: FeedAutomationOverride? = nil,
        autoDownload: FeedAutomationOverride? = nil,
        autoPrepare: FeedAutomationOverride? = nil,
        keptLimit: FeedKeptLimitOverride? = nil
    ) -> Bool {
        guard let current = policies[feedID] else { return false }
        if case let .explicit(count)? = keptLimit, count < 1 { return false }
        let next = FeedAutomationPolicy(
            autoKeep: autoKeep ?? current.autoKeep, autoDownload: autoDownload ?? current.autoDownload,
            autoPrepare: autoPrepare ?? current.autoPrepare, keptLimit: keptLimit ?? current.keptLimit
        )
        guard next != current else { return true }
        policies[feedID] = next
        failedFeedIDs.remove(feedID)
        // Only a change to what may be kept can open or close places.
        let changesCapacity = next.autoKeep != current.autoKeep || next.keptLimit != current.keptLimit
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            await self?.persist(feedID, next, releasing: changesCapacity)
        }
        return true
    }

    private func persist(_ feedID: String, _ policy: FeedAutomationPolicy, releasing: Bool) async {
        guard let store = model.store, !model.isClosingTemporaryState,
              let id = try? ItemID(rawValue: feedID) else { return }
        do {
            try await store.save(feedAutomationPolicy: policy, for: id)
        } catch {
            failedFeedIDs.insert(feedID)
            if let stored = try? await store.feedAutomationPolicy(for: id) { policies[feedID] = stored }
            return
        }
        // A raised limit, or Auto keep switched on, fills open places now,
        // through the same admission a refresh uses. Nothing is ever removed.
        if releasing { await model.releaseWaitingEpisodes(feedIDs: [feedID]) }
    }

    // MARK: Waiting for space

    /// Episodes the admission planner holds back because the feed is full,
    /// oldest first. Empty unless the feed resolves to Auto keep with a limit.
    func waitingEpisodes(forFeed feedID: String) -> [WiltedMacEpisode] {
        guard isLoaded(feedID) else { return [] }
        let policy = resolved(for: feedID)
        guard policy.autoKeep, policy.keptLimit != nil else { return [] }
        let live = model.episodes.filter { $0.feedID == feedID && $0.removalKind == nil }
        let kept = Set(model.podcastQueueIDs).intersection(live.map(\.id))
        let feedRules = rules[feedID] ?? EpisodeMatchRules()
        let candidates = model.feedsEpisodes.filter { episode in
            guard episode.feedID == feedID, episode.removalKind == nil, !episode.isPlayed else { return false }
            // A rule decides its own episodes; only the rest reach the planner.
            guard case .noMatch? = try? feedRules.evaluate(
                .init(id: episode.id, title: episode.title, notes: episode.notes ?? "")
            ) else { return false }
            return true
        }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return FeedAdmissionPlanner.plan(
            candidates: candidates.map { .init(id: $0.id, releaseDate: $0.releasedAt) },
            keptEpisodeIDs: kept, playingEpisodeID: nil, partHeardEpisodeIDs: [],
            manualDecisions: [:], policy: policy
        ).filter { $0.outcome == .wait }.compactMap { byID[$0.candidate.id] }
    }

    /// The IDs waiting for space across every loaded feed.
    var waitingEpisodeIDs: Set<String> {
        Set(policies.keys.flatMap { waitingEpisodes(forFeed: $0).map(\.id) })
    }
}

// MARK: - Feed row control

/// The gear on a subscription row and the popover it opens.
struct WiltedMacFeedPolicyButton: View {
    let board: WiltedMacFeedPolicyBoard
    let subscription: WiltedMacSubscription
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false

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
            WiltedMacFeedPolicyContent(board: board, subscription: subscription, dismiss: { isPresented = false })
                .padding(WiltedTheme.Spacing.large)
                .background(WiltedTheme.color(.card, scheme: colorScheme))
        }
    }
}

// MARK: - Popover content

/// The four per-feed choices and what they resolve to right now.
struct WiltedMacFeedPolicyContent: View {
    let board: WiltedMacFeedPolicyBoard
    let subscription: WiltedMacSubscription
    var dismiss: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @State private var limitIsRejected = false
    @State private var showsRules = false

    private var feedID: String { subscription.id }
    private var policy: FeedAutomationPolicy { board.policy(for: feedID) }

    var body: some View {
        Group {
            if showsRules {
                WiltedMacFeedRulesView(
                    editor: board.rulesEditor(for: feedID), subscription: subscription,
                    resolved: board.resolved(for: feedID), back: { showsRules = false }, dismiss: dismiss
                )
            } else {
                settingsPage
            }
        }
        .frame(width: WiltedMacFeedRulesView.width)
    }

    private var settingsPage: some View {
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
                overrideRow(
                    "Auto download", label: "Auto download for \(subscription.title)",
                    identifier: "wilted-feed-policy-auto-download",
                    selection: overrideBinding(\.autoDownload) { board.update(feedID, autoDownload: $0) }
                )
                overrideRow(
                    "Auto prepare", label: "Auto prepare for \(subscription.title)",
                    identifier: "wilted-feed-policy-auto-prepare",
                    selection: overrideBinding(\.autoPrepare) { board.update(feedID, autoPrepare: $0) }
                )
                keptLimitRows
            }
            .disabled(!board.isLoaded(feedID))
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
                open: { showsRules = true }
            )
            Divider()
            Text("A lower limit never removes an episode already in Larder.")
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

extension WiltedMacFeedPolicyBoard {
    /// How many of the feed's episodes are kept in Larder right now.
    func keptCount(forFeed feedID: String) -> Int {
        let queued = Set(model.podcastQueueIDs)
        return model.episodes.filter { $0.feedID == feedID && $0.removalKind == nil && queued.contains($0.id) }.count
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
