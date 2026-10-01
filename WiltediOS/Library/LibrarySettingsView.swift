import SwiftUI
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
    @State private var cache = LibraryCacheSummary()
    @State private var isConfirmingRemoval = false
    @State private var removalNotice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xLarge) {
                    appearanceCard
                    playbackCard
                    storageCard
                    syncCard
                    statisticsCard
                    aboutCard
                }
                .padding(WiltedTheme.Spacing.large)
            }
            .background(WiltedTheme.color(.page, scheme: colorScheme))
            .overlay { LibraryWatermark() }
            .refreshable { await model.refresh() }
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

    private var appearanceCard: some View {
        WiltedSettingsCard(title: "Appearance") {
            iconRow("textformat.size", "Text and icon size") { EmptyView() }
            segmented(selection: $settings.textScale, identifier: "wilted-library-settings-text-scale")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-appearance")
    }

    private var playbackCard: some View {
        WiltedSettingsCard(title: "Playback") {
            Toggle("Auto-play next episode", isOn: $settings.autoPlayNext)
                .wiltedFont(.utility)
                .accessibilityIdentifier("wilted-library-settings-auto-play-next")
            iconRow("gauge.with.dots.needle.67percent", "Default speed") {
                Text(LibrarySettingsFormat.speed(settings.defaultSpeed)).wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .monospacedDigit()
                Stepper(
                    "Default speed", value: $settings.defaultSpeed, in: LibrarySettingsStore.speedRange,
                    step: LibrarySettingsStore.speedStep)
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-playback")
    }

    private var storageCard: some View {
        WiltedSettingsCard(title: "Storage") {
            iconRow("internaldrive", "Downloaded audio") {
                infoButton(
                    "Removes the phone's copies only. Episodes stay in the Larder to fetch again from the Mac.",
                    identifier: "wilted-library-settings-storage-info")
                Spacer(minLength: 0)
                Text(LibrarySettingsFormat.storage(count: cache.episodeCount, bytes: cache.byteCount))
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("wilted-library-settings-cache-size")
            }
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

    /// One row: the status, plus when the mirror was last fetched once it is current. The last
    /// refresh, and the Mac's own activity, are the same fact seen from two ends, so it is shown once.
    private var syncCard: some View {
        let sync = model.syncSummary
        return WiltedSettingsCard(title: WiltedScreenCopy.sync) {
            iconRow("arrow.triangle.2.circlepath", "Status") {
                Spacer(minLength: 0)
                Text(LibrarySettingsFormat.syncLine(sync, lastRefresh: model.lastSynchronizedAt))
                    .wiltedFont(.utility)
                    .foregroundStyle(sync.tone.color(colorScheme))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("wilted-library-settings-sync-status")
            }
            if let detail = sync.detail {
                Text(detail).wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-library-settings-sync-detail")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-sync")
    }

    private var statisticsCard: some View {
        StatisticsCard(stats: model.phoneStats)
    }

    private var aboutCard: some View {
        WiltedSettingsCard(title: "About") {
            iconRow("info.circle", "Version") {
                Spacer(minLength: 0)
                Text(LibrarySettingsFormat.version(Bundle.main.infoDictionary)).wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-library-settings-version")
            }
            iconRow("iphone", "Device") {
                Spacer(minLength: 0)
                Text(model.deviceID).wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("wilted-library-settings-device-id")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-about")
    }

    // MARK: Pieces

    /// A leading symbol, the label, then whatever trails. Every settings row is built from this so
    /// the spacing, type and symbol treatment cannot drift.
    private func iconRow<Trailing: View>(
        _ symbol: String, _ label: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            Image(symbol: symbol)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(label).wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .lineLimit(1).minimumScaleFactor(0.8)
            trailing()
        }
        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
    }

    /// An "i" that opens `text` in a popover, so explanations stay off the page until asked for.
    private func infoButton(_ text: String, identifier: String) -> some View {
        SettingsInfoButton(text: text, identifier: identifier)
    }

    /// The text-size choice as a row of themed segments (the system control ignores the app's type).
    private func segmented(selection: Binding<WiltedTheme.TextScale>, identifier: String) -> some View {
        HStack(spacing: 2) {
            ForEach(WiltedTheme.TextScale.allCases) { option in
                let isSelected = selection.wrappedValue == option
                Button { selection.wrappedValue = option } label: {
                    Text(option.label).wiltedFont(.utility)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(isSelected
                            ? WiltedTheme.color(.page, scheme: colorScheme)
                            : WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .background(
                            RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
                                .fill(isSelected ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme) : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
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

/// This phone's lifetime totals. Observes the store itself, since the model does not republish it.
private struct StatisticsCard: View {
    @ObservedObject var stats: LibraryPhoneStatsStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WiltedSettingsCard(title: WiltedScreenCopy.lifetimeStatistics) {
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
