import AppKit
import SwiftUI
import WiltedDomain

struct WiltedMacPlayerContent: View {
    @Bindable var model: WiltedMacModel
    @Environment(\.colorScheme) var colorScheme
    @Binding var presentation: WiltedMacPlayerSection?
    let layout: WiltedMacPlayerLayout
    private let focusRequest: WiltedMacPlayerSection?
    let onCollapse: (WiltedMacPlayerSection) -> Void
    private let onSelect: (WiltedMacPlayerSection) -> Void
    @FocusState private var primaryTransportFocused: Bool
    @FocusState private var keyboardFocus: WiltedMacPlayerSection?
    @AccessibilityFocusState private var accessibilityFocus: WiltedMacPlayerSection?

    init(
        model: WiltedMacModel,
        presentation: Binding<WiltedMacPlayerSection?>,
        layout: WiltedMacPlayerLayout,
        focusRequest: WiltedMacPlayerSection?,
        onCollapse: @escaping (WiltedMacPlayerSection) -> Void,
        onSelect: @escaping (WiltedMacPlayerSection) -> Void = { _ in }
    ) {
        self.model = model
        _presentation = presentation
        self.layout = layout
        self.focusRequest = focusRequest
        self.onCollapse = onCollapse
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: WiltedTheme.Spacing.small) {
            if layout == .fullWindow {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Now Playing")
                            .wiltedFont(.display)
                        Text(presentation?.title ?? "")
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    }
                    Spacer()
                    Button("Collapse") { collapsePresentation() }
                        .accessibilityIdentifier("wilted-player-collapse")
                }
            }
            if model.hasCurrentPlayback {
                HStack(spacing: WiltedTheme.Spacing.medium) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                        .wiltedFont(.body)
                        .accessibilityIdentifier("wilted-player-item-title")
                    Text(detail)
                        .lineLimit(1)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityLabel(detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Label hidden and width unconstrained: with both, an 82pt
                // picker showed "Speed" and clipped the value to a sliver.
                Picker("Speed", selection: Binding(
                    get: { model.playbackRate }, set: { model.setPlaybackRate($0) }
                )) {
                    ForEach(WiltedMacModel.playbackRateChoices, id: \.self) {
                        Text("\($0, specifier: "%g")×").tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!model.hasCurrentPlayback)
                .accessibilityLabel("Speed")
                .accessibilityIdentifier("wilted-player-speed")

                if let shareURL = model.currentPlaybackShareURL {
                    ShareLink(
                        item: shareURL,
                        subject: Text(model.currentPlaybackShareTitle),
                        message: Text(model.currentPlaybackShareMessage)
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Share")
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("wilted-player-share")
                } else if let shareText = model.currentPlaybackShareText {
                    ShareLink(
                        item: shareText,
                        subject: Text(model.currentPlaybackShareTitle),
                        message: Text(model.currentPlaybackShareMessage)
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Share")
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("wilted-player-share")
                }

            }

            HStack(spacing: WiltedTheme.Spacing.medium) {
                transport("backward.end.fill", label: "Previous episode", id: "wilted-player-previous") {
                    model.previousPlayback()
                }
                .disabled(!model.canSelectPreviousEpisode)
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                transport("gobackward.15", label: "Rewind 15 seconds", id: WiltedScreenCopy.playerRewindIdentifier) {
                    model.rewind()
                }
                .disabled(!model.hasCurrentPlayback)
                .keyboardShortcut(.leftArrow, modifiers: .command)
                transport(
                    model.isPlaying ? "pause.fill" : "play.fill",
                    label: model.isPlaying ? "Pause" : "Play",
                    id: WiltedScreenCopy.playerPlayPauseIdentifier
                ) {
                    model.togglePlayback()
                }
                .disabled(!model.hasCurrentPlayback)
                .focusable()
                .focused($primaryTransportFocused)
                .onKeyPress(.space) {
                    guard model.hasCurrentPlayback else { return .ignored }
                    model.togglePlayback()
                    return .handled
                }
                transport("goforward.30", label: "Skip forward 30 seconds", id: WiltedScreenCopy.playerForwardIdentifier) {
                    model.forward()
                }
                .disabled(!model.hasCurrentPlayback)
                .keyboardShortcut(.rightArrow, modifiers: .command)
                transport("forward.end.fill", label: "Next episode", id: "wilted-player-next") {
                    model.nextPlayback()
                }
                .disabled(!model.canSelectNextEpisode)
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Button("Restart") { model.restartPlayback() }
                    .disabled(!model.hasCurrentPlayback)
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityIdentifier("wilted-player-restart")
                // Beside Restart because they are the same kind of decision
                // about the whole episode rather than about the playhead: one
                // says start over, the other says done with it. The label goes
                // past tense once the press has nothing left to do, which is
                // the only thing on this row that changes, so the press is
                // visible. It follows the retirement rather than the written
                // record: an episode marked finished but still on the shelf
                // still has the half the listener can see left to do.
                Button(model.playbackCompletionIsSettled ? "Completed" : "Mark completed") {
                    model.markCurrentPlaybackCompleted()
                }
                .disabled(!model.hasCurrentPlayback || model.playbackCompletionIsSettled)
                .accessibilityIdentifier("wilted-player-mark-completed")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-player-keyboard-transports")

            HStack {
                Slider(value: Binding(
                    get: { model.playbackPositionSeconds }, set: { model.scrub(to: $0) }
                ), in: 0...max(1, model.playbackDurationSeconds)) {
                    Text("Playback position")
                }
                .disabled(!model.hasCurrentPlayback)
                .accessibilityLabel("Playback position")
                .accessibilityValue(model.playbackProgressSpokenLabel)
                .accessibilityIdentifier("wilted-player-scrubber")

                Text(model.playbackProgressLabel)
                    .wiltedFont(.utility)

                expansionButton("Transcript", expansion: .transcript, id: "wilted-player-transcript")
                // Show notes belong to episodes; an article has its own text.
                if model.currentEpisode != nil {
                    expansionButton("Notes", expansion: .notes, id: "wilted-player-notes")
                }
                if model.selectedNavigation != .menu {
                    Button("Larder (\(model.menuUpcomingEpisodeIDs.count))") {
                        presentation = nil
                        model.openMenu()
                    }
                        .accessibilityLabel("Open Larder with \(model.menuUpcomingEpisodeIDs.count) episodes")
                        .accessibilityIdentifier("wilted-player-menu")
                }

                if model.audioRouteFault {
                    Button("Recover audio") { model.recoverAudioRoute() }
                        .accessibilityIdentifier("wilted-player-route-recovery")
                }

                Image(systemName: "speaker.fill")
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { model.playbackVolume }, set: { model.setPlaybackVolume($0) }
                ), in: 0...1)
                .frame(width: 90)
                .disabled(!model.hasCurrentPlayback)
                .accessibilityLabel("Volume")
                .accessibilityIdentifier("wilted-player-volume")
            }

            if model.playbackError != nil {
                // The status is the sole fault sentence. This container keeps
                // the established recovery identifier without rendering it a
                // second time.
                VStack(alignment: .leading, spacing: 0) {
                    playbackStatus
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("wilted-player-recoverable-error")
            } else {
                playbackStatus
            }

            if let presentation {
                Divider()
                expandedContent(presentation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let status = model.playbackOperationStatus {
                Text(status)
                    .wiltedFont(.utility)
                    .accessibilityIdentifier("wilted-player-operation-status")
            }
            } else {
                minimizedIdlePlayer
            }
        }
        .onExitCommand {
            collapsePresentation()
        }
        .task(id: model.hasCurrentPlayback) {
            guard model.hasCurrentPlayback else { return }
            await Task.yield()
            if layout == .rail, presentation == nil, keyboardFocus == nil {
                primaryTransportFocused = true
            }
            while !Task.isCancelled {
                model.refreshPlaybackReadout()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: focusRequest) {
            guard layout == .rail, let focusRequest else { return }
            await Task.yield()
            keyboardFocus = focusRequest
        }
    }

    @ViewBuilder
    private func expansionButton(
        _ label: String,
        expansion target: WiltedMacPlayerSection,
        id: String
    ) -> some View {
        // The same button closes what it opened, and says so: the pane pushes
        // the list up rather than covering it, and nothing else on screen
        // explained how to get the room back.
        //
        // Both titles are laid out, with only one visible, so the control keeps
        // one width across the toggle. Letting it resize left the focus ring
        // drawn at the wider "Hide ..." size after the title had gone back to
        // the short one, and a toggle that changes width under the pointer is
        // the wrong behaviour regardless of the ring.
        Button {
            toggle(target)
        } label: {
            ZStack {
                Text("Hide \(label)").hidden()
                Text(presentation == target ? "Hide \(label)" : label)
            }
        }
        .accessibilityLabel(presentation == target ? "Hide \(label)" : label)
        .focusable()
        .focused($keyboardFocus, equals: target)
        .onKeyPress(.space) {
            toggle(target)
            return .handled
        }
        .onKeyPress(.escape) {
            guard presentation != nil else { return .ignored }
            collapsePresentation()
            return .handled
        }
        .accessibilityFocused($accessibilityFocus, equals: target)
        .accessibilityValue(presentation == target ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(id)
    }

    private func toggle(_ target: WiltedMacPlayerSection) {
        if presentation == target {
            collapsePresentation()
        } else {
            presentation = target
            if layout == .fullWindow {
                onSelect(target)
            }
            primaryTransportFocused = false
            Task { @MainActor in
                await Task.yield()
                keyboardFocus = target
            }
        }
    }

}
