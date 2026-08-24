import SwiftUI
import WiltedDomain

public struct WiltedListenerLibraryView: View {
    @ObservedObject private var model: WiltedListenerAppModel

    public init(model: WiltedListenerAppModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.section) {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Spacer()
                    Button("Refresh") { Task { await model.refresh() } }
                        .buttonStyle(.bordered)
                        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .disabled(model.status.isBusy)
                        .accessibilityIdentifier("wilted-listener-refresh")
                }

                Text(model.status.message)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier("wilted-listener-status")

                if model.status.isBusy {
                    Button("Cancel") { model.cancel() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("wilted-listener-cancel")
                }

                if model.items.isEmpty {
                    Text(WiltedScreenCopy.noArticles)
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                } else {
                    ForEach(model.items) { item in
                        itemRow(item)
                    }
                }

                if case .failed(_, retryable: true) = model.status {
                    Button("Retry") { Task { await model.refresh() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("wilted-listener-retry")
                }

                Button("Send Playback Progress") { Task { await model.sendPending() } }
                    .buttonStyle(.bordered)
                    .disabled(model.status.isBusy)
                    .accessibilityIdentifier("wilted-listener-send")

                if let selected = model.selectedPlayback {
                    nowPlaying(selected)
                }
            }
            .padding(WiltedTheme.Spacing.xLarge)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        // Library is the listener's home and the only tab wrapped in a
        // `NavigationStack`, so it carries the wordmark for the app the way
        // the producer's window toolbar does on the Mac. Downloads and
        // Settings keep plain titles rather than repeating the brand.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                WiltedWordmark(height: 18)
            }
        }
        .accessibilityIdentifier(WiltedScreenCopy.libraryIdentifier)
    }

    @Environment(\.colorScheme) private var colorScheme

    private func itemRow(_ item: ListenerLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    Text(item.title).font(WiltedTheme.font(.title))
                    Text(item.source).font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    Text(item.state.label).font(WiltedTheme.font(.utility))
                        .foregroundStyle(item.state == .downloaded ? WiltedTheme.color(.success, scheme: colorScheme) : WiltedTheme.color(.error, scheme: colorScheme))
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
        .padding(WiltedTheme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .overlay(Rectangle().stroke(WiltedTheme.color(.steel, scheme: colorScheme), lineWidth: 1))
    }

    private func nowPlaying(_ state: PlaybackState) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Now Playing").font(WiltedTheme.font(.title))
            Text("\(Int(state.positionSeconds)) / \(Int(state.durationSeconds)) seconds")
                .font(WiltedTheme.font(.utility))
            HStack {
                Button("Rewind") { Task { await model.rewind() } }
                    .buttonStyle(.bordered)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier(WiltedScreenCopy.playerRewindIdentifier)
                Button(playbackIsPlaying ? "Pause" : "Play") {
                    Task { await togglePlayback() }
                }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier(WiltedScreenCopy.playerPlayPauseIdentifier)
                Button("Restart") { Task { await model.restart() } }
                    .buttonStyle(.bordered)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-listener-restart")
            }
            WiltedTranscriptDisclosure(
                transcript: model.transcriptsByItem[state.itemID],
                identifier: "wilted-now-playing-transcript"
            )
        }
        .padding(WiltedTheme.Spacing.large)
        // A `VStack` is not an accessibility element, so an identifier applied here does not
        // name the panel: SwiftUI pushes it down onto every leaf inside and overwrites the
        // identifiers the transport buttons set for themselves. Rewind, Pause, and Restart
        // all reported as `wilted-player`, which is unaddressable for tests and, worse,
        // indistinguishable under VoiceOver. Declaring the container makes it a real element
        // that carries the identifier while its children keep their own, which is what the
        // shared state views at `Shared/WiltedStateViews.swift` already do.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing")
        .accessibilityValue("\(Int(state.positionSeconds)) seconds")
        .accessibilityIdentifier(WiltedScreenCopy.playerIdentifier)
        .task(id: state.sessionID) {
            while !Task.isCancelled {
                await model.refreshNowPlayingReadout()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var playbackIsPlaying: Bool {
        if case .playing = model.status { return true }
        return false
    }

    private func togglePlayback() async {
        if playbackIsPlaying {
            await model.pause()
        } else if let itemID = model.selectedItemID {
            await model.play(itemID: itemID)
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .failed, .incompatible, .deleted: WiltedTheme.color(.error, scheme: colorScheme)
        case .offline: WiltedTheme.color(.stale, scheme: colorScheme)
        default: WiltedTheme.color(.secondaryText, scheme: colorScheme)
        }
    }
}

public struct WiltedListenerDownloadsView: View {
    @ObservedObject private var model: WiltedListenerAppModel

    public init(model: WiltedListenerAppModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                Text(WiltedScreenCopy.downloads)
                    .font(WiltedTheme.font(.display))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                let downloaded = model.items.filter { $0.state == .downloaded }
                if downloaded.isEmpty {
                    Text(WiltedScreenCopy.noDownloads)
                        .font(WiltedTheme.font(.body))
                        .accessibilityIdentifier(WiltedScreenCopy.downloadsEmptyIdentifier)
                } else {
                    Text(downloadSummary)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-downloads-summary")
                    ForEach(downloaded) { item in
                        HStack(alignment: .center, spacing: WiltedTheme.Spacing.medium) {
                            VStack(alignment: .leading) {
                                Text(item.title).font(WiltedTheme.font(.title))
                                Text(item.source).font(WiltedTheme.font(.utility))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Play") { Task { await model.play(itemID: item.itemID) } }
                                .buttonStyle(.borderedProminent)
                                .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                                .accessibilityIdentifier("wilted-listener-download-\(item.itemID.rawValue)")
                        }
                        .padding(WiltedTheme.Spacing.large)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WiltedTheme.color(.card, scheme: colorScheme))
                        .overlay(Rectangle().stroke(WiltedTheme.color(.steel, scheme: colorScheme), lineWidth: 1))
                    }
                }
            }
            .padding(WiltedTheme.Spacing.xLarge)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityIdentifier(WiltedScreenCopy.downloadsIdentifier)
    }

    @Environment(\.colorScheme) private var colorScheme

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
                Text(WiltedScreenCopy.settings)
                    .font(WiltedTheme.font(.display))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))

                settingsCard(title: "Sync") {
                    settingsRow("Connected Mac", value: "Unavailable", identifier: "wilted-settings-producer")
                    Divider()
                    settingsRow("Last successful sync", value: lastSyncLabel, identifier: "wilted-settings-last-sync")
                    if let failure = model.syncObservability.lastFetchFailure {
                        Divider()
                        settingsRow("Last sync issue", value: failure, identifier: "wilted-settings-sync-error")
                    }
                }

                settingsCard(title: "Downloads") {
                    settingsRow("Saved audio", value: downloadCountLabel, identifier: "wilted-settings-download-count")
                    Divider()
                    settingsRow("Storage used", value: storageLabel, identifier: "wilted-settings-download-bytes")
                }

                settingsCard(title: "Audio") {
                    settingsRow(WiltedScreenCopy.audio, value: WiltedScreenCopy.audioValue,
                                identifier: WiltedScreenCopy.audioRowIdentifier)
                }
            }
            .padding(WiltedTheme.Spacing.xLarge)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
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

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(title)
                .font(WiltedTheme.font(.title))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            content()
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WiltedTheme.color(.card, scheme: colorScheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(WiltedTheme.color(.steel, scheme: colorScheme), lineWidth: 1)
        )
    }

    private func settingsRow(_ label: String, value: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.medium) {
            Text(label)
                .font(WiltedTheme.font(.body))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Spacer(minLength: WiltedTheme.Spacing.large)
            Text(value)
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityIdentifier(identifier)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

private struct WiltedTranscriptDisclosure: View {
    let transcript: Transcript?
    let identifier: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let transcript, let text = transcript.text,
               transcript.availability == .available || transcript.availability == .stale {
                DisclosureGroup(transcript.availability == .stale ? "Transcript (may be outdated)" : "Transcript") {
                    Text(text)
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .textSelection(.enabled)
                        .padding(.top, WiltedTheme.Spacing.small)
                }
                .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            } else {
                Label(unavailableLabel, systemImage: "doc.text.magnifyingglass")
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }

    private var unavailableLabel: String {
        switch transcript?.availability {
        case .oversized: "Transcript unavailable: article text is too large"
        case .malformed: "Transcript unavailable: article text could not be read"
        case .absent, .none: "Transcript unavailable"
        case .available, .stale: "Transcript unavailable"
        }
    }
}
