import AppKit
import SwiftUI
import WiltedDomain
import WiltedLibrary

/// Which tab the Now Playing pane shows beneath the transport.
enum WiltedMacPaneTab: String, CaseIterable, Identifiable {
    case transcript = "Transcript"
    case notes = "Notes"

    var id: String { rawValue }
}

/// What the Now Playing pane remembers, owned by the Larder rather than the
/// pane: the pane is unmounted whenever the window is too narrow for it, and
/// reopening it should find the reader's tab and place in the transcript
/// where they left them.
struct WiltedMacPaneState: Equatable {
    var tab: WiltedMacPaneTab = .transcript
    /// Whether the transcript is keeping the spoken line in view.
    var followsPlayback = true

    /// A new episode starts at its own line, not wherever the last was. The
    /// tab is the reader's and stays.
    mutating func episodeChanged() { followsPlayback = true }

    /// Leaving the transcript for Notes unmounts it; coming back mounts a fresh
    /// one at its top, so it resumes at the spoken line rather than strand a
    /// reader at the top with following switched off.
    mutating func tabChanged() { followsPlayback = true }

    /// The full-window player collapsed back to a section. When the window has
    /// since widened, the pane is where that section now lives, so it opens on
    /// the section the reader was in rather than on its own last tab.
    mutating func collapsed(to section: WiltedMacPlayerSection) {
        tab = section == .notes ? .notes : .transcript
        followsPlayback = true
    }
}

/// The full-height Now Playing pane beside the Larder list.
///
/// It reaches the same model calls, accessibility identifiers and keyboard
/// shortcuts as the playback rail (`WiltedMacPlayerContent`); the rail is not
/// mounted while this is, so no identifier appears twice.
struct WiltedMacNowPlayingPane: View {
    @Bindable var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var state: WiltedMacPaneState

    var body: some View {
        Group {
            if model.hasCurrentPlayback {
                playing
            } else {
                idle
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-now-playing-pane")
        .task(id: model.hasCurrentPlayback) {
            guard model.hasCurrentPlayback else { return }
            while !Task.isCancelled {
                model.refreshPlaybackReadout()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Leaving the transcript for Notes and coming back mounts a fresh
        // transcript at its top, so it resumes at the spoken line.
        .onChange(of: state.tab) { state.tabChanged() }
    }

    private var idle: some View {
        VStack(spacing: WiltedTheme.Spacing.medium) {
            if model.isAutomaticAdvancing {
                loading
            } else if model.playbackCommands.pending == nil || model.playbackCommands.pending?.usesInitiatingButtonFeedback == true {
                VStack(spacing: WiltedTheme.Spacing.medium) {
                    WiltedProduceTile(symbol: .lettuce, size: 96)
                        .accessibilityHidden(true)
                    Text("Nothing is playing")
                        .wiltedFont(.title)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    Text("Choose an episode from Larder to start playback.")
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wilted-player-idle")
            }
            // First-start progress stays in the initiating Larder button.
            WiltedMacPlaybackStartResult(model: model)
        }
    }

    private var loading: some View {
        VStack(spacing: WiltedTheme.Spacing.medium) {
            WiltedLoadingMotif()
                .accessibilityHidden(true)
            Text(model.playbackStatusMessage)
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-player-status")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-player-loading")
    }

    private var playing: some View {
        VStack(spacing: WiltedTheme.Spacing.medium) {
            header
            transportRow
            WiltedMacSpeedSaveLine(model: model)
            scrubber
            if showsStatus {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Text(model.playbackStatusMessage)
                        .wiltedFont(.utility)
                        .foregroundStyle(model.playbackStatusTone.color(colorScheme))
                        .accessibilityIdentifier("wilted-player-status")
                    WiltedMacPlaybackRetryButton(model: model)
                }
            }
            tabs
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private var showsStatus: Bool {
        model.playbackStatusMessage != "Playing" && model.playbackStatusMessage != "Paused"
            && model.playbackCommands.pending?.usesPlayPauseButtonFeedback != true
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            artwork
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                WiltedMacPlayerEpisodeTitle(
                    model: model, title: title, font: .title, titleLineLimit: 2,
                    labelIdentifier: "wilted-player-item-title")
                Text(detail)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Share sits on the trailing side of the title, as in the rail player. Borderless icons
            // leave the show and date room; at the narrowest width the date may wrap, never truncate.
            share.buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var artwork: some View {
        let side = WiltedTheme.scaled(48, scale: model.textScale)
        if let url = model.currentEpisode?.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                WiltedProduceTile(symbol: .cabbage, size: 48)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: WiltedTheme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: WiltedTheme.Radius.card)
                    .stroke(WiltedTheme.color(.steel, scheme: colorScheme), lineWidth: 1)
            )
            .accessibilityHidden(true)
        } else {
            WiltedProduceTile(symbol: model.currentEpisode == nil ? .lettuce : .cabbage, size: 48)
                .accessibilityLabel("Playback artwork unavailable")
        }
    }

    private var title: String {
        model.currentEpisode?.title ?? model.currentArticle?.title ?? "Nothing is playing"
    }

    private var detail: String {
        if let episode = model.currentEpisode {
            return episode.presentation.playerSubtitleLabel
        }
        return model.currentArticle?.source ?? WiltedScreenCopy.nowPlayingEmptyDetailProducer
    }

    // MARK: Transport

    private var transportRow: some View {
        HStack(spacing: WiltedTheme.Spacing.xSmall) {
            transport("backward.end.fill", label: "Previous episode", id: "wilted-player-previous") {
                model.previousPlayback()
            }
            .disabled(!model.canSelectPreviousEpisode)
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            transport("gobackward.15", label: "Rewind 15 seconds", id: WiltedScreenCopy.playerRewindIdentifier) {
                model.rewind()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            transport(
                model.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                label: model.isPlaying ? "Pause" : "Play",
                id: WiltedScreenCopy.playerPlayPauseIdentifier,
                size: 48
            ) {
                model.togglePlayback()
            }
            .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            .onKeyPress(.space) {
                model.togglePlayback()
                return .handled
            }
            transport("goforward.30", label: "Skip forward 30 seconds", id: WiltedScreenCopy.playerForwardIdentifier) {
                model.forward()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            transport("forward.end.fill", label: "Next episode", id: "wilted-player-next") {
                model.nextPlayback()
            }
            .disabled(!model.canSelectNextEpisode)
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            completionControl
            moreMenu
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-player-keyboard-transports")
        .controlSize(.regular)
        // A shortcut on a More menu item does not fire while the menu is closed,
        // so Cmd-R stays here, the pane's one binding for it, for the whole session.
        .background {
            Button("Restart") { model.restartPlayback() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var completionControl: some View {
        Button(model.playbackCompletionIsSettled ? "Completed" : "Mark completed") {
            model.markCurrentPlaybackCompleted()
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .disabled(model.playbackCompletionIsSettled)
        .accessibilityIdentifier("wilted-player-mark-completed")
    }

    /// The rare whole-episode actions, in a native pull-down that says what it is.
    private var moreMenu: some View {
        Menu("More") { playbackActions }
            .fixedSize()
            .help("More playback actions")
            .accessibilityIdentifier("wilted-player-menu")
    }

    /// The More menu's items, also hosted directly by headless render tests.
    @ViewBuilder var playbackActions: some View {
        Button("Restart", systemImage: "arrow.counterclockwise") { model.restartPlayback() }
            .accessibilityIdentifier("wilted-player-restart")
        if model.audioRouteFault {
            Button("Recover audio", systemImage: "speaker.wave.2") { model.recoverAudioRoute() }
                .accessibilityIdentifier("wilted-player-route-recovery")
        }
    }

    var share: some View { WiltedMacPlaybackShareLink(model: model) }

    private func transport(
        _ symbol: String, label: String, id: String, size: CGFloat = 24, action: @escaping () -> Void
    ) -> some View {
        let busy = id == WiltedScreenCopy.playerPlayPauseIdentifier
            && model.playbackCommands.pending?.usesPlayPauseButtonFeedback == true
        return Button(action: action) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .wiltedSquare(size)
                .opacity(busy ? 0 : 1)
                .overlay {
                    if busy { ProgressView().controlSize(.small).accessibilityHidden(true) }
                }
        }
        .buttonStyle(.borderless)
        .help(busy ? model.playbackCommands.pending?.message ?? label : label)
        .accessibilityLabel(label)
        .accessibilityValue(busy ? model.playbackCommands.pending?.message ?? "" : "")
        .accessibilityIdentifier(id)
    }

    // MARK: Scrubber

    private var scrubber: some View {
        VStack(spacing: WiltedTheme.Spacing.xSmall) {
            Slider(value: Binding(
                get: { model.playbackPositionSeconds }, set: { model.scrub(to: $0) }
            ), in: 0...max(1, model.playbackDurationSeconds))
            .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            .accessibilityLabel("Playback position")
            .accessibilityValue(model.playbackProgressSpokenLabel)
            .accessibilityIdentifier("wilted-player-scrubber")
            HStack {
                Text(WiltedMacScrubberLabels.elapsed(model.playbackPositionSeconds))
                Spacer()
                Text(WiltedMacScrubberLabels.remaining(
                    position: model.playbackPositionSeconds, duration: model.playbackDurationSeconds))
            }
            .wiltedFont(.utility)
            .monospacedDigit()
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .accessibilityHidden(true)
        }
    }

    // MARK: Tabs

    private var tabs: some View {
        VStack(spacing: WiltedTheme.Spacing.small) {
            // One line over the reader: the section switch starts at the column's leading
            // edge and Speed ends at its trailing edge, so the header keeps its full width.
            HStack(spacing: WiltedTheme.Spacing.small) {
                Picker("Section", selection: $state.tab) {
                    ForEach(WiltedMacPaneTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("wilted-player-pane-tabs")
                Spacer(minLength: WiltedTheme.Spacing.small)
                speedMenu
            }
            Group {
                switch state.tab {
                case .transcript:
                    WiltedMacTranscriptPanel(model: model, viewportHeight: nil, following: $state.followsPlayback)
                        .accessibilityIdentifier(WiltedMacPlayerSection.transcript.expandedAccessibilityIdentifier)
                case .notes:
                    WiltedMacNotesPanel(model: model)
                        .accessibilityIdentifier(WiltedMacPlayerSection.notes.expandedAccessibilityIdentifier)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    /// The frequent control, always showing the current rate, worded like the iPhone player's.
    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(
                get: { model.playbackRate }, set: { model.setPlaybackRate($0) }
            )) {
                ForEach(PlaybackSpeeds.all, id: \.self) {
                    Text("\($0, specifier: "%g")×").tag($0)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text("Speed \(model.playbackRate, specifier: "%g")×")
        }
        .fixedSize()
        .help("Playback speed")
        .accessibilityLabel("Speed")
        .accessibilityValue(Text("\(model.playbackRate, specifier: "%g")×"))
        .accessibilityIdentifier("wilted-player-speed")
    }
}

/// The scrubber's two end labels. Pure, so the sign and rounding are a test.
enum WiltedMacScrubberLabels {
    static func elapsed(_ position: TimeInterval) -> String {
        WiltedDuration.clock(position)
    }

    /// Time left with a leading minus, never negative: a position past the
    /// end reads `-0:00` rather than a negative clock.
    static func remaining(position: TimeInterval, duration: TimeInterval) -> String {
        "-" + WiltedDuration.clock(max(0, duration - position))
    }
}
