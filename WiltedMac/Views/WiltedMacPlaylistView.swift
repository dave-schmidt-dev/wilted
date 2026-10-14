import SwiftUI
import WiltedProducer

/// A playlist's page: its items in play order, Play, and the controls for its kind. A manual
/// playlist reorders by drag (or the Move earlier and later actions) and removes items; an
/// automatic playlist shows what its rules match and offers the rule editor. Playing never
/// changes the Larder queue.
struct WiltedMacPlaylistView: View {
    @Bindable var model: WiltedMacModel
    let playlistID: String
    @State private var isEditingRules = false
    @State private var dropTargetID: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let playlist = model.playlist(playlistID) {
            let items = model.playlistItems(playlist)
            WiltedMacDestination(
                title: playlist.name, identifier: "wilted-playlist-\(playlist.id)",
                titleAccessory: { titleActions(playlist) }
            ) {
                header(playlist, items: items)
                if let message = model.playlists.ruleReadErrors[playlist.id]
                    ?? model.playlists.failures[playlist.id] ?? model.playlists.message {
                    Text(message)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-playlist-message")
                }
                if model.playlists.ruleReadErrors[playlist.id] != nil {
                    HStack(spacing: WiltedTheme.Spacing.small) {
                        if model.playlists.retryingRuleIDs.contains(playlist.id) {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Retrying playlist rules")
                        }
                        Button("Retry") { Task { await model.retryPlaylistRules(playlist.id) } }
                            .disabled(model.playlists.retryingRuleIDs.contains(playlist.id))
                            .accessibilityIdentifier("wilted-playlist-rules-retry")
                    }
                }
                if items.isEmpty {
                    empty(playlist)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index, count: items.count, playlist: playlist)
                            Divider()
                        }
                    }
                }
            }
            .sheet(isPresented: $isEditingRules) {
                WiltedMacPlaylistRulesSheet(model: model, playlist: playlist)
            }
        } else {
            // The selection is reconciled to the Larder once playlists load; until then, nothing.
            Color.clear
        }
    }

    private func header(_ playlist: Playlist, items: [WiltedMacLibraryItem]) -> some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            Button {
                model.playPlaylist(playlist)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(!items.contains(where: model.canPlayPlaylistItem))
            .accessibilityLabel("Play \(playlist.name)")
            .accessibilityIdentifier("wilted-playlist-play")
            Text(playlist.kind == .manual ? "Manual playlist" : "Automatic playlist")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            if let operation = model.playlistOperation(playlist.id) {
                HStack(spacing: WiltedTheme.Spacing.xSmall) {
                    ProgressView().controlSize(.small)
                    Text(operation.progressCopy)
                }
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wilted-playlist-saving")
            }
            Spacer()
            if playlist.kind == .automatic {
                Button("Edit Rules…") { isEditingRules = true }
                    .disabled(model.playlists.ruleReadErrors[playlist.id] != nil)
                    .accessibilityIdentifier("wilted-playlist-edit-rules")
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Rename and delete act on the playlist itself, so they sit with its name
    /// rather than in the row that acts on the items inside it.
    private func titleActions(_ playlist: Playlist) -> some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Button { model.playlists.prompt = .rename(playlist.id) } label: { Image(systemName: "pencil") }
                .disabled(model.playlistOperation(playlist.id) != nil)
                .buttonStyle(.borderless)
                .help("Rename playlist")
                .accessibilityLabel("Rename \(playlist.name)")
                .accessibilityIdentifier("wilted-playlist-rename")
            Button { model.playlists.prompt = .delete(playlist.id) } label: { Image(systemName: "trash") }
                .disabled(model.playlistOperation(playlist.id) != nil)
                .buttonStyle(.borderless)
                .help("Delete playlist")
                .accessibilityLabel("Delete \(playlist.name)")
                .accessibilityIdentifier("wilted-playlist-delete")
        }
    }

    private func empty(_ playlist: Playlist) -> some View {
        Text(model.playlists.ruleReadErrors[playlist.id] != nil
             ? "These rules are unavailable until they can be read."
             : playlist.kind == .manual
                 ? "Nothing here yet. Use Add to Playlist on a Larder row."
                 : "Nothing matches these rules yet. Use Edit Rules to choose what belongs here.")
            .wiltedFont(.body)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .accessibilityIdentifier("wilted-playlist-empty")
    }

    private func row(_ item: WiltedMacLibraryItem, index: Int, count: Int, playlist: Playlist) -> some View {
        let manual = playlist.kind == .manual
        let ready = model.canPlayPlaylistItem(item)
        return VStack(spacing: 0) {
            Rectangle()
                .fill(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                .frame(height: 2)
                .opacity(dropTargetID == item.id ? 1 : 0)
                .accessibilityHidden(true)
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text(String(format: "%02d", index + 1))
                    .wiltedFont(.utility)
                    .monospacedDigit()
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    WiltedMacPlaylistItemTitle(model: model, item: item)
                    Text(subtitle(item, ready: ready))
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if manual {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .draggable(item.id)
                        .help("Drag to reorder")
                        .accessibilityLabel("Reorder \(item.title)")
                        .accessibilityAction(named: Text("Move earlier")) {
                            Task { await model.movePlaylistEntry(playlist.id, entryID: item.id, to: max(index - 1, 0)) }
                        }
                        .accessibilityAction(named: Text("Move later")) {
                            Task { await model.movePlaylistEntry(playlist.id, entryID: item.id, to: min(index + 1, count - 1)) }
                        }
                    Button {
                        Task { await model.removeFromPlaylist(playlist.id, entryID: item.id) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from playlist")
                    .accessibilityLabel("Remove \(item.title) from \(playlist.name)")
                    .accessibilityIdentifier("wilted-playlist-remove-\(item.id)")
                }
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .dropDestination(for: String.self) { ids, _ in
            guard manual, let dragged = ids.first, dragged != item.id else { return false }
            Task { await model.movePlaylistEntry(playlist.id, entryID: dragged, to: index) }
            return true
        } isTargeted: { targeted in
            dropTargetID = targeted ? item.id : nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), number \(index + 1) of \(count)")
        .accessibilityIdentifier("wilted-playlist-row-\(item.id)")
    }

    private func subtitle(_ item: WiltedMacLibraryItem, ready: Bool) -> String {
        var parts = [item.source]
        if let seconds = Self.durationSeconds(item), seconds > 0 {
            parts.append(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        if !ready { parts.append("Not ready") }
        return parts.joined(separator: " · ")
    }

    private static func durationSeconds(_ item: WiltedMacLibraryItem) -> TimeInterval? {
        switch item {
        case .article(let article): article.durationSeconds
        case .episode(let episode), .audiobook(let episode): episode.durationSeconds
        }
    }
}

/// Each playlist row owns its popover; articles remain ordinary titles.
struct WiltedMacPlaylistItemTitle: View {
    let model: WiltedMacModel
    let item: WiltedMacLibraryItem
    @State private var isPresented = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch item {
        case .article(let article):
            Text(article.title)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .lineLimit(2)
        case .episode(let episode), .audiobook(let episode):
            WiltedMacEpisodeNotesTitle(
                episode: episode, prefix: "wilted-playlist", isPresented: $isPresented,
                titleLineLimit: 2
            ) {
                WiltedMacEpisodeNotes(
                    episode: episode, prefix: "wilted-playlist",
                    source: model.episodeInfoSource(id: episode.id, showTitle: episode.feedTitle)
                ) { EmptyView() }
            }
            .id(episode.id)
        }
    }
}
