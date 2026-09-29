import SwiftUI
import WiltedDomain
import WiltedLibrary

/// The iPhone Larder: the Mac's queue, in the Mac's order. Builds the production CloudKit
/// environment unless a test or preview injects a model.
struct LibraryRoot: View {
    @StateObject private var model: LibraryAppModel
    @StateObject private var player: LibraryPlayer
    @State private var isPlayerPresented = false
    @Environment(\.scenePhase) private var scenePhase

    init(model: LibraryAppModel? = nil, player: LibraryPlayer? = nil) {
        _model = StateObject(wrappedValue: model ?? LibraryEnvironment.makeModel())
        _player = StateObject(wrappedValue: player ?? LibraryPlayer.live())
    }

    var body: some View {
        LibraryListView(model: model, onPlay: { row in Task { await model.playCached(row) } })
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if LibraryContinueBanner.isVisible(model) { LibraryContinueBanner(model: model) }
                    if player.item != nil || player.status != .idle {
                        LibraryMiniPlayer(player: player) { isPlayerPresented = true }
                    }
                }
            }
            .sheet(isPresented: $isPlayerPresented) {
                LibraryPlayerView(player: player) { isPlayerPresented = false }
                    .presentationDetents([.large])
            }
            // Removing the file from the phone must not leave its audio playing.
            .onChange(of: model.media) { _, media in
                if let playing = player.item, media[playing.entryID] != .onPhone { player.stop() }
            }
            .task {
                model.attachPlayer(player)
                LibraryPushHandler.shared.attach { await model.handleSilentPush() }
                await model.start()
            }
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

    /// Starts a row's cached audio; nil hides the Play button (previews).
    var onPlay: ((LibraryRow) -> Void)?

    var body: some View {
        List {
            if model.accountQuarantined {
                Section {
                    WiltedAccountRecoveryNotice { Task { await model.recoverFromAccountChange() } }
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
            if model.new.isEmpty && model.queued.isEmpty && model.removed.isEmpty {
                emptyState
            } else {
                if !model.new.isEmpty {
                    Section {
                        ForEach(model.new) { decisionRow($0, in: .new) }
                    } header: {
                        Text("New")
                    }
                }
                if !model.queued.isEmpty {
                    Section {
                        ForEach(model.queued) { row in
                            decisionRow(
                                row, in: .larder, media: model.mediaState(for: row.id),
                                onPlay: onPlay.map { play in { play(row) } })
                                .moveDisabled(model.pendingDecision(for: row.id) != nil)
                        }
                        .onMove { model.moveQueued(fromOffsets: $0, toOffset: $1) }
                    } header: {
                        Text("Larder")
                    }
                }
                if !model.removed.isEmpty {
                    Section {
                        Picker("Sort removed by", selection: $model.removedSort) {
                            ForEach(LibraryRemovedSort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("wilted-library-removed-sort")
                        ForEach(model.removed) { decisionRow($0, in: .removed) }
                    } header: {
                        Text("Removed")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .refreshable { await model.refresh() }
        .navigationTitle(WiltedScreenCopy.library)
        .toolbar {
            if model.queued.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { EditButton().accessibilityIdentifier("wilted-library-reorder") }
            }
        }
        .accessibilityIdentifier("wilted-library-list")
    }

    private func decisionRow(
        _ row: LibraryRow, in section: LibraryRowSection, media: LibraryMediaState? = nil,
        onPlay: (() -> Void)? = nil
    ) -> some View {
        LibraryRowView(
            row: row, media: media,
            onMedia: { model.performMediaAction($0, entryID: row.id) },
            onPlay: onPlay,
            decisionActions: model.decisionActions(for: row, in: section),
            decisionStatus: model.decisionStatus(for: row.id),
            onDecision: { model.performDecision($0, entryID: row.id) },
            onCancelDecision: { model.cancelDecision(entryID: row.id) })
    }

    @ViewBuilder private var emptyState: some View {
        if model.isRefreshing {
            HStack(spacing: WiltedTheme.Spacing.medium) {
                ProgressView()
                Text("Fetching the Larder").wiltedFont(.body)
            }
            .accessibilityIdentifier("wilted-library-loading")
        } else {
            ContentUnavailableView {
                Label("Nothing in the Larder", symbol: .larder)
            } description: {
                Text("Episodes queued on your Mac appear here.")
            }
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("wilted-library-empty")
        }
    }
}

struct LibraryRowView: View {
    let row: LibraryRow
    /// Audio state and actions; nil for rows that offer no audio (the removed section).
    var media: LibraryMediaState?
    var onMedia: (LibraryMediaAction) -> Void = { _ in }
    /// Plays the cached audio; only offered once the audio is on the phone.
    var onPlay: (() -> Void)?
    /// Decision buttons for this row's section, and what its decision in flight says.
    var decisionActions: [LibraryDecisionAction] = []
    var decisionStatus: LibraryDecisionStatus?
    var onDecision: (LibraryDecisionAction) -> Void = { _ in }
    var onCancelDecision: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text(row.title)
                .wiltedFont(.body)
                .lineLimit(2)
                .accessibilityIdentifier("wilted-library-title-\(row.id.rawValue)")
            Text(subtitle)
                .wiltedFont(.utility)
                .foregroundStyle(secondary)
                .lineLimit(1)
            if let removal = row.removalText {
                Text(removal)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
                    .accessibilityIdentifier("wilted-library-removal-\(row.id.rawValue)")
            }
            if let checkpoint = row.checkpointText {
                Text(checkpoint)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-library-checkpoint-\(row.id.rawValue)")
            }
            if let media {
                LibraryMediaControl(entryID: row.id, state: media, perform: onMedia)
                if media == .onPhone, let onPlay {
                    Button("Play", systemImage: "play.fill", action: onPlay)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .accessibilityIdentifier("wilted-library-play-\(row.id.rawValue)")
                }
            }
            LibraryDecisionControl(
                entryID: row.id, actions: decisionActions, status: decisionStatus,
                perform: onDecision, cancel: onCancelDecision)
        }
        .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-row-\(row.id.rawValue)")
    }

    private var subtitle: String { [row.showTitle, row.durationText].compactMap { $0 }.joined(separator: " · ") }
    private var secondary: Color { WiltedTheme.color(.secondaryText, scheme: colorScheme) }
}

/// The decision line of a row: its buttons, or the state of the decision in flight. The state is
/// spelled out, never carried by color alone.
struct LibraryDecisionControl: View {
    let entryID: ItemID
    let actions: [LibraryDecisionAction]
    let status: LibraryDecisionStatus?
    let perform: (LibraryDecisionAction) -> Void
    let cancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !actions.isEmpty || status != nil {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                if let status { statusLine(status) }
                if !actions.isEmpty {
                    HStack(spacing: WiltedTheme.Spacing.medium) {
                        ForEach(actions, id: \.identifier) { action in
                            Button(action.title, systemImage: action.systemImage) { perform(action) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                                .accessibilityIdentifier("wilted-library-action-\(action.identifier)-\(entryID.rawValue)")
                        }
                    }
                }
            }
            .padding(.top, WiltedTheme.Spacing.xSmall)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-library-action-\(entryID.rawValue)")
        }
    }

    private func statusLine(_ status: LibraryDecisionStatus) -> some View {
        HStack(alignment: .center, spacing: WiltedTheme.Spacing.medium) {
            Label {
                Text(status.text)
                    .wiltedFont(.utility)
                    .foregroundStyle(tone(status).color(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol(status)).foregroundStyle(tone(status).color(colorScheme))
            }
            .accessibilityIdentifier("wilted-library-action-status-\(entryID.rawValue)")
            Spacer(minLength: 0)
            if status == .pendingOnMac {
                Button("Stop waiting", action: cancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-library-action-cancel-\(entryID.rawValue)")
            }
        }
    }

    private func tone(_ status: LibraryDecisionStatus) -> WiltedStatusTone {
        switch status {
        case .waiting, .confirming: .active
        case .pendingOnMac: .caution
        case .failed: .failure
        }
    }

    private func symbol(_ status: LibraryDecisionStatus) -> String {
        switch status {
        case .waiting: "clock"
        case .confirming: "checkmark.circle"
        case .pendingOnMac: "exclamationmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// The audio line of a Larder row: what state the episode's audio is in, live progress while it
/// moves, and the one action that fits. The state is always spelled out, never carried by color alone.
struct LibraryMediaControl: View {
    let entryID: ItemID
    let state: LibraryMediaState
    let perform: (LibraryMediaAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            HStack(alignment: .center, spacing: WiltedTheme.Spacing.medium) {
                status
                Spacer(minLength: 0)
                action
            }
            progress
        }
        .padding(.top, WiltedTheme.Spacing.xSmall)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-media-\(entryID.rawValue)")
    }

    /// Re-evaluated every second while a transfer runs so the elapsed time keeps moving.
    @ViewBuilder private var status: some View {
        if let start = state.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                statusText(elapsed: context.date.timeIntervalSince(start))
            }
        } else {
            statusText(elapsed: 0)
        }
    }

    private func statusText(elapsed: TimeInterval) -> some View {
        Label {
            Text(state.statusText(elapsed: max(0, elapsed)))
                .wiltedFont(.utility)
                .foregroundStyle(tone.color(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tone.color(colorScheme))
        }
        .accessibilityIdentifier("wilted-library-media-status-\(entryID.rawValue)")
    }

    @ViewBuilder private var progress: some View {
        switch state {
        case .downloading:
            if let fraction = state.fraction { ProgressView(value: fraction) } else { ProgressView() }
        case .requested, .verifying:
            ProgressView()
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .available: button("Get audio", .request, id: "get")
        case .requested, .downloading: button("Cancel", .cancel, id: "cancel")
        case .verifying: EmptyView()
        case .onPhone: button("Remove from phone", .removeFromPhone, id: "remove")
        case .failed: button("Retry", .request, id: "retry")
        case .notPrepared: button("Check again", .request, id: "retry")
        }
    }

    private func button(_ title: String, _ action: LibraryMediaAction, id: String) -> some View {
        Button(title) { perform(action) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            .accessibilityIdentifier("wilted-library-media-\(id)-\(entryID.rawValue)")
    }

    private var tone: WiltedStatusTone {
        switch state {
        case .available: .neutral
        case .requested, .downloading, .verifying: .active
        case .onPhone: .positive
        case .failed: .failure
        case .notPrepared: .caution
        }
    }

    private var symbol: String {
        switch state {
        case .available: "icloud.and.arrow.down"
        case .requested: "clock"
        case .downloading, .verifying: "arrow.down.circle"
        case .onPhone: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .notPrepared: "exclamationmark.circle"
        }
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
    NavigationStack { LibraryPreviewHost() }.preferredColorScheme(.dark)
}
#endif
