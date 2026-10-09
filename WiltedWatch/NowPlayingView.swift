import Foundation
import SwiftUI

/// The Watch's Now Playing screen: the phone's current episode, its position,
/// the transport controls, and the speed and sleep menus.
///
/// The screen always renders the last snapshot and its age. While the phone is
/// unreachable the controls are disabled and a one-line note explains why; the
/// screen never blocks on the link or shows an error page.
struct NowPlayingView: View {
    /// The state the screen renders and controls.
    let model: WatchViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView { captureContent }
            .navigationTitle("Now Playing")
    }

    /// Shipping content, shared with the offscreen fixture renderer. Native
    /// ScrollView/navigation chrome is intentionally outside this seam.
    var captureContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            episode
            progress
            transport
            options
            status
        }
    }

    private var isPlaying: Bool { model.snapshot?.nowPlaying?.isPlaying == true }

    private var episode: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let playing = model.snapshot?.nowPlaying {
                Text(playing.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(playing.showTitle)
                    .font(.caption)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
            } else {
                Text("Nothing playing")
                    .font(.headline)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progress: some View {
        let playing = model.snapshot?.nowPlaying
        let position = playing?.positionSeconds ?? 0
        let duration = playing?.durationSeconds ?? 0
        let total = duration > 0 ? duration : max(position, 1)
        return VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: min(max(position, 0), total), total: total)
                .tint(WiltedTheme.color(.progress, scheme: colorScheme))
            HStack {
                Text(Self.timeText(position))
                Spacer()
                Text(duration > 0 ? Self.timeText(duration) : "--:--")
            }
            .font(.caption2)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            duration > 0
                ? "Position \(Self.timeText(position)) of \(Self.timeText(duration))"
                : "Position \(Self.timeText(position))"
        )
    }

    private var transport: some View {
        HStack(spacing: 12) {
            WatchHeldSkipButton(model: model, direction: .backward) {
                transportIcon("gobackward.\(model.snapshot?.skipBackSeconds ?? 15)", action: .skipBack)
                    .font(.title3)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canSend(.skipBack))
            .accessibilityLabel("Skip back \(model.snapshot?.skipBackSeconds ?? 15) seconds")
            .accessibilityValue(model.isPending(.skipBack) ? "Pending" : "")

            Button {
                model.togglePlayPause()
            } label: {
                transportIcon(isPlaying ? "pause.fill" : "play.fill", action: .toggle)
                    .font(.title3)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canSend(.toggle))
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityValue(model.isPending(.toggle) ? "Pending" : "")

            WatchHeldSkipButton(model: model, direction: .forward) {
                transportIcon("goforward.\(model.snapshot?.skipForwardSeconds ?? 30)", action: .skipForward)
                    .font(.title3)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canSend(.skipForward))
            .accessibilityLabel("Skip forward \(model.snapshot?.skipForwardSeconds ?? 30) seconds")
            .accessibilityValue(model.isPending(.skipForward) ? "Pending" : "")
        }
        .disabled(!model.controlsEnabled)
    }

    @ViewBuilder private func transportIcon(_ symbol: String, action: WatchCommand.Action) -> some View {
        if model.isPending(action) { Image(systemName: "hourglass").accessibilityLabel("Pending") }
        else { Image(systemName: symbol) }
    }

    private var options: some View {
        HStack(spacing: 8) {
            NavigationLink {
                SpeedListView(model: model)
            } label: {
                Label {
                    Text(Self.speedText(model.currentSpeed))
                } icon: {
                    if model.hasPendingSpeed { Image(systemName: "hourglass").accessibilityLabel("Pending") } else { Image(systemName: "speedometer") }
                }
                    .font(.caption)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .accessibilityLabel("Playback speed \(Self.speedText(model.currentSpeed))")
            .accessibilityValue(model.hasPendingSpeed ? "Pending" : "")

            NavigationLink {
                SleepListView(model: model)
            } label: {
                Label {
                    sleepLabel
                } icon: {
                    if model.hasPendingSleep { Image(systemName: "hourglass").accessibilityLabel("Pending") } else { Image(systemName: "moon.zzz") }
                }
                    .font(.caption)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .accessibilityLabel("Sleep timer")
            .accessibilityValue(model.hasPendingSleep ? "Pending" : "")
        }
        .disabled(!model.controlsEnabled)
    }

    @ViewBuilder private var sleepLabel: some View {
        switch model.snapshot?.sleep ?? .off {
        case .off: Text("Sleep")
        case let .untilDate(deadline):
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                if model.activeSleepDeadline(at: timeline.date) != nil {
                    Text(deadline, style: .timer)
                        .monospacedDigit()
                } else { Text("Sleep ended") }
            }
        case .endOfEpisode: Text("End of episode")
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let note = model.unreachableNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            Text(model.ageText)
                .font(.caption2)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func timeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func speedText(_ rate: Double) -> String {
        PlaybackSpeedText.rate(rate)
    }
}

/// One Watch touch owns a short skip or a hold; the phone still owns all movement.
struct WatchHeldSkipButton<Label: View>: View {
    let model: WatchViewModel
    let direction: WatchCommand.SeekDirection
    @ViewBuilder let label: () -> Label
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var contact = false
    @State private var touchID: UUID?
    @State private var touchLoadID: String?
    @State private var touchControlSessionID: UUID?
    @State private var thresholdTask: Task<Void, Never>?
    @State private var recognized = false
    @State private var holdID: UUID?

    var body: some View {
        Button {} label: { label() }.contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .updating($contact) { _, state, _ in state = true }
                .onChanged { _ in startTouch() }
                .onEnded { _ in finishTouch() })
            .onChange(of: contact) { _, value in if !value { cancelTouch() } }
            .onChange(of: model.snapshot?.nowPlaying?.seekSessionID) { _, _ in cancelTouch() }
            .onChange(of: model.snapshot?.controlSessionID) { _, _ in cancelTouch() }
            .onChange(of: model.controlsEnabled) { _, value in if !value { cancelTouch() } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { cancelTouch() } }
            .onDisappear { cancelTouch() }
    }

    private func tap() {
        if direction == .forward { _ = model.skipForward() } else { _ = model.skipBack() }
    }

    private func startTouch() {
        guard touchID == nil, model.controlsEnabled,
              let load = model.snapshot?.nowPlaying?.seekSessionID,
              let session = model.snapshot?.controlSessionID else { return }
        let id = UUID()
        touchID = id; touchLoadID = load; touchControlSessionID = session; recognized = false
        thresholdTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled, touchID == id, contact, scenePhase == .active,
                  model.snapshot?.nowPlaying?.seekSessionID == load,
                  model.snapshot?.controlSessionID == session else { return }
            recognized = true
            if model.beginHold(direction), case let .seek(_, _, heldID, _, _, _) = model.heldAction {
                holdID = heldID
            }
        }
    }

    private func finishTouch() {
        guard touchID != nil else { return }
        let shouldTap = !recognized && scenePhase == .active
            && touchLoadID == model.snapshot?.nowPlaying?.seekSessionID
            && touchControlSessionID == model.snapshot?.controlSessionID
        cancelTouch()
        if shouldTap { tap() }
    }

    private func cancelTouch() {
        touchID = nil; touchLoadID = nil; touchControlSessionID = nil; recognized = false
        thresholdTask?.cancel(); thresholdTask = nil
        if let id = holdID { holdID = nil; model.endHold(holdID: id) }
    }
}
