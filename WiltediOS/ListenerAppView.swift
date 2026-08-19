import SwiftUI
import WiltedDomain

public struct WiltedListenerLibraryView: View {
    @ObservedObject private var model: WiltedListenerAppModel

    public init(model: WiltedListenerAppModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.section) {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    WiltedMark(size: 32, color: WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                    Text(WiltedScreenCopy.library)
                        .font(WiltedTheme.font(.display))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    Spacer()
                    Button("Refresh") { Task { await model.refresh() } }
                        .buttonStyle(.bordered)
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
                    .accessibilityIdentifier(WiltedScreenCopy.playerRewindIdentifier)
                Button("Pause") { Task { await model.pause() } }
                    .accessibilityIdentifier(WiltedScreenCopy.playerPlayPauseIdentifier)
                Button("Restart") { Task { await model.restart() } }
                    .accessibilityIdentifier("wilted-listener-restart")
            }
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
        .accessibilityIdentifier(WiltedScreenCopy.playerIdentifier)
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
                HStack(spacing: WiltedTheme.Spacing.small) {
                    WiltedMark(size: 32, color: WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                    Text(WiltedScreenCopy.downloads)
                        .font(WiltedTheme.font(.display))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                }
                let downloaded = model.items.filter { $0.state == .downloaded }
                if downloaded.isEmpty {
                    Text(WiltedScreenCopy.noDownloads)
                        .font(WiltedTheme.font(.body))
                        .accessibilityIdentifier(WiltedScreenCopy.downloadsEmptyIdentifier)
                } else {
                    ForEach(downloaded) { item in
                        Button {
                            Task { await model.play(itemID: item.itemID) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.title).font(WiltedTheme.font(.title))
                                Text(item.source).font(WiltedTheme.font(.utility))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("wilted-listener-download-\(item.itemID.rawValue)")
                    }
                }
            }
            .padding(WiltedTheme.Spacing.xLarge)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityIdentifier(WiltedScreenCopy.downloadsIdentifier)
    }

    @Environment(\.colorScheme) private var colorScheme
}
