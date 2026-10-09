import AppKit
import SwiftUI
import WiltedDomain

extension WiltedMacLarderView {
    func larderRow(
        _ episode: WiltedMacEpisode,
        position: Int,
        count: Int,
        showsGroupName: Bool
    ) -> some View {
        let group = WiltedMacModel.larderGroup(for: episode)
        return VStack(spacing: 0) {
            Rectangle()
                .fill(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                .frame(height: 2)
                .opacity(dropTargetID == episode.id ? 1 : 0)
                .accessibilityHidden(true)
            HStack(spacing: WiltedTheme.Spacing.small) {
            Text(String(format: "%02d", position))
                .wiltedFont(.utility)
                .monospacedDigit()
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityHidden(true)
            rowArtwork(episode)
            VStack(alignment: .leading, spacing: 2) {
                WiltedMacLarderEpisodeNotesTitle(episode: episode)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                WiltedMacEpisodeMetadata(
                    episode: episode,
                    lifecycleLabel: showsGroupName ? group.displayName : nil,
                    identifier: "wilted-larder-metadata-\(episode.id)",
                    isLarder: true
                )
                // Partway through: how much is heard and how much is left,
                // worded as the CarPlay rows word it.
                if let progress = model.episodeProgress(episode) {
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: progress.fraction)
                            .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                            .frame(maxWidth: 160)
                            .accessibilityHidden(true)
                        Text(progress.timeLeftLabel)
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("wilted-larder-listened-\(episode.id)")
                }
                // Only while the phone holds the newest position; hidden otherwise.
                if let phoneLine = model.phonePositionLabel(forEpisodeID: episode.id) {
                    Text(phoneLine)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .lineLimit(1)
                        .accessibilityIdentifier("wilted-larder-phone-position-\(episode.id)")
                }
                // Preparing stays in Downloaded, and this is the figure that
                // says so; the row does not move groups while it runs.
                if episode.preparationState.isRunning,
                   let fraction = model.preparationFraction(forEpisode: episode.id) {
                    ProgressView(value: fraction)
                        .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                        .frame(width: 120)
                        .accessibilityValue("\(Int(fraction * 100)) percent prepared")
                        .accessibilityIdentifier("wilted-larder-progress-\(episode.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // `circle.grid.2x3.fill` is not in the system symbol set -- the
            // handle drew as a blank square on every Larder row, so the reorder
            // affordance was invisible. Checked against NSImage before
            // choosing the replacement rather than swapping one guess for
            // another.
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .draggable(episode.id)
                .help("Drag to reorder")
                .accessibilityLabel("Reorder \(episode.title)")
                .accessibilityAction(named: Text("Move earlier")) {
                    model.moveLarderEpisode(episode.id, by: -1)
                }
                .accessibilityAction(named: Text("Move later")) {
                    model.moveLarderEpisode(episode.id, by: 1)
                }
            if group == .playable {
                nextStepControl(episode, group: group)
                    .controlSize(.small)
                    .frame(width: Self.readyActionSlotWidth, height: 28)
            } else {
                nextStepControl(episode, group: group)
            }
            // Completion is available only after listening has started and
            // before its durable completion record exists. Unstarted and
            // already completed rows keep this slot empty.
            let canMarkCompleted = model.hasStartedEpisode(episode) && !episode.isPlayed
            HStack(spacing: 2) {
                if canMarkCompleted {
                    Button { model.skipEpisode(episode) } label: {
                        Label("Mark completed", systemImage: "checkmark")
                    }
                        .labelStyle(.iconOnly)
                        .help("Mark completed")
                        .accessibilityLabel("Mark \(episode.title) completed")
                        .accessibilityIdentifier("wilted-larder-mark-completed-\(episode.id)")
                } else {
                    Color.clear
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
                // Keep Remove in its existing trailing slot when the completion
                // control is hidden.
                Button { model.removeEpisodeFromUpNext(episode.id) } label: {
                    Label("Remove from Larder", systemImage: "minus.circle")
                }
                    .labelStyle(.iconOnly)
                    .help("Remove from Larder")
                    .accessibilityLabel("Remove \(episode.title) from Larder")
                    .accessibilityIdentifier("wilted-larder-remove-\(episode.id)")
            }
            .controlSize(.small)
            .frame(width: Self.trailingActionSlotsWidth, alignment: .trailing)
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .dropDestination(for: String.self) { draggedIDs, _ in
            model.dropLarderEpisodes(draggedIDs, before: episode.id)
        } isTargeted: { targeted in
            dropTargetID = targeted ? episode.id : nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(episode.title), number \(position) in Larder")
        .accessibilityValue("\(position) of \(count)")
        .accessibilityIdentifier("wilted-larder-row-\(episode.id)")
    }

    /// The show's artwork at row size, or the produce tile when the feed
    /// published none or it has not arrived.
    @ViewBuilder private func rowArtwork(_ episode: WiltedMacEpisode) -> some View {
        if let url = episode.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                WiltedProduceTile(symbol: .cabbage, size: 40)
            }
            .wiltedSquare(40)
            .clipShape(RoundedRectangle(cornerRadius: WiltedTheme.Radius.control))
            .accessibilityHidden(true)
        } else {
            WiltedProduceTile(symbol: .cabbage, size: 40)
                .accessibilityHidden(true)
        }
    }

    /// The single step the row is waiting for. Its group already says which
    /// one it is, so a row never shows the other two greyed out.
    @ViewBuilder private func nextStepControl(_ episode: WiltedMacEpisode, group: WiltedMacLarderGroup) -> some View {
        switch group {
        case .playable:
            if model.isEpisodeFinished(episode) {
                // The one definition of finished, asked by the row: a finished
                // episode is not waiting to be played again.
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .help("Played")
                    .accessibilityLabel("Played")
                    .accessibilityIdentifier("wilted-larder-played-\(episode.id)")
            } else {
                // The press is answered on the row it came from while it opens.
                let opening = model.playbackCommands.pending?.command.kind == .select
                    && model.playbackCommands.pending?.command.itemID == episode.id
                Button { model.playLarderEpisode(episode) } label: {
                    if opening {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Play now", systemImage: "play.fill")
                    }
                }
                    .labelStyle(.iconOnly)
                    .disabled(opening)
                    .help("Play now")
                    .accessibilityLabel(opening ? "Opening \(episode.title)" : "Play \(episode.title) now")
                    .accessibilityIdentifier("wilted-larder-play-\(episode.id)")
            }
        case .downloaded:
            if model.isDeferredForOffPeak(episode.id) {
                // A deferred job is stored as `.preparing(stage: "Queued")`, so
                // without this branch the row reads "Preparing…" beside a Stop
                // button for work that has not started and will not start for
                // hours. The window is a default, not a rule.
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Text("Waiting for off-peak")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    Button("Prepare now") { model.prepareDeferredEpisodeNow(episode) }
                        .accessibilityLabel("Prepare \(episode.title) now")
                        .accessibilityIdentifier("wilted-larder-prepare-now-\(episode.id)")
                }
            } else if episode.preparationState.isRunning {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Text("Preparing…")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    Button { model.cancelEpisodePreparation(episode) } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                        .labelStyle(.iconOnly)
                        .help("Stop")
                        .accessibilityLabel("Stop preparing \(episode.title)")
                        .accessibilityIdentifier("wilted-larder-stop-\(episode.id)")
                }
            } else if case .failed = episode.preparationState {
                Button { model.prepareEpisode(episode) } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                    .labelStyle(.iconOnly)
                    .help("Retry")
                    .accessibilityLabel("Retry preparing \(episode.title)")
                    .accessibilityIdentifier("wilted-larder-retry-\(episode.id)")
            } else {
                Button("Prepare") { model.prepareEpisode(episode) }
                    .accessibilityIdentifier("wilted-larder-prepare-\(episode.id)")
            }
        case .available:
            switch episode.downloadState {
            case .queued, .downloading:
                Button { model.cancelEpisodeDownload(episode) } label: {
                    Label("Cancel download", systemImage: "xmark.circle")
                }
                    .labelStyle(.iconOnly)
                    .help("Cancel download")
                    .accessibilityLabel("Cancel download \(episode.title)")
                    .accessibilityIdentifier("wilted-larder-cancel-\(episode.id)")
            case .failed, .cancelled:
                Button { model.retryEpisodeDownload(episode) } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                    .labelStyle(.iconOnly)
                    .help("Retry")
                    .accessibilityLabel("Retry \(episode.title)")
                    .accessibilityIdentifier("wilted-larder-retry-\(episode.id)")
            case .notDownloaded, .completed:
                Button { model.downloadEpisode(episode) } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                    .labelStyle(.iconOnly)
                    .help("Download")
                    .accessibilityLabel("Download \(episode.title)")
                    .accessibilityIdentifier("wilted-larder-download-\(episode.id)")
            }
        }
    }

    /// Add, kept in the Larder where there is nothing to read: no articles yet,
    /// or none matching the search (W-INV-010). Otherwise the toolbar's Add is
    /// the way in. It opens the same Add sheet.
    @ViewBuilder var addArticleButton: some View {
        if model.larderSearchArticleResults.isEmpty {
            Button {
                model.presentAddSheet()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier("wilted-larder-add-button")
        }
    }
}
