import SwiftUI
import WiltedDomain

/// Maps the listener's status to the shared tone vocabulary.
///
/// This switch used to be written twice in this file and a third time on the
/// Mac, so the same condition could render three different colors.
private extension ListenerAppStatus {
    var tone: WiltedStatusTone {
        switch self {
        case .failed, .incompatible, .deleted: .failure
        case .offline: .caution
        case .refreshing, .sending: .active
        case .playing: .positive
        case .idle, .ready, .paused: .neutral
        }
    }
}

/// Shared adapter from a domain transcript to the shared disclosure.
private struct WiltedTranscriptDisclosure: View {
    let transcript: Transcript?
    let identifier: String

    var body: some View {
        WiltedTranscriptSection(
            isReadable: isReadable,
            title: transcript?.availability == .stale ? "Transcript (may be outdated)" : "Transcript",
            text: transcript?.text,
            unavailableLabel: unavailableLabel,
            identifier: identifier
        )
    }

    private var isReadable: Bool {
        guard let transcript, let text = transcript.text, !text.isEmpty else { return false }
        return transcript.availability == .available || transcript.availability == .stale
    }

    private var unavailableLabel: String {
        switch transcript?.availability {
        case .oversized: "Transcript unavailable: article text is too large"
        case .malformed: "Transcript unavailable: article text could not be read"
        default: "Transcript unavailable"
        }
    }
}

public struct WiltedListenerLibraryView: View {
    @ObservedObject private var model: WiltedListenerAppModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: WiltedListenerAppModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                Text(model.status.message)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(model.status.tone.color(colorScheme))
                    .accessibilityIdentifier("wilted-listener-status")

                if model.status.isBusy {
                    Button("Cancel") { model.cancel() }
                        .buttonStyle(.bordered)
                        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .accessibilityIdentifier("wilted-listener-cancel")
                }

                if case .failed(_, retryable: true) = model.status {
                    Button("Retry") { Task { await model.refresh() } }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .accessibilityIdentifier("wilted-listener-retry")
                }

                // A quarantined listener previously showed only a red line.
                // Review is the one action that can move it forward, and it is
                // worded and gated exactly as it is on the Mac.
                if model.accountQuarantined {
                    WiltedAccountRecoveryNotice {
                        Task { await model.recoverFromAccountChange() }
                    }
                }

                if model.items.isEmpty {
                    ContentUnavailableView(
                        WiltedScreenCopy.libraryEmpty,
                        systemImage: "tray",
                        description: Text(WiltedScreenCopy.libraryEmptyDetailListener)
                    )
                    .accessibilityIdentifier("wilted-listener-empty-state")
                } else {
                    ForEach(model.items) { item in
                        itemRow(item)
                    }
                }
            }
            .padding(WiltedTheme.Spacing.xLarge)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .navigationTitle(WiltedScreenCopy.library)
        // Refresh belongs in the navigation bar, not floating in the content.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.status.isBusy)
                    .accessibilityIdentifier("wilted-listener-refresh")
            }
        }
        .accessibilityIdentifier(WiltedScreenCopy.libraryIdentifier)
    }

    private func itemRow(_ item: ListenerLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    Text(item.title).font(WiltedTheme.font(.title))
                    Text(item.source).font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    Text(item.state.label).font(WiltedTheme.font(.utility))
                        .foregroundStyle(
                            (item.state == .downloaded ? WiltedStatusTone.positive : .failure)
                                .color(colorScheme)
                        )
                }
                Spacer()
                Button("Play") { Task { await model.play(itemID: item.itemID) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(item.state != .downloaded)
                    .accessibilityIdentifier("wilted-listener-play-\(item.itemID.rawValue)")
            }
            if item.state == .metadataOnly {
                Button("Download") { Task { await model.download(itemID: item.itemID) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("wilted-listener-download-action-\(item.itemID.rawValue)")
            } else if item.state == .downloaded {
                Button("Remove Download") { Task { await model.removeDownload(itemID: item.itemID) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("wilted-listener-remove-download-\(item.itemID.rawValue)")
            }
            WiltedTranscriptDisclosure(
                transcript: model.transcriptsByItem[item.itemID],
                identifier: "wilted-transcript-\(item.itemID.rawValue)"
            )
        }
        .wiltedCard(colorScheme)
    }
}

/// The listener's single authoritative playback surface. Library and Downloads
/// start media; this permanent destination owns every in-app transport.
public struct WiltedListenerNowPlayingView: View {
    @ObservedObject private var model: WiltedListenerAppModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: WiltedListenerAppModel) { self.model = model }

    public var body: some View {
        Group {
            if let state = model.selectedPlayback {
                player(state)
            } else {
                WiltedNowPlayingEmptyView(detail: WiltedScreenCopy.nowPlayingEmptyDetailListener)
            }
        }
        .navigationTitle(WiltedScreenCopy.nowPlaying)
    }

    private func player(_ state: PlaybackState) -> some View {
        ScrollView {
            VStack(spacing: WiltedTheme.Spacing.large) {
                WiltedMark(size: 64, color: WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))

                VStack(spacing: WiltedTheme.Spacing.xSmall) {
                    Text(selectedItem?.title ?? WiltedScreenCopy.nowPlaying)
                        .font(WiltedTheme.font(.title))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .multilineTextAlignment(.center)
                    if let source = selectedItem?.source {
                        Text(source)
                            .font(WiltedTheme.font(.utility))
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    }
                }

                ProgressView(value: boundedPosition(state), total: max(1, state.durationSeconds))
                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityLabel("Playback progress")
                    .accessibilityValue(progressLabel(state))

                Text(progressLabel(state))
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))

                Text(model.status.message)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(model.status.tone.color(colorScheme))
                    .accessibilityIdentifier("wilted-now-playing-status")

                HStack(spacing: WiltedTheme.Spacing.medium) {
                    transportButton(
                        title: "Rewind 15 seconds",
                        symbol: "gobackward.15",
                        identifier: WiltedScreenCopy.playerRewindIdentifier
                    ) { await model.seekBackward() }

                    transportButton(
                        title: playbackIsPlaying ? "Pause" : "Play",
                        symbol: playbackIsPlaying ? "pause.fill" : "play.fill",
                        identifier: WiltedScreenCopy.playerPlayPauseIdentifier,
                        prominent: true
                    ) { await togglePlayback(state) }

                    transportButton(
                        title: "Skip forward 30 seconds",
                        symbol: "goforward.30",
                        identifier: WiltedScreenCopy.playerForwardIdentifier
                    ) { await model.seekForward() }
                }

                Button("Restart") { Task { await model.restart() } }
                    .buttonStyle(.bordered)
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-listener-restart")

                WiltedTranscriptDisclosure(
                    transcript: model.transcriptsByItem[state.itemID],
                    identifier: "wilted-now-playing-transcript"
                )
            }
            .padding(WiltedTheme.Spacing.xLarge)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing. \(selectedItem?.title ?? "Selected article")")
        .accessibilityValue("\(Int(boundedPosition(state))) seconds")
        .accessibilityIdentifier(WiltedScreenCopy.playerIdentifier)
        .task(id: state.sessionID) {
            while !Task.isCancelled {
                await model.refreshNowPlayingReadout()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var selectedItem: ListenerLibraryItem? {
        guard let itemID = model.selectedPlayback?.itemID else { return nil }
        return model.items.first { $0.itemID == itemID }
    }

    private var playbackIsPlaying: Bool {
        if case .playing = model.status { return true }
        return false
    }

    private func boundedPosition(_ state: PlaybackState) -> Double {
        max(0, min(state.positionSeconds, state.durationSeconds))
    }

    private func progressLabel(_ state: PlaybackState) -> String {
        "\(Int(boundedPosition(state))) of \(Int(state.durationSeconds)) seconds"
    }

    private func togglePlayback(_ state: PlaybackState) async {
        if playbackIsPlaying {
            await model.pause()
        } else {
            await model.play(itemID: state.itemID)
        }
    }

    @ViewBuilder
    private func transportButton(
        title: String,
        symbol: String,
        identifier: String,
        prominent: Bool = false,
        action: @escaping () async -> Void
    ) -> some View {
        if prominent {
            Button { Task { await action() } } label: {
                transportIcon(symbol)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        } else {
            Button { Task { await action() } } label: {
                transportIcon(symbol)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        }
    }

    private func transportIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .frame(
                width: WiltedTheme.Spacing.minimumTouchTarget,
                height: WiltedTheme.Spacing.minimumTouchTarget
            )
    }
}

public struct WiltedListenerDownloadsView: View {
    @ObservedObject private var model: WiltedListenerAppModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: WiltedListenerAppModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                let downloaded = model.items.filter { $0.state == .downloaded }
                if downloaded.isEmpty {
                    ContentUnavailableView(
                        WiltedScreenCopy.noDownloads,
                        systemImage: "arrow.down.circle",
                        description: Text("Download an article from Library to listen offline.")
                    )
                    .accessibilityIdentifier(WiltedScreenCopy.downloadsEmptyIdentifier)
                } else {
                    Text(downloadSummary)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-downloads-summary")
                    ForEach(downloaded) { item in
                        downloadRow(item)
                    }
                }
            }
            .padding(WiltedTheme.Spacing.xLarge)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .navigationTitle(WiltedScreenCopy.downloads)
        .accessibilityIdentifier(WiltedScreenCopy.downloadsIdentifier)
    }

    /// The same item carries the same actions here as it does in Library.
    /// Removing a download from the screen that lists downloads was previously
    /// impossible — it was offered only in Library.
    private func downloadRow(_ item: ListenerLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    Text(item.title).font(WiltedTheme.font(.title))
                    Text(item.source).font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Play") { Task { await model.play(itemID: item.itemID) } }
                    .buttonStyle(.borderedProminent)
                    .frame(
                        minWidth: WiltedTheme.Spacing.minimumTouchTarget,
                        minHeight: WiltedTheme.Spacing.minimumTouchTarget
                    )
                    .accessibilityIdentifier("wilted-listener-download-\(item.itemID.rawValue)")
            }
            Button("Remove Download") { Task { await model.removeDownload(itemID: item.itemID) } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("wilted-downloads-remove-\(item.itemID.rawValue)")
        }
        .wiltedCard(colorScheme)
    }

    private var downloadSummary: String {
        let count = model.downloadStatistics.fileCount
        let noun = count == 1 ? "download" : "downloads"
        return "\(count) \(noun) • \(Self.byteFormatter.string(fromByteCount: model.downloadStatistics.byteCount))"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

public struct WiltedListenerSettingsView: View {
    @ObservedObject private var model: WiltedListenerAppModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: WiltedListenerAppModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                WiltedSettingsCard(title: WiltedScreenCopy.sync) {
                    WiltedSettingsRow("Connected Mac", value: "Unavailable", identifier: "wilted-settings-producer")
                    Divider()
                    WiltedSettingsRow("Last successful sync", value: lastSyncLabel, identifier: "wilted-settings-last-sync")
                    if let failure = model.syncObservability.lastFetchFailure {
                        Divider()
                        WiltedSettingsRow(
                            "Last sync issue",
                            value: failure,
                            identifier: "wilted-settings-sync-error",
                            tone: .failure
                        )
                    }

                    // Sync plumbing lives with the rest of sync. This sat in
                    // the Library list, presented as a primary listener action.
                    Button(WiltedScreenCopy.sendPlaybackProgress) { Task { await model.sendPending() } }
                        .buttonStyle(.bordered)
                        .disabled(model.status.isBusy)
                        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .padding(.top, WiltedTheme.Spacing.xSmall)
                        .accessibilityIdentifier("wilted-listener-send")

                    if model.accountQuarantined {
                        WiltedAccountRecoveryNotice(identifier: "wilted-settings-use-current-account") {
                            Task { await model.recoverFromAccountChange() }
                        }
                    }
                }

                WiltedSettingsCard(title: WiltedScreenCopy.downloads) {
                    WiltedSettingsRow("Saved audio", value: downloadCountLabel, identifier: "wilted-settings-download-count")
                    Divider()
                    WiltedSettingsRow("Storage used", value: storageLabel, identifier: "wilted-settings-download-bytes")
                }

                WiltedSettingsCard(title: WiltedScreenCopy.audio) {
                    // The row used to repeat its card's title verbatim.
                    WiltedSettingsRow(
                        WiltedScreenCopy.audioMode,
                        value: WiltedScreenCopy.audioValue,
                        identifier: WiltedScreenCopy.audioRowIdentifier
                    )
                }

                WiltedWordmark(height: 16)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, WiltedTheme.Spacing.large)
                    .accessibilityLabel("Wilted")
            }
            .padding(WiltedTheme.Spacing.xLarge)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .navigationTitle(WiltedScreenCopy.settings)
        .accessibilityIdentifier(WiltedScreenCopy.settingsIdentifier)
    }

    private var lastSyncLabel: String {
        model.syncObservability.lastSuccessfulFetchAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }

    private var downloadCountLabel: String {
        let count = model.downloadStatistics.fileCount
        return "\(count) \(count == 1 ? "file" : "files")"
    }

    private var storageLabel: String {
        Self.byteFormatter.string(fromByteCount: model.downloadStatistics.byteCount)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
