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
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                episode
                progress
                transport
                options
                status
            }
        }
        .navigationTitle("Now Playing")
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
            Button {
                model.skipBack()
            } label: {
                Image(systemName: "gobackward")
                    .font(.title3)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Skip back")

            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Button {
                model.skipForward()
            } label: {
                Image(systemName: "goforward")
                    .font(.title3)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Skip forward")
        }
        .disabled(!model.controlsEnabled)
    }

    private var options: some View {
        HStack(spacing: 8) {
            NavigationLink {
                SpeedListView(model: model)
            } label: {
                Label(Self.speedText(model.currentSpeed), systemImage: "speedometer")
                    .font(.caption)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .accessibilityLabel("Playback speed \(Self.speedText(model.currentSpeed))")

            NavigationLink {
                SleepListView(model: model)
            } label: {
                Label(sleepLabel, systemImage: "moon.zzz")
                    .font(.caption)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .accessibilityLabel("Sleep timer")
        }
        .disabled(!model.controlsEnabled)
    }

    private var sleepLabel: String {
        guard let sleep = model.snapshot?.sleep else { return "Sleep" }
        switch sleep {
        case .off:
            return "Sleep"
        case .untilDate:
            return "Sleep on"
        case .endOfEpisode:
            return "End of episode"
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
        "\(String(format: "%g", rate))\u{00D7}"
    }
}
