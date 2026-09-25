import AppKit
import SwiftUI
import WiltedDomain

// MARK: - Settings

/// Sync used to sit inside Library, above the article composer, which is both
/// the wrong altitude and out of step with the listener, where the same facts
/// live in Settings.
struct WiltedMacSettingsView: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WiltedMacDestination(title: WiltedScreenCopy.settings, identifier: "wilted-mac-settings") {
            appearanceCard
            lifetimeStatisticsCard
            automationCard
            syncCard
        }
    }

    private var lifetimeStatisticsCard: some View {
        WiltedSettingsCard(title: WiltedScreenCopy.lifetimeStatistics) {
            Text(WiltedScreenCopy.lifetimeStatisticsScope)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier(WiltedScreenCopy.lifetimeStatisticsScopeIdentifier)
            Divider()
            WiltedSettingsRow(
                WiltedScreenCopy.audioProcessed,
                value: WiltedDuration.spoken(model.lifetimeStatistics.audioProcessedSeconds),
                identifier: WiltedScreenCopy.audioProcessedIdentifier
            )
            Divider()
            WiltedSettingsRow(
                WiltedScreenCopy.speechGenerated,
                value: WiltedDuration.spoken(model.lifetimeStatistics.speechGeneratedSeconds),
                identifier: WiltedScreenCopy.speechGeneratedIdentifier
            )
            Divider()
            WiltedSettingsRow(
                WiltedScreenCopy.confirmedAdTimeRemoved,
                value: WiltedDuration.spoken(model.lifetimeStatistics.confirmedAdTimeRemovedSeconds),
                identifier: WiltedScreenCopy.confirmedAdTimeRemovedIdentifier
            )
            Divider()
            WiltedSettingsRow(
                WiltedScreenCopy.fasterPlaybackTimeSaved,
                value: WiltedDuration.spoken(model.lifetimeStatistics.fasterPlaybackTimeSavedSeconds),
                identifier: WiltedScreenCopy.fasterPlaybackTimeSavedIdentifier
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-lifetime-statistics")
    }

    /// The Mac inherits no text size from the system the way iPhone does, so
    /// this is the only place the reader can change it.
    private var appearanceCard: some View {
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
                Text("Applies to every screen. Icons and artwork grow with the text.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-appearance-controls")
    }

    /// Automation follows the path an admitted episode actually takes. The
    /// quiet rules make that sequence scannable without introducing another
    /// settings surface or a decorative treatment competing with the cards.
    private var automationCard: some View {
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

                Text("Refresh adds metadata only. Download and preparation begin after Keep moves an episode to Larder.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-automation-feeds-admission-policy")

                Divider()

                automationSectionTitle("Processing")
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
                Toggle("Remove ads", isOn: removeAdsBinding)
                    .accessibilityIdentifier("wilted-automation-remove-ads")
                Toggle("Chime where an ad was removed", isOn: Binding(
                    get: { model.marksRemovedAds }, set: { model.marksRemovedAds = $0 }
                ))
                    .accessibilityIdentifier("wilted-automation-ad-marker")
                    .help("Plays a short, quiet tone at each spot an advertisement was cut. Takes effect immediately; nothing is re-prepared.")
                if model.automationSettings.transcriptPolicyBlocksAdRemoval {
                    Text(WiltedAutomationSettings.transcriptPolicyBlocksAdRemovalExplanation)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-automation-transcript-conflict")
                }

                Divider()

                automationSectionTitle("Larder")
                Toggle("Add prepared episodes to Larder", isOn: autoAddPreparedToMenuBinding)
                    .accessibilityIdentifier("wilted-automation-auto-add-to-menu")
                Text("An episode joins Larder when it finishes preparing. Episodes already "
                     + "played, already queued, or now playing are left alone.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-automation-auto-add-to-menu-explanation")
                Toggle("Download everything in Larder", isOn: downloadEverythingBinding)
                    .accessibilityIdentifier("wilted-automation-download-everything")
                Toggle("Prepare everything downloaded", isOn: prepareEverythingBinding)
                    .accessibilityIdentifier("wilted-automation-prepare-everything")
                Text("Both overrides stay on until you turn them off, and each takes the same "
                     + "step the matching Larder group action takes. Downloads cost disk and "
                     + "bandwidth; preparing spends the machine's speech and detection models.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-automation-menu-overrides-explanation")

            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-automation-controls")
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

    private var autoAddPreparedToMenuBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.autoAddPreparedToMenu },
                set: { replaceAutomationSettings(autoAddPreparedToMenu: $0) })
    }

    private var downloadEverythingBinding: Binding<Bool> {
        Binding(get: { model.automationSettings.downloadEverythingOnMenu },
                set: { replaceAutomationSettings(downloadEverythingOnMenu: $0) })
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
        autoAddPreparedToMenu: Bool? = nil,
        downloadEverythingOnMenu: Bool? = nil,
        prepareEverythingDownloaded: Bool? = nil
    ) {
        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: refreshPolicy ?? settings.refreshPolicy,
                downloadPolicy: downloadPolicy ?? settings.downloadPolicy,
                processingPolicy: processingPolicy ?? settings.processingPolicy,
                transcriptPolicy: transcriptPolicy ?? settings.transcriptPolicy,
                removeAds: removeAds ?? settings.removeAds,
                autoAddPreparedToMenu: autoAddPreparedToMenu ?? settings.autoAddPreparedToMenu,
                downloadEverythingOnMenu: downloadEverythingOnMenu ?? settings.downloadEverythingOnMenu,
                prepareEverythingDownloaded: prepareEverythingDownloaded ?? settings.prepareEverythingDownloaded
            )
        }
    }

    private var syncCard: some View {
        WiltedSettingsCard(title: WiltedScreenCopy.sync) {
            WiltedSettingsRow(
                "Status",
                value: model.syncStatus.phase.rawValue.capitalized,
                identifier: "wilted-sync-status",
                tone: model.syncStatus.phase.tone
            )
            Divider()
            WiltedSettingsRow(
                "Detail",
                value: model.syncStatus.detail,
                identifier: "wilted-sync-detail"
            )
            Divider()
            WiltedSettingsRow(
                "Producer identity",
                value: model.syncObservability.producerIdentity.label,
                identifier: "wilted-sync-producer-identity"
            )
            Divider()
            WiltedSettingsRow("Last fetch", value: lastFetchLabel, identifier: "wilted-sync-last-fetch")
            Divider()
            WiltedSettingsRow("Last send", value: lastSendLabel, identifier: "wilted-sync-last-send")

            HStack(spacing: WiltedTheme.Spacing.small) {
                Button("Refresh") { model.refreshSync() }
                    .disabled(syncActionsDisabled)
                    .accessibilityIdentifier("wilted-sync-refresh")
                Button("Upload") { model.uploadPendingSync() }
                    .disabled(syncActionsDisabled)
                    .accessibilityIdentifier("wilted-sync-upload")
                if model.syncStatus.phase == .fetching
                    || model.syncStatus.phase == .sending
                    || model.syncStatus.phase == .staging {
                    Button("Cancel") { model.cancelSync() }
                        .accessibilityIdentifier("wilted-sync-cancel")
                }
            }
            .padding(.top, WiltedTheme.Spacing.xSmall)

            if model.syncStatus.phase == .quarantined {
                WiltedAccountRecoveryNotice(identifier: "wilted-sync-use-current-account") {
                    model.resetSyncAccount()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-sync-controls")
    }

    private var syncActionsDisabled: Bool {
        model.syncStatus.phase == .disabled || model.syncStatus.phase == .quarantined
    }

    private var lastFetchLabel: String {
        model.syncObservability.lastSuccessfulFetchAt
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet"
    }

    private var lastSendLabel: String {
        model.syncObservability.lastSuccessfulSendAt
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet"
    }
}
