import AppKit
import SwiftUI
import WiltedDomain

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
    @State var feedPolicyBoard: WiltedMacFeedPolicyBoard

    init(
        model: WiltedMacModel,
        location: WiltedLocationProvider? = nil,
        policyBoard: WiltedMacFeedPolicyBoard? = nil
    ) {
        self.model = model
        self.location = location ?? model.bulletinHub.location
        _feedPolicyBoard = State(initialValue: policyBoard ?? WiltedMacFeedPolicyBoard(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsTabs
            GeometryReader { viewport in
                let position = model.settingsScrollPosition
                let initialSection = position.wrappedValue.flatMap(WiltedMacSettingsSection.init(rawValue:))
                ScrollViewReader { reader in
                    WiltedMacDestination(
                        title: WiltedScreenCopy.settings,
                        identifier: "wilted-mac-settings",
                        watermark: true,
                        scrollAnchor: position
                    ) {
                        settingsTabContent(viewportHeight: viewport.size.height)
                    }
                    .onAppear {
                        if let initialSection {
                            reader.scrollTo(initialSection.rawValue, anchor: .top)
                        }
                    }
                }
                .id(model.settingsTab)
            }
        }
    }

    private var settingsTabs: some View {
        HStack(spacing: WiltedTheme.Spacing.xSmall) {
            ForEach(WiltedMacSettingsTab.allCases) { tab in
                Button {
                    model.settingsTab = tab
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

    @ViewBuilder private func settingsTabContent(viewportHeight: CGFloat) -> some View {
        ForEach(model.settingsTab.sections) { section in
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
            .frame(minHeight: section == model.settingsTab.sections.last ? viewportHeight : nil,
                   alignment: .topLeading)
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
            if model.automationSettings.transcriptPolicyBlocksAdRemoval {
                Text(WiltedAutomationSettings.transcriptPolicyBlocksAdRemovalExplanation)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-automation-transcript-conflict")
            }
        }
    }

    var adRemovalCard: some View {
        WiltedSettingsCard(title: "Automation") {
            Toggle("Remove ads", isOn: removeAdsBinding)
                .accessibilityIdentifier("wilted-automation-remove-ads")
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
