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
        WiltedMacLarderRowContent(larder: self, episode: episode, position: position, count: count, showsGroupName: showsGroupName)
    }

    func rowContent(_ episode: WiltedMacEpisode, position: Int, count: Int, showsGroupName: Bool, scheme colorScheme: ColorScheme) -> some View {
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
                WiltedMacThreeLineNotesTitle(
                    episode: episode,
                    source: model.episodeInfoSource(id: episode.id, showTitle: episode.feedTitle)
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isActiveEpisode(episode) {
                    Text(activeStatusLabel(for: episode))
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .lineLimit(2)
                        .accessibilityIdentifier("wilted-larder-active-status-\(episode.id)")
                    WiltedMacEpisodeMetadata(
                        episode: episode, identifier: "wilted-larder-metadata-\(episode.id)", isLarder: true
                    )
                } else {
                    HStack(spacing: 0) {
                        Text(episode.presentation.showLabel).lineLimit(1)
                        Text(" - \(WiltedMacEpisodePresentation.durationLabel(episode.presentation.sourceDurationSeconds))")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-larder-metadata-\(episode.id)")
                    // The row keeps three lines, so listening progress from any
                    // device rides on the date line. Without it the only sign of
                    // a started episode was the Mark completed button.
                    HStack(spacing: WiltedTheme.Spacing.small) {
                        Text(episode.presentation.publicationLabel)
                            .lineLimit(1)
                            .accessibilityIdentifier("wilted-larder-date-\(episode.id)")
                        if let fraction = WiltedMacListeningProgress.fraction(for: episode),
                           let remaining = WiltedMacListeningProgress.remainingLabel(for: episode) {
                            HStack(spacing: WiltedTheme.Spacing.small) {
                                ProgressView(value: fraction)
                                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                                    .frame(width: 60)
                                Text(remaining).lineLimit(1)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Listened \(Int((fraction * 100).rounded())) percent, \(remaining)")
                            .accessibilityIdentifier("wilted-larder-listening-\(episode.id)")
                        }
                    }
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    if let again = model.prepareAgainRows[episode.id] {
                        prepareAgainStatus(episode, again, scheme: colorScheme)
                    }
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
            if group == .downloaded, let cause = preparationFailureCause(episode) {
                Text(cause)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .trailing)
                    .help(cause)
                    .accessibilityIdentifier("wilted-larder-preparation-cause-\(episode.id)")
            }
            nextStepControl(episode, group: group)
                .controlSize(.small)
            // Visible, not only in the context menu: a row can reach the
            // reader's playlists without discovering a right-click.
            WiltedMacAddToPlaylistMenu(model: model, entryID: episode.id, style: .rowAction)
            // Manual completion declares finished without inventing listening time.
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
        .contextMenu {
            WiltedMacAddToPlaylistMenu(model: model, entryID: episode.id)
            if model.canPrepareAgain(episode) {
                Divider()
                Button("Prepare Again") { model.prepareAgain(episode) }
                    .accessibilityIdentifier("wilted-larder-prepare-again-\(episode.id)")
            }
            if WiltedMacEpisodeIdentityReviewRequest.isAvailable(for: episode) {
                Divider()
                Button("Review Possible Duplicate\u{2026}") {
                    reviewTarget = WiltedMacEpisodeIdentityReviewRequest(anchorID: episode.id)
                }
                .accessibilityIdentifier("wilted-larder-review-duplicate-\(episode.id)")
            }
        }
    }

    /// Whether an episode has in-flight work and is presented in the Active Work section.
    func isActiveEpisode(_ episode: WiltedMacEpisode) -> Bool {
        episode.downloadState.isInFlight || (episode.preparationState.isRunning && !model.isDeferredForOffPeak(episode.id))
    }

    /// The live narrative status shown in place of idle metadata while work is in flight.
    func activeStatusLabel(for episode: WiltedMacEpisode) -> String {
        let lifecycle = episode.lifecyclePresentation.primaryLabel
        if let run = model.processorRuns.first(where: { $0.itemID == episode.id && $0.outcome == .running }),
           !run.narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let narrative = run.narrative.trimmingCharacters(in: .whitespacesAndNewlines)
            if narrative.caseInsensitiveCompare(lifecycle) == .orderedSame || narrative.lowercased().hasPrefix(lifecycle.lowercased()) {
                return narrative
            }
            if lifecycle.isEmpty {
                return narrative
            }
            return "\(lifecycle) · \(narrative)"
        }
        return episode.lifecyclePresentation.label
    }

    /// The show's artwork at row size, or the produce tile when the feed
    /// published none or it has not arrived. A report has its own tile: it has no show.
    @ViewBuilder private func rowArtwork(_ episode: WiltedMacEpisode) -> some View {
        WiltedMacEpisodeArtwork(episode: episode, size: 40)
    }

    /// A prepare-again run's line under a Ready row: the live stage with its
    /// transfer progress, or the note a run that changed nothing leaves.
    private func prepareAgainStatus(
        _ episode: WiltedMacEpisode, _ row: WiltedMacPrepareAgainRow, scheme colorScheme: ColorScheme
    ) -> some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            if row.isRunning {
                if let fraction = row.fraction {
                    ProgressView(value: fraction)
                        .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                        .frame(width: 60)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            Text(row.label).lineLimit(2)
        }
        .wiltedFont(.utility)
        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wilted-larder-prepare-again-status-\(episode.id)")
    }

    /// The short cause beside a failed preparation's Retry: the typed cause
    /// from this session, or a plain "failed" for a failure found at launch.
    private func preparationFailureCause(_ episode: WiltedMacEpisode) -> String? {
        guard case .failed = episode.preparationState else { return nil }
        return model.preparationFailureCauses[episode.id] ?? "Preparation failed"
    }

    /// This installed view resolves appearance and keeps every lifecycle action in one slot.
    func nextStepControl(_ episode: WiltedMacEpisode, group: WiltedMacLarderGroup) -> some View {
        WiltedMacLarderNextStepControl(larder: self, episode: episode, group: group)
    }

    @ViewBuilder func nextStepContents(_ episode: WiltedMacEpisode, group: WiltedMacLarderGroup, scheme colorScheme: ColorScheme) -> some View {
        switch group {
        case .playable:
            if model.prepareAgainRows[episode.id]?.isRunning == true {
                // The old cut stays playable underneath; this stops the run only.
                Button { model.cancelEpisodePreparation(episode) } label: {
                    if let fraction = model.prepareAgainRows[episode.id]?.fraction {
                        ProgressView(value: fraction).frame(width: 28)
                    } else { ProgressView().controlSize(.small) }
                }
                .help("Stop preparing again")
                .accessibilityLabel("Stop preparing \(episode.title) again")
                .accessibilityIdentifier("wilted-larder-stop-\(episode.id)")
            } else if model.isEpisodeFinished(episode) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .help("Played")
                    .accessibilityLabel("Played")
                    .accessibilityIdentifier("wilted-larder-played-\(episode.id)")
            } else {
                let opening = model.playbackCommands.pending?.command.kind == .select
                    && model.playbackCommands.pending?.command.itemID == episode.id
                Button { model.playLarderEpisode(episode) } label: {
                    if opening { ProgressView().controlSize(.small) }
                    else { Label("Play now", systemImage: "play.fill") }
                }
                .labelStyle(.iconOnly)
                .disabled(opening)
                .help(opening ? "Opening episode" : "Play now")
                .accessibilityLabel(opening ? "Opening \(episode.title)" : "Play \(episode.title) now")
                .accessibilityIdentifier("wilted-larder-play-\(episode.id)")
            }
        case .downloaded:
            if model.isDeferredForOffPeak(episode.id) {
                Button { model.prepareDeferredEpisodeNow(episode) } label: { Text("Queued") }
                    .help("Waiting for off-peak; prepare now")
                    .accessibilityLabel("Prepare \(episode.title) now")
                    .accessibilityIdentifier("wilted-larder-prepare-now-\(episode.id)")
            } else if case .preparing(let stage) = episode.preparationState {
                Button { model.cancelEpisodePreparation(episode) } label: {
                    if stage == WiltedMacModel.preparationQueuedStage { Text("Queued") }
                    else if let fraction = model.preparationFraction(forEpisode: episode.id) {
                        ProgressView(value: fraction).frame(width: 28)
                    } else { ProgressView().controlSize(.small) }
                }
                .help("Stop preparing")
                .accessibilityLabel("Stop preparing \(episode.title)")
                .accessibilityIdentifier("wilted-larder-stop-\(episode.id)")
            } else if case .failed = episode.preparationState {
                Button { model.prepareEpisode(episode) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly).help("Retry preparation")
                    .accessibilityLabel("Retry preparing \(episode.title)")
                    .accessibilityIdentifier("wilted-larder-retry-\(episode.id)")
            } else {
                Button("Prepare") { model.prepareEpisode(episode) }
                    .help("Prepare episode")
                    .accessibilityIdentifier("wilted-larder-prepare-\(episode.id)")
            }
        case .available:
            switch episode.downloadState {
            case .queued:
                Button { model.cancelEpisodeDownload(episode) } label: { Text("Queued") }
                    .help("Cancel queued download")
                    .accessibilityLabel("Cancel download \(episode.title)")
                    .accessibilityIdentifier("wilted-larder-cancel-\(episode.id)")
            case .downloading(let received, let expected):
                Button { model.cancelEpisodeDownload(episode) } label: {
                    if let expected, expected > 0 {
                        ProgressView(value: min(1, max(0, Double(received) / Double(expected))))
                            .frame(width: 28)
                    } else { ProgressView().controlSize(.small) }
                }
                .help("Cancel download")
                .accessibilityLabel("Cancel download \(episode.title)")
                .accessibilityIdentifier("wilted-larder-cancel-\(episode.id)")
            case .failed, .cancelled:
                Button { model.retryEpisodeDownload(episode) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly).help("Retry download")
                    .accessibilityLabel("Retry \(episode.title)")
                    .accessibilityIdentifier("wilted-larder-retry-\(episode.id)")
            case .notDownloaded, .completed:
                Button { model.downloadEpisode(episode) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .labelStyle(.iconOnly).help("Download")
                    .accessibilityLabel("Download \(episode.title)")
                    .accessibilityIdentifier("wilted-larder-download-\(episode.id)")
            }
        }
    }
}

/// A morning report's artwork: the produce tile's shape with a sunrise, since a report has no show.
struct WiltedMacReportTile: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.wiltedTextScale) private var textScale
    let size: CGFloat

    var body: some View {
        let side = WiltedTheme.scaled(size, scale: textScale)
        RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
            .fill(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.2))
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: "sun.horizon.fill")
                    .font(.system(size: side * 0.5))
                    .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            )
    }
}

/// Resolves the row's environment inside the installed hierarchy, including focused native renders.
private struct WiltedMacLarderRowContent: View {
    let larder: WiltedMacLarderView
    let episode: WiltedMacEpisode
    let position: Int
    let count: Int
    let showsGroupName: Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        larder.rowContent(episode, position: position, count: count, showsGroupName: showsGroupName, scheme: colorScheme)
    }
}

private struct WiltedMacLarderNextStepControl: View {
    let larder: WiltedMacLarderView
    let episode: WiltedMacEpisode
    let group: WiltedMacLarderGroup
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        larder.nextStepContents(episode, group: group, scheme: colorScheme)
            .controlSize(.small)
            .buttonStyle(WiltedMacLarderActionStyle())
            .frame(width: WiltedMacLarderView.readyActionSlotWidth, height: 32)
    }
}

private struct WiltedMacThreeLineNotesTitle: View {
    let episode: WiltedMacEpisode
    let source: WiltedMacEpisodeInfoSource
    @State private var isPresented = false
    var body: some View {
        WiltedMacEpisodeNotesTitle(episode: episode, prefix: "wilted-larder", isPresented: $isPresented, titleLineLimit: 1) {
            WiltedMacEpisodeNotes(episode: episode, prefix: "wilted-larder", source: source) { EmptyView() }
        }
    }
}

/// Makes the visible label and click target identical across row lifecycle states.
struct WiltedMacLarderActionStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: WiltedMacLarderView.readyActionSlotWidth, height: 32)
            .background(WiltedTheme.color(.card, scheme: colorScheme).opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: WiltedTheme.Radius.control))
            .contentShape(Rectangle())
    }
}
