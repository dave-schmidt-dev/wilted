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
            if mode == .rail { WiltedMacNewPlaylistMenu(model: model, style: .icon) }
        } header: {
            if mode == .full { playlistsHeader(scheme: colorScheme) }
        }
    }

    /// One playlist row: the shared sidebar row, named for the playlist.
    func playlistRow(_ playlist: Playlist) -> some View {
        WiltedMacSidebarRow(
            destination: .playlist(playlist.id), title: playlist.name, mode: mode,
            isSelected: model.selectedNavigation == .playlist(playlist.id), textScale: model.textScale
        ) { onSelect(.playlist(playlist.id)) }
    }

    /// The section heading with its New Playlist menu; the installed caller supplies its appearance.
    func playlistsHeader(scheme: ColorScheme) -> some View {
        HStack {
            Text("Playlists")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: scheme))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            WiltedMacNewPlaylistMenu(model: model, style: .icon)
        }
        .accessibilityIdentifier("wilted-sidebar-playlists-header")
    }

    @ViewBuilder
    func playlistActions(_ playlist: Playlist) -> some View {
        Button("Rename…") { model.playlists.prompt = .rename(playlist.id) }
        Button("Delete…", role: .destructive) { model.playlists.prompt = .delete(playlist.id) }
    }
}

/// New Playlist: manual or automatic. Used in the sidebar header, the rail and the Larder's
/// Add to Playlist menu.
struct WiltedMacNewPlaylistMenu: View {
    enum Style { case icon }
    @Bindable var model: WiltedMacModel
    let style: Style
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Menu {
            Button("New Playlist") { Task { await model.createPlaylist(kind: .manual) } }
            Button("New Automatic Playlist") { Task { await model.createPlaylist(kind: .automatic) } }
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
                    if let id = renamingID { Task { await model.renamePlaylist(id, to: draftName) } }
                    model.playlists.prompt = nil
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
                    if let id = deletingID { Task { await model.deletePlaylist(id) } }
                    model.playlists.prompt = nil
                }
                Button("Cancel", role: .cancel) { model.playlists.prompt = nil }
            } message: {
                Text("The items in it stay in your library.")
            }
    }
}

/// Add to Playlist, for a Larder row's context menu: the manual playlists, then New Playlist.
struct WiltedMacAddToPlaylistMenu: View {
    @Bindable var model: WiltedMacModel
    let entryID: String

    var body: some View {
        Menu("Add to Playlist") {
            ForEach(model.playlists.playlists.filter { $0.kind == .manual }, id: \.id) { playlist in
                Button(playlist.name) { Task { await model.addToPlaylist(playlist.id, entryID: entryID) } }
            }
            Divider()
            Button("New Playlist…") {
                Task { await model.createPlaylist(kind: .manual, adding: entryID) }
            }
        }
    }
}
