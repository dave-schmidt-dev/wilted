import AppKit
import SwiftUI
import WiltedDomain

// MARK: - Settings

/// Sync used to sit inside Library, above the article composer, which is both
/// the wrong altitude and out of step with the listener, where the same facts
/// live in Settings.
struct WiltedMacSettingsView: View {
    let model: WiltedMacModel
    /// The one provider Settings reads. The app-level owner arrives with the Reports wiring (Task 3.2);
    /// until then Settings shares one process-wide instance so the permission prompt has a home.
    let location: WiltedLocationProvider
    @Environment(\.colorScheme) private var colorScheme
    @State private var choosesCustomMetadataCount = false

    @MainActor static let sharedLocation = WiltedLocationProvider(
        manager: WiltedCoreLocationManager(), wifi: WiltedCoreWLANPower())

    init(model: WiltedMacModel, location: WiltedLocationProvider = WiltedMacSettingsView.sharedLocation) {
        self.model = model
        self.location = location
    }

    var body: some View {
        WiltedMacDestination(
            title: WiltedScreenCopy.settings, identifier: "wilted-mac-settings", watermark: true,
            scrollAnchor: model.scrollAnchor(for: .settings)
        ) {
            appearanceCard.id("settings-appearance")
            WiltedMacLifetimeStatisticsCard(model: model).id("settings-statistics")
            automationCard.id("settings-automation")
            WiltedMacReportsCard(model: model, location: location).id("settings-reports")
            syncCard.id("settings-sync")
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
        WiltedMacHelpContent(title: "Appearance", text: "Applies to every screen. Icons and artwork grow with the text.")
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
                WiltedMacInheritedFeedDefaults(model: model)
                Text("Use global follows these defaults. Change one feed from Feed settings in Feeds.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-automation-feed-defaults-explanation")
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

    /// The selected engine's card: the library publisher never falls back to the legacy "Disabled".
    @ViewBuilder private var syncCard: some View {
        if model.showsLibraryPublisherSync {
            WiltedMacLibrarySyncCard(model: model)
        } else {
            legacySyncCard
        }
    }

    var legacySyncCard: some View {
        WiltedSettingsCard(title: WiltedScreenCopy.sync) {
            WiltedSettingsRow(
                "Status",
                value: model.syncStatus.phase.rawValue.capitalized,
                identifier: "wilted-sync-status",
                tone: model.syncStatus.phase.tone
            )
            if model.syncStatus.phase != .disabled {
                Divider()
                WiltedSettingsRow(
                    "Detail",
                    value: model.syncStatus.detail,
                    identifier: "wilted-sync-detail"
                )
            }
            Divider()
            WiltedSettingsRow("Last fetch", value: lastFetchLabel, identifier: "wilted-sync-last-fetch")
            Divider()
            WiltedSettingsRow("Last send", value: lastSendLabel, identifier: "wilted-sync-last-send")

            if !syncActionsDisabled {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Button("Refresh") { model.refreshSync() }
                        .accessibilityIdentifier("wilted-sync-refresh")
                    Button("Upload") { model.uploadPendingSync() }
                        .accessibilityIdentifier("wilted-sync-upload")
                    if model.syncStatus.phase == .fetching
                        || model.syncStatus.phase == .sending
                        || model.syncStatus.phase == .staging {
                        Button("Cancel") { model.cancelSync() }
                            .accessibilityIdentifier("wilted-sync-cancel")
                    }
                }
                .padding(.top, WiltedTheme.Spacing.xSmall)
            }

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

/// The library publisher's Sync card (Task 5.2): one status line, this Mac's own send and read
/// times, one Sync now, and the account review. Times are local; the phone reports its own fetch.
private struct WiltedMacLibrarySyncCard: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isReviewing = false

    var body: some View {
        let status = model.librarySyncStatus
        let activity = model.librarySyncActivity
        WiltedSettingsCard(title: WiltedScreenCopy.sync) {
            WiltedPublicationNotice(summary: model.libraryPublicationSummary, detail: model.libraryPublicationDetail,
                qualifier: model.libraryPublicationQualifier)
            WiltedSettingsRow("Status", value: status.headline, identifier: "wilted-sync-status", tone: status.tone)
            if let throttle = model.libraryThrottle {
                Divider()
                // The retry time while it is ahead, "Retrying now…" once it has passed (never a time
                // that has gone by); cleared by the next call that succeeds.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    WiltedSettingsRow(
                        "iCloud", value: throttle.noticeWithResumeTime(now: context.date, retrying: false),
                        identifier: "wilted-sync-throttle", tone: .caution)
                }
            }
            Divider()
            WiltedSettingsRow(
                "Sent from this Mac", value: WiltedMacLibrarySyncStatus.timeLabel(activity.lastSentAt),
                identifier: "wilted-sync-last-send")
            Divider()
            WiltedSettingsRow(
                "Phone changes read", value: WiltedMacLibrarySyncStatus.timeLabel(activity.lastCheckedAt),
                identifier: "wilted-sync-last-check")
            Text(WiltedMacLibrarySyncStatus.scopeNote)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-sync-scope-note")
            HStack(spacing: WiltedTheme.Spacing.small) {
                Button("Sync now") { model.syncLibraryNow() }
                    .disabled(!status.canSyncNow)
                    .accessibilityIdentifier("wilted-sync-now")
                if status.reviewContext != nil {
                    Button("Review account…") { isReviewing = true }
                        .accessibilityIdentifier("wilted-sync-review-account")
                }
            }
            .padding(.top, WiltedTheme.Spacing.xSmall)
        }
        .alert(WiltedMacLibrarySyncStatus.reviewTitle, isPresented: $isReviewing) {
            Button(WiltedMacLibrarySyncStatus.approveReview) { model.reviewLibraryAccount() }
                .accessibilityIdentifier("wilted-sync-review-approve")
            Button(WiltedMacLibrarySyncStatus.keepHeld, role: .cancel) {}
                .accessibilityIdentifier("wilted-sync-review-keep-held")
        } message: {
            Text("\(status.reviewContext ?? "") \(WiltedMacLibrarySyncStatus.reviewExplanation)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-sync-controls")
    }
}

// MARK: - Reports

/// Settings > Reports: spoken weather alerts and headlines at pause points, the daily report, and
/// the location that weather needs. Interruptions are off until the listener turns them on.
struct WiltedMacReportsCard: View {
    let model: WiltedMacModel
    let location: WiltedLocationProvider
    @Environment(\.colorScheme) private var colorScheme
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var contactText = ""
    @State private var coordinateProblem = false
    @State private var showsDetails: Bool

    /// The details start folded: interruptions are off by default, and the rest only matters once on.
    init(model: WiltedMacModel, location: WiltedLocationProvider, startsExpanded: Bool = false) {
        self.model = model
        self.location = location
        _showsDetails = State(initialValue: startsExpanded)
    }

    private var settings: WiltedAutomationSettings { model.automationSettings }

    var body: some View {
        WiltedSettingsCard(title: "Reports") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Toggle("Read bulletins while playing", isOn: reportsBinding(\.interruptionsEnabled))
                    .accessibilityIdentifier("wilted-reports-interruptions")
                DisclosureGroup(isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                        Toggle("Weather alerts", isOn: reportsBinding(\.alertsEnabled))
                            .disabled(!settings.interruptionsEnabled)
                            .accessibilityIdentifier("wilted-reports-alerts")
                        Toggle("Headlines", isOn: reportsBinding(\.headlinesEnabled))
                            .disabled(!settings.interruptionsEnabled)
                            .accessibilityIdentifier("wilted-reports-headlines")
                        Stepper(value: reportsBinding(\.waitLimitSeconds), in: WiltedAutomationSettings.waitLimitRange, step: 10) {
                            labeledValue("Wait for a break", "\(settings.waitLimitSeconds) seconds")
                        }
                        .disabled(!settings.interruptionsEnabled)
                        .accessibilityIdentifier("wilted-reports-wait-limit")
                        Stepper(value: reportsBinding(\.headlineMinimumGapMinutes),
                                in: WiltedAutomationSettings.headlineGapRange, step: 5) {
                            labeledValue("Between headlines", "\(settings.headlineMinimumGapMinutes) minutes")
                        }
                        .disabled(!settings.interruptionsEnabled)
                        .accessibilityIdentifier("wilted-reports-headline-gap")

                        Divider()

                        Toggle("Daily report", isOn: reportsBinding(\.reportEnabled))
                            .accessibilityIdentifier("wilted-reports-daily")
                        DatePicker("Report time", selection: reportTimeBinding, displayedComponents: .hourAndMinute)
                            .disabled(!settings.reportEnabled)
                            .accessibilityIdentifier("wilted-reports-time")

                        Divider()

                        locationSection

                        Divider()

                        LabeledContent("Weather service contact") {
                            TextField("Weather service contact", text: $contactText, prompt: Text("Email or web address"))
                                .labelsHidden()
                                .frame(maxWidth: 280)
                                .onSubmit(commitContact)
                                .accessibilityIdentifier("wilted-reports-nws-contact")
                        }
                    }
                    .padding(.top, WiltedTheme.Spacing.small)
                } label: {
                    Text("Alerts, headlines, daily report and location")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                .accessibilityIdentifier("wilted-reports-details")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-reports-controls")
        .overlay(alignment: .topTrailing) {
            WiltedMacHelpButton(content: Self.help, identifier: "wilted-reports-help")
                .padding(WiltedTheme.Spacing.medium)
        }
        .task {
            latitudeText = settings.typedLatitude.map(Self.decimal) ?? ""
            longitudeText = settings.typedLongitude.map(Self.decimal) ?? ""
            contactText = settings.nwsContact
            location.typedCoordinates = settings.typedCoordinates
        }
    }

    // MARK: Location

    @ViewBuilder private var locationSection: some View {
        WiltedSettingsRow(
            "Location", value: Self.statusText(location.status),
            identifier: "wilted-reports-location-status", tone: Self.tone(location.status))
        if location.detail != .usingTyped {
            note(Self.detailText(location.detail), id: "wilted-reports-location-detail")
        }
        locationButton
        LabeledContent("Latitude") {
            TextField("Latitude", text: $latitudeText, prompt: Text("38.90"))
                .labelsHidden()
                .frame(maxWidth: 140)
                .onSubmit(commitCoordinates)
                .accessibilityIdentifier("wilted-reports-latitude")
        }
        LabeledContent("Longitude") {
            TextField("Longitude", text: $longitudeText, prompt: Text("-77.04"))
                .labelsHidden()
                .frame(maxWidth: 140)
                .onSubmit(commitCoordinates)
                .accessibilityIdentifier("wilted-reports-longitude")
        }
        if coordinateProblem {
            Text("Latitude must be from -90 to 90 and longitude from -180 to 180.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-reports-coordinate-problem")
        }
    }

    @ViewBuilder private var locationButton: some View {
        switch location.authorization {
        case .notDetermined:
            Button("Allow location access") { location.requestPermission() }
                .accessibilityIdentifier("wilted-reports-location-allow")
        case .denied:
            Button("Open Location settings") { Self.openLocationSettings() }
                .accessibilityIdentifier("wilted-reports-location-open-settings")
        case .authorized:
            Button("Update location") { location.refresh() }
                .accessibilityIdentifier("wilted-reports-location-refresh")
        }
    }

    private func commitCoordinates() {
        let lat = latitudeText.trimmingCharacters(in: .whitespaces)
        let lon = longitudeText.trimmingCharacters(in: .whitespaces)
        if lat.isEmpty && lon.isEmpty {
            coordinateProblem = false
            setTyped(latitude: nil, longitude: nil)
        } else if let latitude = Double(lat), let longitude = Double(lon),
                  WiltedCoordinates(latitude: latitude, longitude: longitude) != nil {
            coordinateProblem = false
            setTyped(latitude: latitude, longitude: longitude)
        } else {
            coordinateProblem = true
            return
        }
        latitudeText = model.automationSettings.typedLatitude.map(Self.decimal) ?? ""
        longitudeText = model.automationSettings.typedLongitude.map(Self.decimal) ?? ""
    }

    private func setTyped(latitude: Double?, longitude: Double?) {
        model.updateAutomationSettings { current in
            current.updatingReports { $0.typedLatitude = latitude; $0.typedLongitude = longitude }
        }
        location.typedCoordinates = model.automationSettings.typedCoordinates
    }

    private func commitContact() {
        model.updateAutomationSettings { current in current.updatingReports { $0.nwsContact = contactText } }
        contactText = model.automationSettings.nwsContact
    }

    // MARK: Bindings and text

    private func reportsBinding<Value>(_ keyPath: WritableKeyPath<WiltedAutomationSettings.ReportsFields, Value>)
        -> Binding<Value> {
        Binding(
            get: { WiltedAutomationSettings.ReportsFields(model.automationSettings)[keyPath: keyPath] },
            set: { value in
                model.updateAutomationSettings { current in current.updatingReports { $0[keyPath: keyPath] = value } }
            })
    }

    private var reportTimeBinding: Binding<Date> {
        Binding(
            get: {
                let time = settings.reportTime
                return Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                guard let hour = parts.hour, let minute = parts.minute,
                      let time = WiltedAutomationLocalTime(hour: hour, minute: minute) else { return }
                model.updateAutomationSettings { current in current.updatingReports { $0.reportTime = time } }
            })
    }

    private func note(_ text: String, id: String) -> some View {
        Text(text)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: WiltedTheme.Spacing.large)
            Text(value).foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
    }

    static let help = WiltedMacHelpContent(title: "Reports", text:
        "Playback pauses at a natural break, reads the bulletin, then resumes. Interruptions are off until you turn them on. "
        + "Typed coordinates are used whenever this Mac has no location fix; press Return to save them, or clear both to remove. "
        + "The National Weather Service contact is sent with weather requests so the service can reach you; press Return to save it.")

    static func statusText(_ status: WiltedLocationStatus) -> String {
        switch status {
        case .none: "Not set up"
        case .denied: "Access off"
        case .noFix: "No fix"
        case .typed: "Typed coordinates"
        case .located: "Located"
        }
    }

    static func tone(_ status: WiltedLocationStatus) -> WiltedStatusTone {
        switch status {
        case .located, .typed: .positive
        case .denied, .noFix: .caution
        case .none: .neutral
        }
    }

    static func detailText(_ detail: WiltedLocationDetail) -> String {
        switch detail {
        case .notRequested:
            "Weather needs a location. Allow access, or type coordinates below."
        case .permissionDenied:
            "Location access is off for Wilted. Allow it in System Settings, or type coordinates below."
        case .wifiOff:
            "Wi-Fi is off. This Mac finds its location from nearby Wi-Fi, so turn Wi-Fi on or type coordinates below."
        case .fixFailed:
            "No location fix yet. Try again, or type coordinates below."
        case .fixDiscardedWifiOff:
            "Wi-Fi turned off while locating, so the result was discarded. Turn Wi-Fi on or type coordinates below."
        case .usingTyped:
            "Using the coordinates you typed."
        case .fixAccepted:
            "Found from nearby Wi-Fi and rounded to about 1 km. Kept in memory only."
        }
    }

    private static func decimal(_ value: Double) -> String { String(format: "%g", value) }

    private static func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}
