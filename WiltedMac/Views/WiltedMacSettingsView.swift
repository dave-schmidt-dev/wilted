import AppKit
import SwiftUI
import WiltedDomain
import WiltedProducer

enum WiltedMacSettingsScrollCoordinateSpace {
    static let name = "wilted-settings-scroll-viewport"
}

private struct WiltedMacSettingsSectionPositionKey: PreferenceKey {
    static let defaultValue: [WiltedMacSettingsSection: CGFloat] = [:]

    static func reduce(value: inout [WiltedMacSettingsSection: CGFloat],
                       nextValue: () -> [WiltedMacSettingsSection: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

// MARK: - Settings

/// Sync used to sit inside Library, above the article composer, which is both
/// the wrong altitude and out of step with the listener, where the same facts
/// live in Settings.
struct WiltedMacSettingsView: View {
    let model: WiltedMacModel
    /// The one provider Settings reads; the model owns it (see `WiltedMacBulletinHub`).
    let location: WiltedLocationProvider
    @Environment(\.colorScheme) private var colorScheme
    @State private var choosesCustomMetadataCount = false
    /// Read by the preparation worker at each launch (see `WorkerPriority`).
    @AppStorage(WorkerPriority.userSettingKey) private var processesInBackground = true
    @State var feedPolicyBoard: WiltedMacFeedPolicyBoard
    @State private var scrollTarget: WiltedMacSettingsSection?
    @State private var sectionChangedByScroll: WiltedMacSettingsSection?

    init(
        model: WiltedMacModel,
        location: WiltedLocationProvider? = nil,
        policyBoard: WiltedMacFeedPolicyBoard? = nil
    ) {
        self.model = model
        self.location = location ?? model.bulletinHub.location
        _feedPolicyBoard = State(initialValue: policyBoard ?? WiltedMacFeedPolicyBoard(model: model))
        let savedAnchor = model.scrollAnchor(for: .settings).wrappedValue
        _scrollTarget = State(initialValue: savedAnchor == nil ? nil : model.settingsSection)
    }

    var body: some View {
        ScrollViewReader { reader in
            VStack(spacing: 0) {
                settingsTabs { tab in
                    model.settingsSection = tab.sections[0]
                }
                GeometryReader { viewport in
                    WiltedMacDestination(
                        title: WiltedScreenCopy.settings,
                        identifier: "wilted-mac-settings",
                        watermark: true,
                        scrollCoordinateSpaceName: WiltedMacSettingsScrollCoordinateSpace.name
                    ) {
                        settingsContent(viewportHeight: viewport.size.height)
                    }
                    .onAppear {
                        if let scrollTarget {
                            reader.scrollTo(scrollTarget.rawValue, anchor: .top)
                        }
                    }
                    .onChange(of: model.settingsSection) { _, section in
                        if sectionChangedByScroll == section {
                            sectionChangedByScroll = nil
                            return
                        }
                        scrollTarget = section
                        reader.scrollTo(section.rawValue, anchor: .top)
                    }
                    .onPreferenceChange(WiltedMacSettingsSectionPositionKey.self) { positions in
                        let sections = WiltedMacSettingsTab.allCases.flatMap(\.sections)
                        if let scrollTarget {
                            guard (positions[scrollTarget] ?? .greatestFiniteMagnitude) <= 1 else { return }
                            self.scrollTarget = nil
                        }
                        if let current = sections.last(where: {
                            // Match the target-arrival tolerance. A sub-point positive
                            // offset is visually at the top and should not clear the
                            // saved anchor as if the user returned to the page title.
                            (positions[$0] ?? .greatestFiniteMagnitude) <= 1
                        }) {
                            let savedAnchor = model.scrollAnchor(for: .settings).wrappedValue
                            guard savedAnchor != current.rawValue else { return }
                            sectionChangedByScroll = current
                            model.settingsSection = current
                        } else if model.scrollAnchor(for: .settings).wrappedValue != nil {
                            sectionChangedByScroll = .general
                            model.persistSettingsScrollPosition("destination-top")
                        }
                    }
                }
            }
        }
    }

    private func settingsTabs(select: @escaping (WiltedMacSettingsTab) -> Void) -> some View {
        HStack(spacing: WiltedTheme.Spacing.xSmall) {
            ForEach(WiltedMacSettingsTab.allCases) { tab in
                Button {
                    select(tab)
                } label: {
                    Text(tab.title)
                        .wiltedFont(.utility)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, WiltedTheme.Spacing.xSmall)
                        .padding(.vertical, WiltedTheme.Spacing.small)
                        .background {
                            if model.settingsTab == tab {
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.16))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.settingsTab == tab ? .isSelected : [])
                .accessibilityIdentifier("wilted-settings-tab-\(tab.id)")
            }
        }
        .padding(.horizontal, WiltedTheme.Spacing.small)
        .padding(.vertical, WiltedTheme.Spacing.xSmall)
    }

    @ViewBuilder private func settingsContent(viewportHeight: CGFloat) -> some View {
        ForEach(WiltedMacSettingsTab.allCases.flatMap(\.sections)) { section in
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                if section != .reports {
                    Text(section.title)
                        .wiltedFont(.body)
                        .fontWeight(.semibold)
                }
                settingsSectionContent(for: section)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-settings-section-\(section.rawValue)")
            .padding(.bottom, WiltedTheme.Spacing.xLarge)
            // A short final section still needs enough scroll range to put its heading at the top.
            .frame(minHeight: section == .about ? viewportHeight : nil,
                   alignment: .topLeading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WiltedMacSettingsSectionPositionKey.self,
                        value: [section: proxy.frame(
                            in: .named(WiltedMacSettingsScrollCoordinateSpace.name)).minY]
                    )
                }
            }
            .id(section.rawValue)
        }
    }

    /// The Mac inherits no text size from the system the way iPhone does, so
    /// this is the only place the reader can change it.
    var appearanceCard: some View {
        WiltedSettingsCard(title: "Appearance") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Picker("Text and icon size", selection: Binding(
                    get: { model.textScale },
                    set: { model.setTextScale($0) }
                )) {
                    ForEach(WiltedTheme.TextScale.allCases) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wilted-text-scale")
                Toggle("Show counts in the sidebar", isOn: Binding(
                    get: { model.showsSidebarCounts },
                    set: { model.showsSidebarCounts = $0 }
                ))
                    .accessibilityIdentifier("wilted-sidebar-counts")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-appearance-controls")
        .overlay(alignment: .topTrailing) {
            WiltedMacHelpButton(content: appearanceHelp, identifier: "wilted-appearance-help")
                .padding(WiltedTheme.Spacing.medium)
        }
    }

    var appearanceHelp: WiltedMacHelpContent {
        WiltedMacHelpContent(title: "Appearance", text: "Applies to every screen. Icons and artwork grow with the text. "
            + "Sidebar counts number the episodes ready to play beside Larder and the episodes still to decide beside Feeds.")
    }

    var automationHelp: WiltedMacHelpContent {
        WiltedMacHelpContent(title: "Larder automation", text:
            "An episode joins Larder when it finishes preparing. Episodes already played, already queued, or now playing are left alone. "
            + "Both overrides stay on until you turn them off, and each takes the same step the matching Larder group action takes. Downloads cost disk and bandwidth; preparing spends the machine's speech and detection models.")
    }

    /// Automation follows the path an admitted episode actually takes. The
    /// quiet rules make that sequence scannable without introducing another
    /// settings surface or a decorative treatment competing with the cards.
    var automationCard: some View {
        WiltedSettingsCard(title: "Automation") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                WiltedSettingsRow(
                    "Status",
                    value: model.automationStatus.settingsStatusText,
                    identifier: "wilted-automation-status"
                )
                if model.automationStatus.isCancellable {
                    Button("Stop") { model.cancelAutomation() }
                        .accessibilityIdentifier("wilted-automation-stop")
                }

                Divider()

                automationSectionTitle("Feeds")
                Picker("Refresh feeds", selection: refreshPolicyBinding) {
                    Text(WiltedAutomationRefreshPolicy.manual.settingsControlLabel)
                        .tag(WiltedAutomationRefreshPolicy.manual.settingsControlLabel)
                    Text(WiltedAutomationRefreshPolicy.onLaunch.settingsControlLabel)
                        .tag(WiltedAutomationRefreshPolicy.onLaunch.settingsControlLabel)
                    ForEach([6, 12, 24], id: \.self) { hours in
                        let policy = WiltedAutomationRefreshPolicy.whileOpen(everyHours: hours)
                        Text(policy.settingsControlLabel).tag(policy.settingsControlLabel)
                    }
                }
                .accessibilityIdentifier("wilted-automation-refresh-policy")
                Text("Manual waits for Refresh. On launch checks when Wilted opens; while-open schedules repeat only while it stays open.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-automation-refresh-policy-explanation")

                Picker("Episodes to list when adding a feed", selection: initialMetadataPreset) {
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("Custom").tag(0)
                }
                .accessibilityIdentifier("wilted-automation-initial-metadata-count")
                if initialMetadataPreset.wrappedValue == 0 {
                    TextField("Custom episodes (1–100)", value: initialMetadataCountBinding, format: .number)
                        .frame(width: 120)
                        .accessibilityIdentifier("wilted-automation-initial-metadata-custom")
                }
                Text("Titles and notes only; audio follows your download settings.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))

                Divider()

                HStack {
                    automationSectionTitle("Larder")
                    WiltedMacHelpButton(content: automationHelp, identifier: "wilted-automation-larder-overrides-explanation")
                    Spacer()
                }
                Toggle("Add prepared episodes to Larder", isOn: autoAddPreparedToLarderBinding)
                    .accessibilityIdentifier("wilted-automation-auto-add-to-larder")
                Toggle("Download everything in Larder", isOn: downloadEverythingBinding)
                    .accessibilityIdentifier("wilted-automation-download-everything")
                Toggle("Prepare everything downloaded", isOn: prepareEverythingBinding)
                    .accessibilityIdentifier("wilted-automation-prepare-everything")
                Divider()

                automationSectionTitle("Feed defaults")
                WiltedMacGlobalFeedDefaultsControls(model: model)
                Text("Same as default follows these values. Change a show on its Show settings page.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-automation-feed-defaults-explanation")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-automation-controls")
    }

    var preparingCard: some View {
        WiltedSettingsCard(title: "Processing") {
            Picker("Prepare episodes", selection: processingPolicyBinding) {
                Text(WiltedAutomationProcessingPolicy.immediate.settingsControlLabel)
                    .tag(WiltedAutomationProcessingPolicy.immediate.settingsControlLabel)
                Text(WiltedAutomationProcessingPolicy.manual.settingsControlLabel)
                    .tag(WiltedAutomationProcessingPolicy.manual.settingsControlLabel)
                Text(WiltedAutomationProcessingPolicy.offPeak(defaultOffPeakWindow).settingsControlLabel)
                    .tag(WiltedAutomationProcessingPolicy.offPeak(defaultOffPeakWindow).settingsControlLabel)
            }
            .accessibilityIdentifier("wilted-automation-processing-policy")
            Text("Immediately starts downloaded episodes as they arrive. Manual waits for Prepare; Off-peak waits for the local-time window below.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-automation-processing-policy-explanation")

            if isOffPeakProcessing {
                DatePicker("Start", selection: offPeakStartBinding, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("wilted-automation-off-peak-start")
                DatePicker("End", selection: offPeakEndBinding, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("wilted-automation-off-peak-end")
                Text("Uses local time. The window may continue overnight.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-automation-off-peak-explanation")
            }

            Toggle("Prepare in the background", isOn: $processesInBackground)
                .accessibilityIdentifier("wilted-processing-low-priority")
            Text("Gives preparation a low priority so it doesn't slow down the rest of your Mac. Playback is unaffected. Applies from the next preparation.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Level voices", isOn: levelVoicesBinding)
                .accessibilityIdentifier("wilted-automation-level-voices")
            Text("Brings quiet and loud voices closer together. Adds preparation time for new episodes. You can choose a different setting for each show.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            automationSectionTitle("Transcript")
            Picker("Transcript source", selection: transcriptPolicyBinding) {
                ForEach([
                    WiltedAutomationTranscriptPolicy.bestAvailable,
                    .alwaysTranscribe,
                    .noLocalSTT
                ], id: \.rawValue) { policy in
                    Text(policy.settingsControlLabel).tag(policy.settingsControlLabel)
                }
            }
            .accessibilityIdentifier("wilted-automation-transcript-policy")
            Text(model.automationSettings.transcriptPolicyExplanation)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-automation-transcript-explanation")
        }
    }

    var adRemovalCard: some View {
        WiltedSettingsCard(title: "Automation") {
            Toggle("Remove ads", isOn: removeAdsBinding)
                .accessibilityIdentifier("wilted-automation-remove-ads")
            Text("Applies to newly prepared episodes when this show is selected for ad finding.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-automation-remove-ads-explanation")
            Toggle("Chime where an ad was removed", isOn: Binding(
                get: { model.marksRemovedAds }, set: { model.marksRemovedAds = $0 }
            ))
                .accessibilityIdentifier("wilted-automation-ad-marker")
                .help("Plays a short, quiet tone at each spot an advertisement was cut. Takes effect immediately; nothing is re-prepared.")
        }
    }

    private func automationSectionTitle(_ title: String) -> some View {
        Text(title)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
    }

    private var refreshPolicyBinding: Binding<String> {
        Binding(
            get: { model.automationSettings.refreshPolicy.settingsControlLabel },
            set: { label in
                guard let policy = WiltedAutomationRefreshPolicy.fromSettingsControlLabel(label) else { return }
                replaceAutomationSettings(refreshPolicy: policy)
            }
        )
    }

    private var initialMetadataPreset: Binding<Int> {
        Binding(
            get: {
                let count = initialMetadataCountBinding.wrappedValue
                return choosesCustomMetadataCount || ![5, 10].contains(count) ? 0 : count
            },
            set: { preset in
                choosesCustomMetadataCount = preset == 0
                if preset != 0 { initialMetadataCountBinding.wrappedValue = preset }
            }
        )
    }

    private var initialMetadataCountBinding: Binding<Int> {
        Binding(
            get: { model.automationSettings.initialEpisodeMetadataCount },
            set: { value in
                guard WiltedAutomationSettings.validInitialEpisodeMetadataCount(value) != nil else { return }
                replaceAutomationSettings(initialEpisodeMetadataCount: value)
            }
        )
    }

    private var downloadPolicyBinding: Binding<String> {
        Binding(
            get: { model.automationSettings.downloadPolicy.settingsControlLabel },
            set: { label in
                guard let policy = WiltedAutomationDownloadPolicy.fromSettingsControlLabel(label) else { return }
                replaceAutomationSettings(downloadPolicy: policy)
            }
        )
    }

    private var processingPolicyBinding: Binding<String> {
        Binding(
            get: { model.automationSettings.processingPolicy.settingsControlLabel },
            set: { label in
                guard let policy = WiltedAutomationProcessingPolicy.fromSettingsControlLabel(
                    label, window: selectedOffPeakWindow
                ) else { return }
                replaceAutomationSettings(processingPolicy: policy)
            }
        )
    }

    private var transcriptPolicyBinding: Binding<String> {
        Binding(
            get: { model.automationSettings.transcriptPolicy.settingsControlLabel },
            set: { label in
                guard let policy = WiltedAutomationTranscriptPolicy.fromSettingsControlLabel(label) else { return }
                replaceAutomationSettings(transcriptPolicy: policy)
            }
        )
    }

    private var removeAdsBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.removeAds }, set: { replaceAutomationSettings(removeAds: $0) })
    }

    private var levelVoicesBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.levelVoices },
                set: { replaceAutomationSettings(levelVoices: $0) })
    }

    private var autoAddPreparedToLarderBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.autoAddPreparedToLarder },
                set: { replaceAutomationSettings(autoAddPreparedToLarder: $0) })
    }

    private var downloadEverythingBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.downloadEverythingOnLarder },
                set: { replaceAutomationSettings(downloadEverythingOnLarder: $0) })
    }

    private var prepareEverythingBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.prepareEverythingDownloaded },
                set: { replaceAutomationSettings(prepareEverythingDownloaded: $0) })
    }

    private var defaultOffPeakWindow: WiltedAutomationOffPeakWindow {
        let start = WiltedAutomationLocalTime(hour: 22, minute: 0)!
        let end = WiltedAutomationLocalTime(hour: 6, minute: 0)!
        return WiltedAutomationOffPeakWindow(start: start, end: end)!
    }

    private var selectedOffPeakWindow: WiltedAutomationOffPeakWindow {
        if case let .offPeak(window) = model.automationSettings.processingPolicy { return window }
        return defaultOffPeakWindow
    }

    private var isOffPeakProcessing: Bool {
        if case .offPeak = model.automationSettings.processingPolicy { return true }
        return false
    }

    private var offPeakStartBinding: Binding<Date> {
        localTimeBinding(\.start)
    }

    private var offPeakEndBinding: Binding<Date> {
        localTimeBinding(\.end)
    }

    private func localTimeBinding(_ keyPath: KeyPath<WiltedAutomationOffPeakWindow, WiltedAutomationLocalTime>) -> Binding<Date> {
        Binding(
            get: {
                let time = selectedOffPeakWindow[keyPath: keyPath]
                return Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? .now
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                guard let hour = components.hour, let minute = components.minute,
                      let replacement = WiltedAutomationLocalTime(hour: hour, minute: minute) else { return }
                let window = selectedOffPeakWindow
                let start = keyPath == \.start ? replacement : window.start
                let end = keyPath == \.end ? replacement : window.end
                guard let updatedWindow = WiltedAutomationOffPeakWindow(start: start, end: end) else { return }
                replaceAutomationSettings(processingPolicy: .offPeak(updatedWindow))
            }
        )
    }

    private func replaceAutomationSettings(
        refreshPolicy: WiltedAutomationRefreshPolicy? = nil,
        downloadPolicy: WiltedAutomationDownloadPolicy? = nil,
        processingPolicy: WiltedAutomationProcessingPolicy? = nil,
        transcriptPolicy: WiltedAutomationTranscriptPolicy? = nil,
        removeAds: Bool? = nil,
        levelVoices: Bool? = nil,
        autoAddPreparedToLarder: Bool? = nil,
        downloadEverythingOnLarder: Bool? = nil,
        prepareEverythingDownloaded: Bool? = nil,
        initialEpisodeMetadataCount: Int? = nil
    ) {
        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: refreshPolicy ?? settings.refreshPolicy,
                downloadPolicy: downloadPolicy ?? settings.downloadPolicy,
                processingPolicy: processingPolicy ?? settings.processingPolicy,
                transcriptPolicy: transcriptPolicy ?? settings.transcriptPolicy,
                removeAds: removeAds ?? settings.removeAds,
                levelVoices: levelVoices ?? settings.levelVoices,
                autoAddPreparedToLarder: autoAddPreparedToLarder ?? settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: downloadEverythingOnLarder ?? settings.downloadEverythingOnLarder,
                prepareEverythingDownloaded: prepareEverythingDownloaded ?? settings.prepareEverythingDownloaded,
                initialEpisodeMetadataCount: initialEpisodeMetadataCount ?? settings.initialEpisodeMetadataCount,
                autoKeepNewEpisodes: settings.autoKeepNewEpisodes,
                keptLimitPerFeed: settings.keptLimitPerFeed
            ).carryingReports(of: settings)
        }
    }

    /// The library publisher's card, or its not-running state when no engine is selected.
    @ViewBuilder var syncCard: some View {
        WiltedMacLibrarySyncCard(model: model)
    }
}
