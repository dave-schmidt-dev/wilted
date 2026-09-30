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
            .refreshable { await model.refresh() }
            .navigationTitle(WiltedScreenCopy.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                        .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .accessibilityIdentifier("wilted-library-settings-done")
                }
            }
        }
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
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Picker("Text and icon size", selection: $settings.textScale) {
                    ForEach(WiltedTheme.TextScale.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wilted-library-settings-text-scale")
                note("Applies to every screen. Icons and artwork grow with the text.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-appearance")
    }

    private var playbackCard: some View {
        WiltedSettingsCard(title: "Playback") {
            Stepper(
                value: $settings.defaultSpeed, in: LibrarySettingsStore.speedRange, step: LibrarySettingsStore.speedStep
            ) {
                row("Default speed", LibrarySettingsFormat.speed(settings.defaultSpeed))
            }
            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            .accessibilityValue(LibrarySettingsFormat.speed(settings.defaultSpeed))
            .accessibilityIdentifier("wilted-library-settings-speed")
            Divider()
            skipPicker("Skip back", selection: $settings.skipBackSeconds, identifier: "wilted-library-settings-skip-back")
            Divider()
            skipPicker("Skip forward", selection: $settings.skipForwardSeconds, identifier: "wilted-library-settings-skip-forward")
            note("A new episode starts at the default speed. "
                 + "Skip lengths also apply to the lock screen controls.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-playback")
    }

    private var storageCard: some View {
        WiltedSettingsCard(title: "Storage") {
            WiltedSettingsRow(
                "Downloaded audio", value: LibrarySettingsFormat.storage(count: cache.episodeCount, bytes: cache.byteCount),
                identifier: "wilted-library-settings-cache-size")
            Divider()
            Button(role: .destructive) { isConfirmingRemoval = true } label: {
                Label("Remove all downloaded audio", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
            }
            .disabled(cache.episodeCount == 0)
            .accessibilityIdentifier("wilted-library-settings-remove-audio")
            if let removalNotice {
                note(removalNotice).accessibilityIdentifier("wilted-library-settings-remove-notice")
            }
            note("Removes the phone's copies only. Episodes stay in the Larder to fetch again from the Mac.")
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

    private var syncCard: some View {
        let sync = model.syncSummary
        return WiltedSettingsCard(title: WiltedScreenCopy.sync) {
            WiltedSettingsRow(
                "Status", value: sync.status, identifier: "wilted-library-settings-sync-status", tone: sync.tone)
            if let detail = sync.detail {
                Divider()
                WiltedSettingsRow("Detail", value: detail, identifier: "wilted-library-settings-sync-detail")
            }
            Divider()
            WiltedSettingsRow(
                "Last refresh", value: LibrarySettingsFormat.date(model.lastSynchronizedAt),
                identifier: "wilted-library-settings-last-refresh")
            Divider()
            WiltedSettingsRow(
                "Mac last seen", value: LibrarySettingsFormat.date(model.macLastSeenAt),
                identifier: "wilted-library-settings-mac-last-seen")
            Divider()
            WiltedSettingsRow("Device", value: model.deviceID, identifier: "wilted-library-settings-device-id")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-sync")
    }

    private var statisticsCard: some View {
        WiltedSettingsCard(title: WiltedScreenCopy.lifetimeStatistics) {
            note(LibrarySettingsFormat.statsScope(model.lifetimeStats))
                .accessibilityIdentifier(WiltedScreenCopy.lifetimeStatisticsScopeIdentifier)
            ForEach(LibrarySettingsFormat.statRows(model.lifetimeStats), id: \.identifier) { stat in
                Divider()
                WiltedSettingsRow(stat.label, value: stat.value, identifier: stat.identifier)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-lifetime-statistics")
    }

    private var aboutCard: some View {
        WiltedSettingsCard(title: "About") {
            WiltedSettingsRow(
                "Version", value: LibrarySettingsFormat.version(Bundle.main.infoDictionary),
                identifier: "wilted-library-settings-version")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-about")
    }

    // MARK: Pieces

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Spacer(minLength: WiltedTheme.Spacing.large)
            Text(value).wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .monospacedDigit()
        }
    }

    private func skipPicker(_ label: String, selection: Binding<Int>, identifier: String) -> some View {
        Picker(selection: selection) {
            ForEach(LibrarySettingsStore.skipOptions, id: \.self) { Text(LibrarySettingsFormat.skip($0)).tag($0) }
        } label: {
            Text(label).wiltedFont(.body)
        }
        .pickerStyle(.menu)
        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
        .accessibilityIdentifier(identifier)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
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
