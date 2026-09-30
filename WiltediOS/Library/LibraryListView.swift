import SwiftUI
import WiltedDomain
import WiltedLibrary

/// The iPhone Larder: episodes the Mac has prepared, in the Mac's order unless sorted. Builds the
/// production CloudKit environment unless a test or preview injects a model.
struct LibraryRoot: View {
    private let runtime: LibraryRuntime
    @StateObject private var model: LibraryAppModel
    @StateObject private var player: LibraryPlayer
    @StateObject private var settings: LibrarySettingsStore
    @State private var isPlayerPresented = false
    @State private var isSettingsPresented = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    init(model: LibraryAppModel? = nil, player: LibraryPlayer? = nil, settings: LibrarySettingsStore? = nil) {
        // The default launch shares the process-wide runtime with CarPlay and Siri; injected objects
        // (tests, previews) get a private one.
        let runtime = (model == nil && player == nil && settings == nil)
            ? LibraryRuntime.shared
            : LibraryRuntime(
                model: model ?? LibraryEnvironment.makeModel(), player: player ?? LibraryPlayer.live(),
                settings: settings ?? LibrarySettingsStore())
        self.runtime = runtime
        _settings = StateObject(wrappedValue: runtime.settings)
        _model = StateObject(wrappedValue: runtime.model)
        _player = StateObject(wrappedValue: runtime.player)
    }

    var body: some View {
        NavigationStack {
            LibraryListView(
                model: model, playingID: player.status == .playing ? player.item?.entryID : nil,
                onPlay: { row in Task { await model.playCached(row) } }, player: player)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isSettingsPresented = true } label: { Label("Settings", systemImage: "gearshape") }
                            .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                            .accessibilityIdentifier("wilted-library-settings-button")
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if LibraryContinueBanner.isVisible(model) { LibraryContinueBanner(model: model) }
                if player.item != nil || player.status != .idle {
                    LibraryMiniPlayer(player: player) { isPlayerPresented = true }
                }
            }
        }
        .sheet(isPresented: $isPlayerPresented) {
            LibraryPlayerView(player: player, model: model) { isPlayerPresented = false }
                .environment(\.wiltedTextScale, settings.textScale)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $isSettingsPresented) {
            LibrarySettingsView(
                settings: settings, model: model, playingID: player.item?.entryID,
                onDone: { isSettingsPresented = false })
                .environment(\.wiltedTextScale, settings.textScale)
                .presentationDetents([.large])
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        .environment(\.wiltedTextScale, settings.textScale)
        .task { await runtime.start() }
        .onChange(of: scenePhase) { _, phase in
            // The refresh also fetches the device records behind "Continue from Mac".
            if phase == .active { Task { await model.refresh() } }
            if phase == .background { Task { await model.sceneEnteredBackground() } }
        }
    }
}

struct LibraryListView: View {
    @ObservedObject var model: LibraryAppModel
    @Environment(\.colorScheme) private var colorScheme
    /// The episode whose detail is open.
    @State private var opened: ItemID?

    /// The entry the player is playing right now; its row offers Pause instead of Play.
    var playingID: ItemID?
    /// Starts a row's cached audio; nil hides the Play button (previews).
    var onPlay: ((LibraryRow) -> Void)?
    /// Lets the episode detail's transcript follow playback.
    var player: LibraryPlayer?

    var body: some View {
        let rows = model.visibleRows
        List {
            if model.accountQuarantined {
                Section {
                    WiltedAccountRecoveryNotice { Task { await model.recoverFromAccountChange() } }
                }
            }
            if let notice = model.throttleNotice {
                Section {
                    Label(notice, systemImage: "hourglass")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
                        .accessibilityIdentifier("wilted-library-throttle")
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
                        .accessibilityIdentifier("wilted-library-error")
                }
            }
            if rows.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(rows) { row in
                        // A tap on the row opens the episode. Not a NavigationLink: while the drag
                        // handles show, the list is in edit mode and a link would stop navigating.
                        LibraryRowView(
                            row: row, media: model.mediaState(for: row.id),
                            isPlaying: playingID == row.id,
                            onMedia: { model.performMediaAction($0, entryID: row.id) },
                            onPlay: onPlay.map { play in { play(row) } },
                            decisionActions: model.decisionActions(for: row).filter { $0 == .markDone },
                            decisionStatus: model.decisionStatus(for: row.id),
                            onDecision: { model.performDecision($0, entryID: row.id) },
                            onCancelDecision: { model.cancelDecision(entryID: row.id) },
                            player: player)
                        .contentShape(Rectangle())
                        .onTapGesture { opened = row.id }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: "Open episode") { opened = row.id }
                        .listRowBackground(WiltedTheme.color(.card, scheme: colorScheme))
                        .moveDisabled(!model.canReorder || model.pendingDecision(for: row.id) != nil)
                    }
                    .onMove(perform: model.canReorder ? { model.moveQueued(fromOffsets: $0, toOffset: $1) } : nil)
                } header: {
                    Text(header(count: rows.count))
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .textCase(nil)
                        .accessibilityIdentifier("wilted-library-count")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .overlay { LibraryWatermark() }
        // The drag handles show exactly when the order can be edited: Custom order, unfiltered,
        // unsearched. There is no Edit button.
        .environment(\.editMode, .constant(model.canReorder && rows.count > 1 ? .active : .inactive))
        .refreshable { await model.refresh() }
        .searchable(text: $model.searchText, prompt: "Title, show or notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Image(.larder).foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                    Text(WiltedScreenCopy.library)
                }
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .accessibilityAddTraits(.isHeader)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu
                sortMenu
            }
        }
        .navigationDestination(item: $opened) { id in
            LibraryEpisodeDetailView(model: model, entryID: id, playingID: playingID, onPlay: onPlay, player: player)
        }
        .accessibilityIdentifier("wilted-library-list")
    }

    private func header(count: Int) -> String {
        model.filter == .all ? "Larder · \(count)" : "\(model.filter.title) · \(count)"
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $model.sort) {
                ForEach(LibrarySortOrder.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Sort: \(model.sort.title)", systemImage: "arrow.up.arrow.down")
        }
        .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
        .accessibilityIdentifier("wilted-library-sort")
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $model.filter) {
                ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Filter: \(model.filter.title)", systemImage: "line.3.horizontal.decrease.circle")
        }
        .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
        .accessibilityIdentifier("wilted-library-filter")
    }

    @ViewBuilder private var emptyState: some View {
        if model.isRefreshing && model.queued.isEmpty {
            HStack(spacing: WiltedTheme.Spacing.medium) {
                ProgressView()
                Text("Fetching the Larder").wiltedFont(.body)
            }
            .accessibilityIdentifier("wilted-library-loading")
        } else if model.preparedCount == 0 {
            ContentUnavailableView {
                Label("Nothing prepared yet", symbol: .larder)
            } description: {
                Text("Episodes prepared on your Mac appear here, ready to fetch.")
            }
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("wilted-library-empty")
        } else {
            ContentUnavailableView {
                Label("No matching episodes", systemImage: "magnifyingglass")
            } description: {
                Text("Change the filter or the search to see more of the Larder.")
            }
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("wilted-library-no-results")
        }
    }
}

struct LibraryRowView: View {
    let row: LibraryRow
    var media: LibraryMediaState?
    /// True while this row's audio is the one playing, so its button pauses.
    var isPlaying = false
    var onMedia: (LibraryMediaAction) -> Void = { _ in }
    /// Plays or pauses the cached audio; only offered once the audio is on the phone.
    var onPlay: (() -> Void)?
    /// Decision buttons for this row, and what its decision in flight says.
    var decisionActions: [LibraryDecisionAction] = []
    var decisionStatus: LibraryDecisionStatus?
    var onDecision: (LibraryDecisionAction) -> Void = { _ in }
    var onCancelDecision: () -> Void = {}
    /// Lets the checkpoint line speak for this phone once it has the episode loaded.
    var player: LibraryPlayer?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
            LibraryArtwork(url: row.artworkURL)
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text(row.title)
                    .wiltedFont(.body)
                    .lineLimit(2)
                    .accessibilityIdentifier("wilted-library-title-\(row.id.rawValue)")
                Text(row.showTitle)
                    .wiltedFont(.utility)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("wilted-library-show-\(row.id.rawValue)")
                Text(detail)
                    .wiltedFont(.utility)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("wilted-library-meta-\(row.id.rawValue)")
                if let removal = row.removalText {
                    Text(removal)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
                        .accessibilityIdentifier("wilted-library-removal-\(row.id.rawValue)")
                }
                LibraryCheckpointLine(row: row, player: player, identifier: "wilted-library-checkpoint-\(row.id.rawValue)")
                LibraryEpisodeActions(
                    row: row, media: media, isPlaying: isPlaying, onMedia: onMedia, onPlay: onPlay,
                    decisionActions: decisionActions, decisionStatus: decisionStatus,
                    onDecision: onDecision, onCancelDecision: onCancelDecision)
            }
        }
        .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-row-\(row.id.rawValue)")
    }

    /// Duration and publication date.
    private var detail: String {
        [row.durationText, row.publishedAt.formatted(.dateTime.month(.abbreviated).day().year())]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var secondary: Color { WiltedTheme.color(.secondaryText, scheme: colorScheme) }
}

/// The episode's artwork at thumbnail size, with a cabbage tile as placeholder while it loads, when the
/// Mac published none, or when it fails. Decorative: the title carries the meaning.
struct LibraryArtwork: View {
    let url: URL?
    var side: CGFloat = 56
    /// True in a list row, where the title carries the meaning; false where the artwork is its own
    /// element and needs an identifier and label.
    var isDecorative = true

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: WiltedTheme.Spacing.small))
        .accessibilityHidden(isDecorative)
    }

    /// The cabbage tile, the Wilted mark for an episode, at the artwork's size.
    private var placeholder: some View {
        WiltedProduceTile(symbol: .cabbage, size: side)
    }
}

#if DEBUG
/// Preview-only data: a Mac writer and an iPhone reader on one in-memory server.
enum LibraryPreviewData {
    @MainActor static func model() async -> LibraryAppModel {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let show = LibrarySource(id: try! ItemID(rawValue: "show-1"), kind: .podcastFeed, title: "Example Show")
        var changes: [LibraryChange] = [.source(show)]
        for (index, title) in ["Queued first", "Queued second"].enumerated() {
            let id = try! ItemID(rawValue: "entry-\(index)")
            let entry = try! LibraryEntry(
                id: id, kind: .podcastEpisode, sourceID: show.id, title: title, summary: "",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 1_800 + Double(index) * 600)
            changes += [.entry(entry), .slot(try! QueueSlot(entryID: id, sortKey: Double(index)))]
        }
        let pending = changes.enumerated().map { PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0) }
        _ = try? await mac.push(changes: pending)
        return LibraryAppModel(transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone")
    }
}

private struct LibraryPreviewHost: View {
    @State private var model: LibraryAppModel?

    var body: some View {
        Group {
            if let model { LibraryRoot(model: model) } else { ProgressView() }
        }
        .task { model = await LibraryPreviewData.model() }
    }
}

#Preview("Larder") {
    LibraryPreviewHost().preferredColorScheme(.dark)
}
#endif
