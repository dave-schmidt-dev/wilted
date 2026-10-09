import SwiftUI
import WiltedDomain
import WiltedLibrary

/// The bar pinned above the Larder while an episode is loaded. Tapping the title opens the
/// full player. State is spelled out in words, never left to color or an icon alone.
struct LibraryMiniPlayer: View {
    @ObservedObject var player: LibraryPlayer
    let onExpand: () -> Void
    /// A start still looking up its file, or one that just failed; it speaks over the player's own state.
    var command: LibraryPlaybackCommandStatus? = nil
    /// Retries a failed start; nil hides Retry.
    var onRetry: (() -> Void)? = nil
    @State private var scrubPosition: Double?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if player.duration > 0 {
                LibraryScrubber(player: player, scrubPosition: $scrubPosition, compact: true)
                    .overlay(alignment: .topLeading) {
                        // The time under the finger while it drags; the line itself is too thin to carry it.
                        if let target = scrubPosition {
                            Text(LibraryClockFormat.duration(target))
                                .wiltedFont(.utility).monospacedDigit()
                                .padding(.horizontal, WiltedTheme.Spacing.small)
                                .background(WiltedTheme.color(.card, scheme: colorScheme), in: Capsule())
                                .offset(y: -WiltedTheme.Spacing.large)
                                .accessibilityHidden(true)
                        }
                    }
            }
            HStack(spacing: WiltedTheme.Spacing.medium) {
                Button(action: onExpand) {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                        Text(command?.title ?? player.item?.title ?? "Nothing playing")
                            .wiltedFont(.body)
                            .lineLimit(1)
                        Text(summary)
                            .wiltedFont(.utility)
                            .foregroundStyle(LibraryPlayerText.tone(for: player.status, command: command).color(colorScheme))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open player")
                .accessibilityValue(summary)
                .accessibilityIdentifier("wilted-player-expand")

                if command?.isFailure == true, let onRetry {
                    Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(LibraryPlayerText.retry)
                        .accessibilityIdentifier("wilted-player-mini-retry")
                } else if player.item != nil {
                    LibraryHeldSkipButton(player: player, direction: .backward, symbol: "gobackward.\(player.skipBackSeconds)")
                        .accessibilityLabel("Back \(player.skipBackSeconds) seconds")
                        .accessibilityIdentifier("wilted-player-mini-back")
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("wilted-player-mini-toggle")
                }
                Button { player.stop() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close player")
                    .accessibilityIdentifier("wilted-player-mini-close")
            }
            .buttonStyle(LibraryPlayerButtonStyle())
            .padding(.horizontal, WiltedTheme.Spacing.large)
        }
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-player-mini")
    }

    private var summary: String { command?.text ?? LibraryPlayerText.summary(for: player) }
}

/// The full player: scrubber, transport, speed.
struct LibraryPlayerView: View {
    @ObservedObject var player: LibraryPlayer
    /// When given, the player shows the playing episode's transcript below the controls.
    var model: LibraryAppModel?
    /// Where the backdrop reads artwork from; tests give it their own folder.
    var artworkCache: LibraryArtworkCache = LibraryArtworkCache.shared
    let onClose: () -> Void
    /// A start still looking up its file, or one that just failed.
    var command: LibraryPlaybackCommandStatus? = nil
    /// Retries a failed start; nil hides Retry.
    var onRetry: (() -> Void)? = nil
    @State private var scrubPosition: Double?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: WiltedTheme.Spacing.large) {
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-player-done")
            }
            VStack(spacing: WiltedTheme.Spacing.small) {
                Text(command?.title ?? player.item?.title ?? "Nothing playing")
                    .wiltedFont(.title)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("wilted-player-title")
                if let show = player.item?.showTitle, !show.isEmpty {
                    Text(show)
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                Text(command?.text ?? LibraryPlayerText.statusLine(for: player.status))
                    .wiltedFont(.utility)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(LibraryPlayerText.tone(for: player.status, command: command).color(colorScheme))
                    .accessibilityIdentifier("wilted-player-status")
                if command?.isFailure == true, let onRetry {
                    Button(LibraryPlayerText.retry, action: onRetry)
                        .wiltedFont(.body)
                        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .accessibilityIdentifier("wilted-player-retry")
                }
            }
            scrubber
            transport
            HStack(spacing: WiltedTheme.Spacing.large) {
                if player.supportsRate { rateMenu }
                if let model, let entryID = player.item?.entryID {
                    LibraryPlayerCompletion(model: model, entryID: entryID)
                }
            }
            transcript
        }
        .padding(WiltedTheme.Spacing.large)
        .background {
            ZStack {
                WiltedTheme.color(.page, scheme: colorScheme)
                LibraryArtworkBackdrop(url: player.item?.artworkURL, cache: artworkCache)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-player-full")
    }

    /// The transcript fills the space under the controls and follows playback.
    @ViewBuilder
    private var transcript: some View {
        if let model, let entryID = player.item?.entryID {
            LibraryTranscriptSection(model: model, entryID: entryID, player: player)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityIdentifier("wilted-player-transcript")
        } else {
            Spacer(minLength: 0)
        }
    }

    private var scrubber: some View {
        VStack(spacing: WiltedTheme.Spacing.xSmall) {
            LibraryScrubber(player: player, scrubPosition: $scrubPosition)
            HStack {
                Text(LibraryClockFormat.duration(scrubPosition ?? player.position))
                Spacer()
                Text("-" + LibraryClockFormat.duration(max(0, player.duration - (scrubPosition ?? player.position))))
            }
            .wiltedFont(.utility)
            .monospacedDigit()
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .accessibilityHidden(true)
        }
    }

    private var transport: some View {
        HStack(spacing: WiltedTheme.Spacing.section) {
            LibraryHeldSkipButton(player: player, direction: .backward, symbol: "gobackward.\(player.skipBackSeconds)")
                .accessibilityLabel("Back \(player.skipBackSeconds) seconds")
                .accessibilityIdentifier("wilted-player-back")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").imageScale(.large)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("wilted-player-toggle")
            LibraryHeldSkipButton(player: player, direction: .forward, symbol: "goforward.\(player.skipForwardSeconds)")
                .accessibilityLabel("Forward \(player.skipForwardSeconds) seconds")
                .accessibilityIdentifier("wilted-player-forward")
        }
        .font(.title)
        .buttonStyle(LibraryPlayerButtonStyle())
        .disabled(player.item == nil)
    }

    private var rateMenu: some View {
        Menu {
            ForEach(PlaybackSpeeds.all, id: \.self) { rate in
                Button {
                    player.setRate(rate)
                } label: {
                    if rate == player.rate { Label(LibraryPlayerText.rate(rate), systemImage: "checkmark") } else { Text(LibraryPlayerText.rate(rate)) }
                }
            }
        } label: {
            Text("Speed \(LibraryPlayerText.rate(player.rate))")
                .wiltedFont(.body)
                .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
        }
        .accessibilityIdentifier("wilted-player-rate")
    }
}

/// Mark completed and Remove from Larder for the episode on screen, the same requests the Larder and
/// the Siri intent make (`decide`), offered while the row would offer them. Both ask first and say
/// when the request is waiting on the Mac.
struct LibraryPlayerCompletion: View {
    @ObservedObject var model: LibraryAppModel
    let entryID: ItemID
    @State private var confirming: LibrarySwipe.Confirmation?

    var body: some View {
        let row = model.queued.first { $0.id == entryID }
        let actions = row.map { model.decisionActions(for: $0) } ?? []
        VStack(spacing: WiltedTheme.Spacing.xSmall) {
            HStack(spacing: WiltedTheme.Spacing.large) {
                if actions.contains(.markDone) { button(.markCompleted(entryID), "wilted-player-mark-completed") }
                if actions.contains(.removeFromLarder) { button(.removeFromLarder(entryID), "wilted-player-remove-from-larder") }
            }
            LibraryStatusLine(
                entryID: entryID, media: nil, decision: model.decisionStatus(for: entryID),
                cancelDecision: { model.cancelDecision(entryID: entryID) })
        }
        .confirmationDialog(
            confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible, presenting: confirming
        ) { question in
            Button(question.confirmLabel, role: question.isDestructive ? .destructive : nil) { question.confirmed(on: model) }
            Button("Cancel", role: .cancel) {}
        } message: { question in
            Text(question.message)
        }
    }

    private func button(_ question: LibrarySwipe.Confirmation, _ identifier: String) -> some View {
        let action: LibraryDecisionAction = question.isDestructive ? .removeFromLarder : .markDone
        return Button { confirming = question } label: {
            Label(action.title, systemImage: action.systemImage)
                .wiltedFont(.body)
                .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Flat icon buttons with the minimum touch target and the Wilted accent.
private struct LibraryPlayerButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Wording and tone for player state, kept pure so it does not depend on a view.
@MainActor enum LibraryPlayerText {
    static func statusLine(for status: LibraryPlayer.Status) -> String {
        switch status {
        case .idle: "Stopped"
        case .playing: "Playing"
        case .paused: "Paused"
        case .ended: "Finished"
        case let .failed(reason): "Could not play: \(reason)"
        }
    }

    /// "Playing · 12:03 of 40:00".
    static func summary(for player: LibraryPlayer) -> String {
        let status = statusLine(for: player.status)
        guard player.item != nil, player.duration > 0 else { return status }
        return "\(status) · \(position(player.position, of: player.duration))"
    }

    static func position(_ seconds: Double, of total: Double) -> String {
        "\(LibraryClockFormat.duration(seconds)) of \(LibraryClockFormat.duration(total))"
    }

    static func rate(_ rate: Double) -> String {
        PlaybackSpeedText.rate(rate)
    }

    static let retry = "Retry playback"

    /// A pending start reads as activity, a failed one as a failure; otherwise the player's own tone.
    static func tone(for status: LibraryPlayer.Status, command: LibraryPlaybackCommandStatus?) -> WiltedStatusTone {
        guard let command else { return tone(for: status) }
        return command.isFailure ? .failure : .active
    }

    static func tone(for status: LibraryPlayer.Status) -> WiltedStatusTone {
        switch status {
        case .playing: .active
        case .paused, .idle: .neutral
        case .ended: .positive
        case .failed: .failure
        }
    }
}

/// One touch owns either a short skip or a load-bound hold on the existing control.
struct LibraryHeldSkipButton: View {
    @ObservedObject var player: LibraryPlayer
    let direction: LibrarySeekDirection
    let symbol: String
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var contact = false
    @State private var touchID: UUID?
    @State private var touchLoadID: String?
    @State private var thresholdTask: Task<Void, Never>?
    @State private var recognized = false
    @State private var holdID: UUID?
    @State private var loadID: String?

    var body: some View {
        // The drag owns physical touches; the native default accessibility action remains a skip.
        Button {} label: { Image(systemName: symbol) }
            .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .updating($contact) { _, state, _ in state = true }
                .onChanged { _ in startTouch() }
                .onEnded { _ in finishTouch() })
            .onChange(of: contact) { _, value in if !value { cancelTouch() } }
            .onChange(of: player.seekSessionID) { _, _ in cancelTouch() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { cancelTouch() } }
            .onDisappear { cancelTouch() }
    }

    private func tap() {
        if direction == .forward { player.skipForward() } else { player.skipBack() }
    }

    private func startTouch() {
        guard touchID == nil, let session = player.seekSessionID else { return }
        let id = UUID()
        touchID = id; touchLoadID = session; recognized = false
        thresholdTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled, touchID == id, contact, scenePhase == .active,
                  player.seekSessionID == session else { return }
            recognized = true; holdID = id; loadID = session
            _ = await player.beginOwnedSeeking(direction, holdID: id, sessionID: session)
        }
    }

    private func finishTouch() {
        guard touchID != nil else { return }
        let shouldTap = !recognized && touchLoadID == player.seekSessionID && scenePhase == .active
        cancelTouch()
        if shouldTap { tap() }
    }

    /// Contact reset is cancellation, so it cannot turn an interrupted hold into a tap.
    private func cancelTouch() {
        touchID = nil; touchLoadID = nil; recognized = false
        thresholdTask?.cancel(); thresholdTask = nil
        guard let id = holdID, let session = loadID else { return }
        holdID = nil; loadID = nil
        Task { @MainActor in _ = await player.endOwnedSeeking(direction, holdID: id, sessionID: session) }
    }
}
