import SwiftUI
import WiltedDomain
import WiltedProducer

/// One place to inspect and change a followed show's settings.
struct WiltedMacShowSettingsView: View {
    enum Section: CaseIterable, Hashable {
        case newEpisodes, ads, type, details
    }

    let model: WiltedMacModel
    let board: WiltedMacFeedPolicyBoard
    let subscription: WiltedMacSubscription

    @Environment(\.colorScheme) private var colorScheme
    @State private var isEditingRules = false
    @State private var renameInteraction = WiltedMacFeedRenameInteraction()
    @FocusState private var isNameFocused: Bool
    @State private var limitIsRejected = false

    private var feedID: String { subscription.id }
    private var policy: FeedAutomationPolicy { board.policy(for: feedID) }
    private var isArticle: Bool {
        board.isLoaded(feedID)
            ? board.isArticleFeed(feedID)
            : WiltedMacFeedKind.isArticleSubscription(subscription)
    }

    var body: some View {
        WiltedMacDestination(
            title: renameInteraction.drafts[feedID] == nil ? subscription.title : "Rename show",
            identifier: "wilted-show-settings-page-\(feedID)",
            contentWidth: 800,
            titleAccessory: { renameTitleAccessory }
        ) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                changesSummary
                loadStatus
                if board.failedFeedIDs.contains(feedID) {
                    Text("Could not save this change. The stored setting is shown.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-feed-policy-failed")
                }
                ForEach(Section.allCases, id: \.self) { section in
                    sectionContent(section)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 620)
        .task {
            board.refreshAdPreferences()
            if !board.isLoaded(feedID), !board.isLoading { await board.reload() }
        }
        .sheet(isPresented: $isEditingRules) {
            WiltedMacFeedRulesView(
                editor: board.rulesEditor(for: feedID), subscription: subscription,
                resolved: board.resolved(for: feedID), dismiss: { isEditingRules = false }
            )
        }
    }

    @ViewBuilder func sectionContent(_ section: Section) -> some View {
        switch section {
        case .newEpisodes: newEpisodesSection
        case .ads: adsSection
        case .type: typeSection
        case .details:
            settingsSection("Details", identifier: "details") {
                WiltedMacFeedDetailsSection(model: model, subscription: subscription)
            }
        }
    }

    @ViewBuilder private var renameTitleAccessory: some View {
        if let draft = renameInteraction.drafts[feedID] {
            TextField("Show name", text: Binding(
                get: { renameInteraction.drafts[feedID]?.text ?? draft.text },
                set: { renameInteraction.update(feedID, text: $0) }
            ))
            .wiltedFont(.body)
            .textFieldStyle(.roundedBorder)
            .frame(width: 260)
            .focused($isNameFocused)
            .onAppear { isNameFocused = true }
            .onSubmit(submitRename)
            .onExitCommand(perform: cancelRename)
            .accessibilityLabel("Name for \(subscription.publisherTitle ?? subscription.title)")
            .accessibilityIdentifier("wilted-show-settings-name-editor")
            Button("Save", action: submitRename)
                .keyboardShortcut(.defaultAction)
            Button("Cancel", action: cancelRename)
                .keyboardShortcut(.cancelAction)
            if let error = draft.error {
                Text(error).wiltedFont(.utility).foregroundStyle(.red)
            }
        } else {
            Button(action: beginRename) {
                Image(systemName: "pencil")
                    .accessibilityHidden(true)
                    .frame(minWidth: 24, minHeight: 24)
            }
            .buttonStyle(.borderless)
            .help("Rename show")
            .disabled(model.isFeedWritePending(feedID))
            .accessibilityLabel("Rename \(subscription.title)")
            .accessibilityIdentifier("wilted-show-settings-rename")
        }
    }

    @ViewBuilder private var changesSummary: some View {
        if board.isLoaded(feedID) {
            WiltedMacShowSettingsResetControl(board: board, feedID: feedID)
        }
    }

    @ViewBuilder var loadStatus: some View {
        if let failure = board.loadFailureMessage {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .wiltedFont(.utility)
                    .foregroundStyle(.red)
                Button("Retry settings") { Task { await board.retryReload() } }
                    .disabled(!board.canRetry)
                    .accessibilityIdentifier("wilted-show-settings-retry")
            }
            .accessibilityIdentifier("wilted-show-settings-load-error")
        } else if !board.isLoaded(feedID) {
            HStack(spacing: WiltedTheme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text("Loading saved settings…").wiltedFont(.utility)
            }
            .accessibilityIdentifier("wilted-show-settings-loading")
        }
    }

    @ViewBuilder private var newEpisodesSection: some View {
        if board.isLoaded(feedID), !(isArticle && board.isNews(feedID)) {
            settingsSection("New episodes", identifier: "new-episodes") {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                    automationRow(
                        "Auto keep", setting: .autoKeep, identifier: "wilted-feed-policy-auto-keep",
                        label: "Auto keep for \(subscription.title)", keyPath: \.autoKeep,
                        update: { board.update(feedID, autoKeep: $0) }
                    )
                    if !isArticle {
                        automationRow(
                            "Auto download", setting: .autoDownload, identifier: "wilted-feed-policy-auto-download",
                            label: "Auto download for \(subscription.title)", keyPath: \.autoDownload,
                            update: { board.update(feedID, autoDownload: $0) }
                        )
                    }
                    automationRow(
                        "Auto prepare", setting: .autoPrepare, identifier: "wilted-feed-policy-auto-prepare",
                        label: "Auto prepare for \(subscription.title)", keyPath: \.autoPrepare,
                        update: { board.update(feedID, autoPrepare: $0) }
                    )
                    keptLimitRow
                    if !isArticle { startOffsetRow }
                    WiltedMacFeedRulesEntry(
                        editor: board.rulesEditor(for: feedID), subscription: subscription,
                        isEnabled: board.isLoaded(feedID), open: { isEditingRules = true }
                    )
                    if policy.autoPrepare == .on
                        && model.automationSettings.processingPolicy == .manual
                        && !model.automationSettings.prepareEverythingDownloaded {
                        Text(
                            "Processing is set to Manual in Settings, so episodes will not prepare automatically. "
                            + "Choose Immediately or Off-peak in Settings, or turn on Prepare everything downloaded."
                        )
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-feed-policy-auto-prepare-blocked")
                    }
                    if limitIsRejected {
                        Text("Enter a whole number of at least 1.")
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .accessibilityIdentifier("wilted-feed-policy-limit-error")
                    }
                    Text("A lower limit never removes \(isArticle ? "an article" : "an episode") already in Larder.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var adsSection: some View {
        if board.isLoaded(feedID), !isArticle {
            settingsSection("Ads", identifier: "ads") {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                    removeAdsRow
                    restoreCutEpisodesRow
                    selfPromotionRow
                    sendForAdFindingRow
                }
            }
        }
    }

    private var typeSection: some View {
        settingsSection("Type", identifier: "type") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                Text(isArticle ? "Articles" : "Podcast")
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                if isArticle && board.isLoaded(feedID) { newsRow }
            }
        }
    }

    private var newsRow: some View {
        settingRow("Headlines only", defaultValue: "Off", setting: .news, resetID: "news",
                   detail: "When on, posts from this feed leave the Keep/Skip inbox and supply headlines.") {
            Toggle("Headlines only", isOn: Binding(
                get: { board.isNews(feedID) }, set: { _ = board.setNews($0, for: feedID) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("Headlines only for \(subscription.title)")
            .accessibilityIdentifier("wilted-feed-policy-news")
        }
    }

    private var keptLimitRow: some View {
        settingRow("Kept limit", defaultValue: globalValue("Kept limit"), setting: .keptLimit, resetID: "kept-limit") {
            HStack(spacing: WiltedTheme.Spacing.small) {
                Picker("Kept limit", selection: limitModeBinding) {
                    Text("Same as default").tag(false)
                    Text("Set a limit").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
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

    private var startOffsetRow: some View {
        settingRow(
            "Start new episodes at", defaultValue: "0 seconds", setting: .startOffset,
            resetID: "start-offset",
            detail: "Only applies to a new episode. Saved progress always resumes where you left off."
        ) {
            VStack(alignment: .trailing, spacing: WiltedTheme.Spacing.xSmall) {
                Picker("Start new episodes at", selection: Binding(
                    get: { board.startOffsetSeconds(for: feedID) },
                    set: { board.scheduleStartOffsetEdit($0, for: feedID) }
                )) {
                    ForEach([0.0, 15, 30, 45, 60, 90, 120, 180, 300, 600], id: \.self) { seconds in
                        Text(seconds == 0 ? "Beginning" : "\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Start new episodes at for \(subscription.title)")
                .accessibilityIdentifier("wilted-show-settings-start-offset")
                .disabled(!board.canEditStartOffset(feedID))
                if !board.canEditStartOffset(feedID) {
                    Text("Read only until iCloud sync is available.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-show-settings-start-offset-read-only")
                }
                if board.showStartOffsetConflictFeedIDs.contains(feedID) {
                    Text("Changed on another device. Choose again to apply.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-show-settings-start-offset-conflict")
                }
            }
        }
    }

    private var removeAdsRow: some View {
        settingRow(
            "Remove ads", defaultValue: model.automationSettings.removeAds ? "On" : "Off",
            setting: .removeAds, resetID: "remove-ads"
        ) {
            Picker("Remove ads", selection: Binding(
                get: { board.isAdFree(feedID) }, set: { board.setRemoveAdsOverride($0, for: feedID) }
            )) {
                Text("Same as default").tag(false)
                Text("This show is already ad-free").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("Remove ads for \(subscription.title)")
            .accessibilityIdentifier("wilted-feed-policy-ad-free")
        }
    }

    @ViewBuilder private var restoreCutEpisodesRow: some View {
        WiltedMacRestoreCutEpisodesControl(board: board, feedID: feedID, showTitle: subscription.title)
    }

    private var selfPromotionRow: some View {
        settingRow(
            "Remove the show's own promotion", defaultValue: "Off", setting: .selfPromotion,
            resetID: "self-promotion",
            detail: "Also cut the show's sponsor roll call, ad-free or Patreon pitches, events and webinars."
        ) {
            Toggle("Remove the show's own promotion", isOn: Binding(
                get: { board.removesSelfPromotion(feedID) },
                set: { _ = board.setRemoveSelfPromotion($0, for: feedID) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("Remove the show's own promotion from \(subscription.title)")
            .accessibilityIdentifier("wilted-feed-policy-remove-self-promotion")
            .disabled(board.isAdFree(feedID))
        }
    }

    private var sendForAdFindingRow: some View {
        settingRow(
            "Send this show for ad finding", defaultValue: "Off", setting: .adFinding,
            resetID: "ad-finding"
        ) {
            HStack(alignment: .center, spacing: WiltedTheme.Spacing.large) {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    Text("When on, the selected service checks episode transcripts and the preparation removes the breaks chosen for this show. When off, ad checking is skipped.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(adRouteLine)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-feed-policy-ad-route")
                }
                Spacer(minLength: WiltedTheme.Spacing.large)
                Toggle("Send this show for ad finding", isOn: Binding(
                    get: { board.sendsForAdFinding(feedID) },
                    set: { _ = board.setSendForAdFinding($0, for: feedID) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Send \(subscription.title) for ad finding")
                .accessibilityIdentifier("wilted-feed-policy-send-for-ad-finding")
            }
        }
    }

    private var adRouteLine: String {
        return switch board.adRoute(for: feedID) {
        case .remote:
            "Selected for online ad finding"
        case .notSent(.switchOff):
            "Online ad finding is off"
        case .notSent(.noKey):
            "Selected service is not ready. Check Providers."
        case .notSent(.dailyCapReached):
            "Daily ad-check limit reached"
        case .notSent(.adRemovalOff):
            "Ad removal is off for this show"
        case .notSent(.notConfirmed):
            "Not selected for ad finding"
        }
    }

    private func automationRow(
        _ title: String,
        setting: WiltedMacShowSetting,
        identifier: String,
        label: String,
        keyPath: KeyPath<FeedAutomationPolicy, FeedAutomationOverride>,
        update: @escaping (FeedAutomationOverride) -> Bool
    ) -> some View {
        settingRow(title, defaultValue: globalValue(title), setting: setting, resetID: setting.rawValue) {
            Picker(title, selection: Binding(
                get: { policy[keyPath: keyPath] }, set: { _ = update($0) }
            )) {
                Text("Same as default").tag(FeedAutomationOverride.useGlobal)
                Text("On").tag(FeedAutomationOverride.on)
                Text("Off").tag(FeedAutomationOverride.off)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
        }
    }

    private func settingRow<Control: View>(
        _ title: String,
        defaultValue: String,
        setting: WiltedMacShowSetting,
        resetID: String,
        detail: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        WiltedMacShowSettingRow(
            title: title, defaultValue: defaultValue,
            detail: detail,
            isOverridden: board.isOverridden(setting, for: feedID),
            resetIdentifier: "wilted-show-settings-reset-\(resetID)",
            resetLabel: "Reset \(title) for \(subscription.title)",
            control: control(), reset: { board.reset(setting, for: feedID) }
        )
    }

    private func settingsSection<Content: View>(
        _ title: String, identifier: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(title).wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            content()
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-show-settings-section-\(identifier)")
    }

    private func globalValue(_ title: String) -> String {
        WiltedFeedAutomationSummary.globalRows(model.automationSettings)
            .first { $0.label == title }?.value ?? "Unknown"
    }

    private var limitModeBinding: Binding<Bool> {
        Binding(
            get: { if case .explicit = policy.keptLimit { true } else { false } },
            set: { wantsLimit in
                limitIsRejected = false
                if wantsLimit {
                    board.update(feedID, keptLimit: .explicit(max(1, board.keptCount(forFeed: feedID))))
                } else {
                    board.update(feedID, keptLimit: .useGlobal)
                }
            }
        )
    }

    private func limitBinding(current: Int) -> Binding<Int> {
        Binding(
            get: { current },
            set: { limitIsRejected = !board.update(feedID, keptLimit: .explicit($0)) }
        )
    }

    private func beginRename() {
        renameInteraction.begin(subscription)
        isNameFocused = true
    }

    private func cancelRename() {
        renameInteraction.cancel(feedID)
        isNameFocused = false
    }

    private func submitRename() {
        guard let name = renameInteraction.submit(feedID) else { return }
        isNameFocused = false
        Task {
            do {
                try await model.renameSubscription(subscription, to: name)
            } catch {
                renameInteraction.restoreFailure(
                    subscription, text: name,
                    error: "\(subscription.title) could not be renamed. Try again."
                )
                isNameFocused = true
            }
        }
    }
}
