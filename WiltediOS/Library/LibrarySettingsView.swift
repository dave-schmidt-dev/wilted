import SwiftUI
import UIKit
import WiltedDomain
import WiltedLibrary

/// The phone's Settings sheet, laid out like the Mac's: cards of labelled rows built from the
/// shared, model-free `WiltedSettingsCard` and `WiltedSettingsRow`. Opened from the Larder's gear.
struct LibrarySettingsView: View {
    @ObservedObject var settings: LibrarySettingsStore
    @ObservedObject var model: LibraryAppModel
    /// The entry playing now; its audio is never removed from under the player.
    let playingID: ItemID?
    let onDone: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(LibraryInterruptionPreferences.speakKey) private var speaksInterruptions = true
    @State private var cache = LibraryCacheSummary()
    @State private var isConfirmingRemoval = false
    @State private var removalNotice: String?
    @State private var showsSupportDetails = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xLarge) {
                    ForEach(LibrarySettingsSection.allCases, id: \.self) { section in
                        switch section {
                        case .general: generalCard
                        case .playback:
                            VStack(spacing: WiltedTheme.Spacing.xLarge) {
                                playbackCard
                                if !podcastSources.isEmpty { showStartOffsetsCard }
                            }
                        case .storage: storageCard
                        case .reports: LibrarySettingsBulletinsCard(model: model)
                        case .devices: devicesCard
                        case .about: aboutCard
                        }
                    }
                }
                .padding(WiltedTheme.Spacing.large)
            }
            .background(WiltedTheme.color(.page, scheme: colorScheme))
            .overlay { LibraryWatermark() }
            .refreshable { await model.pullToRefresh() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(WiltedScreenCopy.settings).wiltedFont(.title)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onDone) { Text("Done").wiltedFont(.body) }
                        .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .accessibilityIdentifier("wilted-library-settings-done")
                }
            }
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        .task { await reloadCache() }
        // A refresh can add or drop cached audio (an account change clears it).
        .onChange(of: model.isRefreshing) { _, running in
            if !running { Task { await reloadCache() } }
        }
        .accessibilityIdentifier("wilted-library-settings")
    }

    // MARK: Cards

    private var generalCard: some View {
        WiltedSettingsCard(title: LibrarySettingsSection.general.title) {
            iconRow("textformat.size", "Text and icon size") { EmptyView() }
            segmented(selection: $settings.textScale, identifier: "wilted-library-settings-text-scale")
            scopeNote(.general)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-appearance")
    }

    private var playbackCard: some View {
        WiltedSettingsCard(title: LibrarySettingsSection.playback.title) {
            Toggle("Auto-play next episode", isOn: $settings.autoPlayNext)
                .wiltedFont(.utility)
                .accessibilityIdentifier("wilted-library-settings-auto-play-next")
            Toggle(LibrarySettingsFormat.speakInterruptionsLabel(deviceKind: model.deviceKind), isOn: $speaksInterruptions)
                .wiltedFont(.utility)
                .accessibilityIdentifier("wilted-library-settings-speak-interruptions")
            iconRow("gauge.with.dots.needle.67percent", "Default speed") {
                Text(LibrarySettingsFormat.speed(settings.defaultSpeed)).wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .monospacedDigit()
                Stepper(
                    "Default speed", value: $settings.defaultSpeed, in: PlaybackSpeeds.range,
                    step: PlaybackSpeeds.step)
                    .labelsHidden()
            }
            .accessibilityElement(children: .contain)
            .accessibilityValue(LibrarySettingsFormat.speed(settings.defaultSpeed))
            .accessibilityIdentifier("wilted-library-settings-speed")
            HStack(spacing: WiltedTheme.Spacing.medium) {
                skipMenu(
                    "Rewind", selection: $settings.skipBackSeconds, symbol: "gobackward", leading: true,
                    identifier: "wilted-library-settings-skip-back")
                skipMenu(
                    "Fast forward", selection: $settings.skipForwardSeconds, symbol: "goforward", leading: false,
                    identifier: "wilted-library-settings-skip-forward")
            }
            scopeNote(.playback)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-playback")
    }

    private var podcastSources: [LibrarySource] {
        model.decisionContent.sources.values.filter { $0.kind == .podcastFeed }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var showStartOffsetsCard: some View {
        WiltedSettingsCard(title: "New episode starts") {
            Text("Choose where a new episode starts for each show. Saved progress always resumes at its saved position.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if model.macSupportsShowStartOffsets == false {
                Text("Update Wilted on your Mac to use show start times.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-library-show-start-offset-update-mac")
            }
            ForEach(podcastSources) { source in
                showStartOffsetRow(source)
            }
            Text("These choices sync with your Mac and apply only to a new episode.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-show-start-offsets")
    }

    private func showStartOffsetRow(_ source: LibrarySource) -> some View {
        let command = model.showStartOffsetCommands[source.id.rawValue]
        let selected = model.showStartOffsetSeconds(for: source.id)
        let options = Array(Set([0.0, 15, 30, 45, 60, 90, 120, 180, 300, 600, selected])).sorted()
        return VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            HStack(spacing: WiltedTheme.Spacing.medium) {
                Text(source.title).wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(2)
                Spacer(minLength: WiltedTheme.Spacing.small)
                Picker("Start new episodes at for \(source.title)", selection: Binding(
                    get: { model.showStartOffsetSeconds(for: source.id) },
                    set: { seconds in Task { await model.setShowStartOffset(seconds, for: source.id) } }
                )) {
                    ForEach(options, id: \.self) { seconds in
                        Text(seconds == 0 ? "Beginning" : "\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("wilted-library-show-start-offset-\(source.id.rawValue)")
                .disabled(model.macSupportsShowStartOffsets == false
                    || ((command?.reservedAt != nil || command?.sentAt != nil) && command?.conflict == false))
            }
            if let notice = model.showStartOffsetStatus(for: source.id) {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Text(notice).wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: WiltedTheme.Spacing.small)
                    if command?.conflict == true {
                        Button("Apply again") { Task { await model.reapplyShowStartOffset(for: source.id) } }
                            .font(.footnote)
                            .accessibilityIdentifier("wilted-library-show-start-offset-reapply-\(source.id.rawValue)")
                    }
                }
            }
            Divider()
        }
    }

    private var storageCard: some View {
        WiltedSettingsCard(title: LibrarySettingsSection.storage.title) {
            LibraryStorageSummaryView(summary: cache)
            Button(role: .destructive) { isConfirmingRemoval = true } label: {
                Label { Text("Remove all downloaded audio").wiltedFont(.body) } icon: { Image(systemName: "trash") }
                    .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
            }
            .disabled(cache.episodeCount == 0)
            .accessibilityIdentifier("wilted-library-settings-remove-audio")
            if let removalNotice {
                Text(removalNotice).wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-library-settings-remove-notice")
            }
            scopeNote(.storage)
        }
        .confirmationDialog(
            "Remove all downloaded audio?", isPresented: $isConfirmingRemoval, titleVisibility: .visible
        ) {
            Button("Remove \(cache.episodeCount) episode\(cache.episodeCount == 1 ? "" : "s")", role: .destructive) {
                Task { await removeAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The episode playing now is kept.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-storage")
    }

    /// One row: the status, and, once idle, when this phone last fetched the library. Only an error
    /// adds a detail line.
    private var devicesCard: some View {
        let sync = model.syncSummary
        return WiltedSettingsCard(title: LibrarySettingsSection.devices.title) {
            WiltedPublicationNotice(summary: model.publicationSummary, detail: model.publicationDetail, qualifier: model.publicationQualifier)
            if model.accountQuarantined { WiltedAccountRecoveryNotice(role: .phone) { Task { await model.recoverFromAccountChange() } } }
            iconRow("arrow.triangle.2.circlepath", "Status") {
                Spacer(minLength: 0)
                if sync.tone == .active { ProgressView().accessibilityIdentifier("wilted-library-settings-sync-progress") }
                Text(LibrarySettingsFormat.syncLine(sync, lastRefresh: model.lastSynchronizedAt))
                    .wiltedFont(.utility)
                    .foregroundStyle(sync.tone.color(colorScheme))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("wilted-library-settings-sync-status")
            }
            Toggle("Download from your Mac over Wi-Fi", isOn: $settings.directDownloads)
                .wiltedFont(.utility)
                .accessibilityIdentifier("wilted-library-settings-direct-downloads")
            if model.directState.localNetworkDenied {
                Text(LibraryDirectDownloadOnboarding.localNetworkDeniedInstruction)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-library-settings-direct-downloads-denied")
            }
            if LibrarySettingsFormat.showsSyncDetailInline(sync), let detail = sync.detail {
                Text(detail).wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier(LibrarySettingsFormat.syncDetailIdentifier)
            }
            scopeNote(.devices)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-sync")
    }

    private var aboutCard: some View {
        var version = LibrarySettingsFormat.version(Bundle.main.infoDictionary)
#if DEBUG
        if let pinned = LibraryUITestFixture.pinnedVersion { version = pinned }
#endif
        return WiltedSettingsCard(title: LibrarySettingsSection.about.title) {
            StatisticsRows(stats: model.phoneStats, deviceKind: model.deviceKind)
            ForEach(LibrarySettingsFormat.aboutRows(version: version), id: \.identifier) { row in
                settingsRow(row)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.8) { showsSupportDetails.toggle() }
                    .accessibilityAction(named: showsSupportDetails
                        ? LibrarySettingsFormat.hideSupportDetailsAction
                        : LibrarySettingsFormat.showSupportDetailsAction) { showsSupportDetails.toggle() }
            }
            if showsSupportDetails { supportDetails }
            scopeNote(.about)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-about")
    }

    /// The hidden support details, shown only after a long press on Version. The request counts are
    /// not observed, so they re-read on a 30 s timeline.
    private var supportDetails: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .leading) {
                Text(LibrarySettingsFormat.supportDetailsLabel)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                ForEach(LibrarySettingsFormat.supportRows(
                    deviceID: model.deviceID, voiceLines: VoiceRoutingLog.shared.lines().reversed(),
                    requests: model.syncDiagnostics), id: \.identifier) { row in
                    settingsRow(row)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-support-details")
    }

    private func scopeNote(_ section: LibrarySettingsSection) -> some View {
        Text(section.footnote(deviceKind: model.deviceKind))
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
    }

    // MARK: Pieces

    /// A leading symbol, the label, then whatever trails. Every settings row is built from this so
    /// the spacing, type and symbol treatment cannot drift.
    private func iconRow<Trailing: View>(
        _ symbol: String, _ label: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        LibrarySettingsIconRow(symbol: symbol, label: label, trailing: trailing)
    }

    /// One described settings row: the copy button rides along when the value should be copyable.
    private func settingsRow(_ row: LibrarySettingsFormat.SettingsRow) -> some View {
        let copyLabel = row.identifier == LibrarySettingsFormat.voiceRoutingLogIdentifier
            ? LibrarySettingsFormat.copyVoiceRoutingLogLabel
            : LibrarySettingsFormat.copyDeviceIDLabel
        return iconRow(row.symbol, row.label) {
            Spacer(minLength: 0)
            Text(row.value).wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .lineLimit(row.wrapsText ? nil : 1)
                .truncationMode(.middle)
                .multilineTextAlignment(row.wrapsText ? .leading : .trailing)
                .accessibilityIdentifier(row.identifier)
            if row.isCopyable {
                Button {
                    UIPasteboard.general.string = row.value
                } label: {
                    Image(systemName: "doc.on.doc")
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                        .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget,
                               minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copyLabel)
                .accessibilityIdentifier("\(row.identifier)-copy")
            }
        }
    }

    /// The text-size choice as a row of themed segments (the system control ignores the app's type).
    private func segmented(selection: Binding<WiltedTheme.TextScale>, identifier: String) -> some View {
        HStack(spacing: 2) {
            ForEach(WiltedTheme.TextScale.allCases) { option in
                let isSelected = selection.wrappedValue == option
                Button { selection.wrappedValue = option } label: {
                    Text(option.label).wiltedFont(.utility)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .foregroundStyle(isSelected
                            ? WiltedTheme.color(.page, scheme: colorScheme)
                            : WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .background(
                            RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
                                .fill(isSelected ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("\(identifier)-\(option.id)")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
                .fill(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// A skip length picker whose face is the direction's own symbol at the chosen length
    /// (`gobackward.15`) and a word for which way it goes.
    private func skipMenu(
        _ title: String, selection: Binding<Int>, symbol: String, leading: Bool, identifier: String
    ) -> some View {
        let value = selection.wrappedValue
        let icon = Image(systemName: "\(symbol).\(value)")
        return Menu {
            Picker(title, selection: selection) {
                ForEach(LibrarySettingsStore.skipOptions, id: \.self) { Text(LibrarySettingsFormat.skip($0)).tag($0) }
            }
        } label: {
            HStack(spacing: WiltedTheme.Spacing.small) {
                if leading { icon }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
                if !leading { icon }
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            .wiltedFont(.body)
            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            .background(
                RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
                    .fill(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.12)))
        }
        .accessibilityLabel(title)
        .accessibilityValue(LibrarySettingsFormat.skip(value))
        .accessibilityIdentifier(identifier)
    }

    // MARK: Actions

    private func reloadCache() async {
        cache = await model.cacheSummary()
    }

    private func removeAll() async {
        let removed = await model.removeAllDownloadedAudio(keeping: playingID)
        await reloadCache()
        removalNotice = removed == 0 ? nil : "Removed \(removed) episode\(removed == 1 ? "" : "s")."
    }
}

/// The shipping Storage label, help, and formatted value; shared with layout regressions.
struct LibraryStorageSummaryView: View {
    let summary: LibraryCacheSummary
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            LibrarySettingsIconRow(symbol: "internaldrive", label: "Downloaded audio") {
                SettingsInfoButton(
                    text: "Removes downloaded audio only. Episodes stay in the Larder to fetch again from the Mac.",
                    identifier: "wilted-library-settings-storage-info")
                Spacer(minLength: 0)
            }
            Text(LibrarySettingsFormat.storage(count: summary.episodeCount, bytes: summary.byteCount))
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("wilted-library-settings-cache-size")
        }
    }
}

/// One native Settings label row, used by the sheet and its Storage summary.
private struct LibrarySettingsIconRow<Trailing: View>: View {
    let symbol: String
    let label: String
    let trailing: Trailing
    @Environment(\.colorScheme) private var colorScheme

    init(symbol: String, label: String, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.label = label
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            Image(symbol: symbol).wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                .frame(width: 26).accessibilityHidden(true)
            Text(label).wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .lineLimit(1).minimumScaleFactor(0.8)
            trailing
        }
        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
    }
}

/// The "i" button and its popover. Its own view so the popover state is local to one button.
private struct SettingsInfoButton: View {
    let text: String
    let identifier: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShown = false

    var body: some View {
        Button { isShown = true } label: {
            Image(systemName: "info.circle")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShown) {
            Text(text).wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .padding(WiltedTheme.Spacing.large)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("More information")
        .accessibilityIdentifier(identifier)
    }
}

/// This device's lifetime totals. Observes the store itself, since the model does not republish it.
private struct StatisticsRows: View {
    @ObservedObject var stats: LibraryPhoneStatsStore
    let deviceKind: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(LibrarySettingsFormat.statisticsTitle(deviceKind: deviceKind)).wiltedFont(.body)
            ForEach(LibrarySettingsFormat.phoneStatRows(stats.stats), id: \.identifier) { stat in
                HStack(spacing: WiltedTheme.Spacing.medium) {
                    Image(symbol: stat.symbol)
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    Text(stat.label).wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    Spacer(minLength: WiltedTheme.Spacing.medium)
                    Text(stat.value).wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .multilineTextAlignment(.trailing)
                }
                .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                .accessibilityElement(children: .combine)
                .accessibilityValue(stat.value)
                .accessibilityIdentifier(stat.identifier)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-lifetime-statistics")
    }
}
