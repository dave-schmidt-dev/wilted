import SwiftUI
import WiltedProducer

extension WiltedMacSidebar {
    /// The Playlists section: one row per playlist, and the New Playlist menu in the header (full)
    /// or beneath the rows (rail). Playlists are the reader's own lists; they never change the Larder.
    @ViewBuilder
    var playlistsSection: some View {
        Section {
            ForEach(model.playlists.playlists, id: \.id) { playlist in
                playlistRow(playlist)
                    .contextMenu { playlistActions(playlist) }
            }
            if mode == .rail {
                HStack(spacing: WiltedTheme.Spacing.xSmall) {
                    playlistCreateFeedback(scheme: colorScheme)
                    WiltedMacNewPlaylistMenu(model: model, style: .icon)
                }
            }
        } header: {
            if mode == .full { playlistsHeader(scheme: colorScheme) }
        }
    }

    /// One playlist row: the shared sidebar row, named for the playlist. A write in flight shows
    /// its spinner, and the last failure stays visible until that playlist's next operation.
    func playlistRow(_ playlist: Playlist) -> some View {
        let isPending = model.playlists.pending[playlist.id] != nil
        let hasFailed = model.playlists.failures[playlist.id] != nil
        let statusSlotWidth = mode == .full && (isPending || hasFailed)
            ? WiltedTheme.scaled(20, scale: model.textScale) : 0
        return WiltedMacSidebarRow(
            destination: .playlist(playlist.id), title: playlist.name,
            symbolName: playlist.kind.symbol.rawValue, playlistKind: playlist.kind, mode: mode,
            isSelected: model.selectedNavigation == .playlist(playlist.id), textScale: model.textScale
        ) { onSelect(.playlist(playlist.id)) }
        .padding(.trailing, statusSlotWidth)
        .overlay(alignment: .trailing) {
            if isPending {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Saving \(playlist.name)")
                    .accessibilityIdentifier("wilted-sidebar-playlist-saving-\(playlist.id)")
            } else if hasFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(WiltedTheme.color(.error, scheme: colorScheme))
                    .help(model.playlists.failures[playlist.id] ?? "")
                    .accessibilityLabel("The last change to \(playlist.name) failed")
                    .accessibilityIdentifier("wilted-sidebar-playlist-error-\(playlist.id)")
            }
        }
    }

    /// The section heading with its New Playlist menu; the installed caller supplies its appearance.
    func playlistsHeader(scheme: ColorScheme) -> some View {
        HStack {
            Text("Playlists")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: scheme))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            playlistCreateFeedback(scheme: scheme)
            WiltedMacNewPlaylistMenu(model: model, style: .icon)
        }
        .accessibilityIdentifier("wilted-sidebar-playlists-header")
    }

    /// Sidebar feedback while creates are writing, or the New Playlist menu's persistent failure.
    @ViewBuilder
    func playlistCreateFeedback(scheme: ColorScheme) -> some View {
        if model.playlists.creatingCount > 0 {
            ProgressView()
                .controlSize(.small)
                .help("Creating playlist\u{2026}")
                .accessibilityLabel("Creating playlist")
                .accessibilityIdentifier("wilted-sidebar-playlist-creating")
        } else if let failure = model.playlists.createFailure {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(WiltedTheme.color(.error, scheme: scheme))
                .help(failure)
                .accessibilityLabel(failure)
                .accessibilityIdentifier("wilted-sidebar-playlist-create-error")
        }
    }

    @ViewBuilder
    func playlistActions(_ playlist: Playlist) -> some View {
        Button("Rename…") { model.playlists.prompt = .rename(playlist.id) }
        Button("Delete…", role: .destructive) { model.playlists.prompt = .delete(playlist.id) }
    }
}

/// New Playlist: manual or smart. Used in the sidebar header, the rail and the Larder's
/// Add to Playlist menu.
struct WiltedMacNewPlaylistMenu: View {
    enum Style { case icon }
    @Bindable var model: WiltedMacModel
    let style: Style
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Menu {
            Button("New Playlist") { Task { await model.createPlaylist(kind: .manual) } }
            Button("New Smart Playlist") { Task { await model.createPlaylist(kind: .automatic) } }
        } label: {
            Image(systemName: "plus")
                .foregroundStyle(WiltedMacSidebarStyle.iconColor(isSelected: false, scheme: colorScheme))
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New Playlist")
        .accessibilityLabel("New Playlist")
        .accessibilityIdentifier("wilted-sidebar-new-playlist")
    }
}

/// The rename field and the delete confirmation, driven by `model.playlists.prompt` so both the
/// sidebar rows and the playlist page can ask.
struct WiltedMacPlaylistPrompts: ViewModifier {
    @Bindable var model: WiltedMacModel
    @State private var draftName = ""

    private var renamingID: String? {
        if case let .rename(id) = model.playlists.prompt { return id }
        return nil
    }
    private var deletingID: String? {
        if case let .delete(id) = model.playlists.prompt { return id }
        return nil
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: model.playlists.prompt) { _, prompt in
                if case let .rename(id) = prompt { draftName = model.playlist(id)?.name ?? "" }
            }
            .alert("Rename Playlist", isPresented: Binding(
                get: { renamingID != nil }, set: { if !$0, renamingID != nil { model.playlists.prompt = nil } }
            )) {
                TextField("Name", text: $draftName)
                Button("Rename") {
                    guard let id = renamingID else { model.playlists.prompt = nil; return }
                    let name = draftName
                    model.playlists.prompt = nil
                    Task { await model.renamePlaylist(id, to: name) }
                }
                Button("Cancel", role: .cancel) { model.playlists.prompt = nil }
            }
            .confirmationDialog(
                "Delete \(deletingID.flatMap { model.playlist($0)?.name } ?? "playlist")?",
                isPresented: Binding(
                    get: { deletingID != nil }, set: { if !$0, deletingID != nil { model.playlists.prompt = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Playlist", role: .destructive) {
                    guard let id = deletingID else { model.playlists.prompt = nil; return }
                    model.playlists.prompt = nil
                    Task { await model.deletePlaylist(id) }
                }
                Button("Cancel", role: .cancel) { model.playlists.prompt = nil }
            } message: {
                Text("The items in it stay in your library.")
            }
    }
}

/// Add to Playlist for a Larder row: the manual playlists, then New Playlist. It renders as the
/// row's context menu and as a named row action, so the choice is visible without opening one.
struct WiltedMacAddToPlaylistMenu: View {
    enum Style { case contextMenu, rowAction }

    @Bindable var model: WiltedMacModel
    let entryID: String
    var style: Style = .contextMenu

    var body: some View {
        switch style {
        case .contextMenu:
            Menu("Add to Playlist") { choices }
        case .rowAction:
            // Compact enough for the minimum Larder row: a text label there
            // would push the episode's date out of the title column.
            Menu { choices } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add to Playlist")
            .accessibilityLabel("Add to Playlist")
            .accessibilityIdentifier("wilted-add-to-playlist-\(entryID)")
        }
    }

    @ViewBuilder private var choices: some View {
        ForEach(model.playlists.playlists.filter { $0.kind == .manual }, id: \.id) { playlist in
            Button(playlist.name) { Task { await Self.add(model: model, entryID: entryID, to: playlist) } }
        }
        Divider()
        Button("New Playlist…") { Task { await Self.createManualPlaylist(model: model, entryID: entryID) } }
    }

    /// The choice both presentations run; a hosted test can invoke it without opening a menu.
    @MainActor static func add(model: WiltedMacModel, entryID: String, to playlist: Playlist) async {
        await model.addToPlaylist(playlist.id, entryID: entryID)
    }

    @MainActor static func createManualPlaylist(model: WiltedMacModel, entryID: String) async {
        await model.createPlaylist(kind: .manual, adding: entryID)
    }
}
