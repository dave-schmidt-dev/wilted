import SwiftUI

/// The position bar on Now Playing, full and mini: drag it (or tap a point) to choose a time. The time
/// under the finger shows live and playback does not move until the finger lifts, then the shared
/// `LibraryPlayer` seeks once, so position sync and the lock screen follow. VoiceOver adjusts it by the
/// skip lengths. The pure mapping is `position(forX:width:duration:)`.
struct LibraryScrubber: View {
    @ObservedObject var player: LibraryPlayer
    /// The time being chosen while a finger is down, nil otherwise; the parent reads it to show the time.
    @Binding var scrubPosition: Double?
    /// The mini player's thin line: no thumb.
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    /// The track is thin; the touch area is at least this tall (`minimumTouchTarget` when full).
    static let compactHeight: CGFloat = 24

    /// Seconds into the episode for a touch `x` points from the track's left edge, clamped to the episode.
    static func position(forX x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval {
        guard width > 0, duration > 0, x.isFinite else { return 0 }
        return min(max(Double(x / width), 0), 1) * duration
    }

    /// How much of the track is filled, 0 to 1.
    static func fraction(_ position: TimeInterval, of duration: TimeInterval) -> Double {
        guard duration > 0, position.isFinite else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    private var isEnabled: Bool { player.item != nil && player.duration > 0 }
    private var shown: Double { scrubPosition ?? player.position }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let filled = width * Self.fraction(shown, of: player.duration)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WiltedTheme.color(.secondaryText, scheme: colorScheme).opacity(0.25))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(WiltedTheme.color(.progress, scheme: colorScheme))
                    .frame(width: filled, height: trackHeight)
                if !compact {
                    Circle()
                        .fill(WiltedTheme.color(.progress, scheme: colorScheme))
                        .frame(width: scrubPosition == nil ? 16 : 24, height: scrubPosition == nil ? 16 : 24)
                        .offset(x: min(max(filled - 8, 0), max(width - 16, 0)))
                }
            }
            .frame(width: width, height: geometry.size.height, alignment: compact ? .top : .center)
            .contentShape(Rectangle())
            .gesture(drag(width: width))
        }
        .frame(height: compact ? Self.compactHeight : WiltedTheme.Spacing.minimumTouchTarget)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(LibraryPlayerText.position(shown, of: player.duration))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: player.skipForward()
            case .decrement: player.skipBack()
            @unknown default: break
            }
        }
        .accessibilityIdentifier(compact ? "wilted-player-mini-scrubber" : "wilted-player-scrubber")
    }

    private var trackHeight: CGFloat { compact ? 3 : 6 }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled else { return }
                scrubPosition = Self.position(forX: value.location.x, width: width, duration: player.duration)
            }
            .onEnded { value in
                defer { scrubPosition = nil }
                guard isEnabled else { return }
                player.seek(to: Self.position(forX: value.location.x, width: width, duration: player.duration))
            }
    }
}
