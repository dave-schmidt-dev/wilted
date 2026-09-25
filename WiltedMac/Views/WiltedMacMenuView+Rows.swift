import AppKit
import SwiftUI
import WiltedDomain

extension WiltedMacMenuView {
    func menuRow(
        _ episode: WiltedMacEpisode,
        position: Int,
        count: Int,
        showsGroupName: Bool
    ) -> some View {
        let group = WiltedMacModel.menuGroup(for: episode)
        let subtitle = "\(episode.feedTitle) · \(episode.releasedAt.formatted(date: .numeric, time: .omitted))"
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
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                Text(showsGroupName ? "\(subtitle) · \(group.displayName)" : subtitle)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
                // Preparing stays in Downloaded, and this is the figure that
                // says so; the row does not move groups while it runs.
                if episode.preparationState.isRunning,
                   let fraction = model.preparationFraction(forEpisode: episode.id) {
                    ProgressView(value: fraction)
                        .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                        .frame(width: 120)
                        .accessibilityValue("\(Int(fraction * 100)) percent prepared")
                        .accessibilityIdentifier("wilted-menu-progress-\(episode.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // `circle.grid.2x3.fill` is not in the system symbol set -- the
            // handle drew as a blank square on every Menu row, so the reorder
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
                    model.moveMenuEpisode(episode.id, by: -1)
                }
                .accessibilityAction(named: Text("Move later")) {
                    model.moveMenuEpisode(episode.id, by: 1)
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
                        .accessibilityIdentifier("wilted-menu-mark-completed-\(episode.id)")
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
                    .accessibilityIdentifier("wilted-menu-remove-\(episode.id)")
            }
            .controlSize(.small)
            .frame(width: Self.trailingActionSlotsWidth, alignment: .trailing)
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .dropDestination(for: String.self) { draggedIDs, _ in
            guard let draggedID = draggedIDs.first else { return false }
            return model.moveMenuEpisode(draggedID, before: episode.id)
        } isTargeted: { targeted in
            dropTargetID = targeted ? episode.id : nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(episode.title), number \(position) in Larder")
        .accessibilityValue("\(position) of \(count)")
        .accessibilityIdentifier("wilted-menu-row-\(episode.id)")
    }

    /// The single step the row is waiting for. Its group already says which
    /// one it is, so a row never shows the other two greyed out.
    @ViewBuilder private func nextStepControl(_ episode: WiltedMacEpisode, group: WiltedMacMenuGroup) -> some View {
        switch group {
        case .playable:
            if model.isEpisodeFinished(episode) {
                // The one definition of finished, asked by the row: a finished
                // episode is not waiting to be played again.
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .help("Played")
                    .accessibilityLabel("Played")
                    .accessibilityIdentifier("wilted-menu-played-\(episode.id)")
            } else {
                Button { model.playEpisode(episode) } label: {
                    Label("Play now", systemImage: "play.fill")
                }
                    .labelStyle(.iconOnly)
                    .help("Play now")
                    .accessibilityLabel("Play \(episode.title) now")
                    .accessibilityIdentifier("wilted-menu-play-\(episode.id)")
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
                        .accessibilityIdentifier("wilted-menu-prepare-now-\(episode.id)")
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
                        .accessibilityIdentifier("wilted-menu-stop-\(episode.id)")
                }
            } else if case .failed = episode.preparationState {
                Button { model.prepareEpisode(episode) } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                    .labelStyle(.iconOnly)
                    .help("Retry")
                    .accessibilityLabel("Retry preparing \(episode.title)")
                    .accessibilityIdentifier("wilted-menu-retry-\(episode.id)")
            } else {
                Button("Prepare") { model.prepareEpisode(episode) }
                    .accessibilityIdentifier("wilted-menu-prepare-\(episode.id)")
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
                    .accessibilityIdentifier("wilted-menu-cancel-\(episode.id)")
            case .failed, .cancelled:
                Button { model.retryEpisodeDownload(episode) } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                    .labelStyle(.iconOnly)
                    .help("Retry")
                    .accessibilityLabel("Retry \(episode.title)")
                    .accessibilityIdentifier("wilted-menu-retry-\(episode.id)")
            case .notDownloaded, .completed:
                Button { model.downloadEpisode(episode) } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                    .labelStyle(.iconOnly)
                    .help("Download")
                    .accessibilityLabel("Download \(episode.title)")
                    .accessibilityIdentifier("wilted-menu-download-\(episode.id)")
            }
        }
    }

    /// The way in to the address box, moved here with the Larder's remaining
    /// jobs: an article is saved listening, and the Menu is where listening
    /// starts now.
    var addArticleButton: some View {
        Button {
            model.isPresentingComposer = true
        } label: {
            Label(WiltedScreenCopy.addLink, systemImage: "plus")
        }
        .accessibilityIdentifier("wilted-add-article-button")
        .popover(isPresented: $model.isPresentingComposer, arrowEdge: .bottom) {
            composer
                .frame(width: 420)
                .padding(WiltedTheme.Spacing.large)
                .background(WiltedTheme.color(.card, scheme: colorScheme))
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(WiltedScreenCopy.addLinkTitle)
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text(WiltedScreenCopy.addLinkDetail)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: WiltedTheme.Spacing.medium) {
                WiltedMacLinkField(text: $model.urlDraft)
                Button(WiltedScreenCopy.addLink) {
                    model.addPastedLink()
                }
                .keyboardShortcut(.return)
                .accessibilityIdentifier("wilted-add-link")
            }
            if let status = model.linkDraftStatus {
                Text(status)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-link-status")
            }
            if let advertised = model.advertisedFeed {
                WiltedMacAdvertisedFeedOffer(
                    model: model, feedURL: advertised, identifier: "wilted-advertised-feed"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-mac-composer")
    }
}
