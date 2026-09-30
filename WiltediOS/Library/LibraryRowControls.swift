import SwiftUI
import WiltedDomain
import WiltedLibrary

/// A round icon button: a Wilted-coloured SF Symbol in a 44 pt target, named for VoiceOver.
/// Every Larder and episode control is one of these, so they read as a single family.
struct LibraryIconButton: View {
    let symbol: String
    let label: String
    let identifier: String
    var tone: WiltedStatusTone = .active
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.wiltedTextScale) private var textScale

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: WiltedTheme.scaled(24, scale: textScale)))
                .foregroundStyle(color)
                .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// Leaf green for an action, muted for a quiet or destructive one.
    private var color: Color {
        tone == .neutral ? WiltedTheme.color(.secondaryText, scheme: colorScheme) : WiltedTheme.color(.wiltedLeaf, scheme: colorScheme)
    }
}

/// The download control for one episode. Its symbol is the state: a download arrow to fetch, a
/// ring with a stop while it moves, a trash can once the audio is on the phone. Delete asks first.
struct LibraryDownloadControl: View {
    let entryID: ItemID
    let state: LibraryMediaState
    let perform: (LibraryMediaAction) -> Void
    @Binding var isConfirmingDelete: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch state {
        case .available:
            icon("arrow.down.circle", "Download to phone", .request, id: "get")
        case .requested, .downloading:
            ZStack {
                ring
                LibraryIconButton(
                    symbol: "xmark", label: "Cancel download",
                    identifier: "wilted-library-media-cancel-\(entryID.rawValue)") { perform(.cancel) }
                    .imageScale(.small)
            }
        case .verifying:
            ProgressView()
                .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                .accessibilityLabel("Verifying download")
        case .onPhone:
            LibraryIconButton(
                symbol: "trash", label: "Delete download", identifier: "wilted-library-media-remove-\(entryID.rawValue)",
                tone: .neutral) { isConfirmingDelete = true }
        case .failed:
            icon("arrow.clockwise.circle", "Retry download", .request, id: "retry")
        case .notPrepared:
            icon("arrow.clockwise.circle", "Check again", .request, id: "retry")
        }
    }

    private func icon(_ symbol: String, _ label: String, _ action: LibraryMediaAction, id: String) -> some View {
        LibraryIconButton(symbol: symbol, label: label, identifier: "wilted-library-media-\(id)-\(entryID.rawValue)") { perform(action) }
    }

    /// Progress drawn around the stop button; an unknown total shows a plain track.
    private var ring: some View {
        let leaf = WiltedTheme.color(.wiltedLeaf, scheme: colorScheme)
        return ZStack {
            Circle().stroke(leaf.opacity(0.2), lineWidth: 3)
            if let fraction = state.fraction {
                Circle().trim(from: 0, to: fraction)
                    .stroke(leaf, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView()
            }
        }
        .frame(width: 32, height: 32)
    }
}

/// One line of words under the controls while something is moving or has gone wrong: transfer
/// progress, a failure, or a decision waiting on the Mac. Silent when everything is at rest, so the
/// row stays quiet. State is always spelled out, never carried by color alone.
struct LibraryStatusLine: View {
    let entryID: ItemID
    let media: LibraryMediaState?
    let decision: LibraryDecisionStatus?
    let cancelDecision: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            if let media, showsMedia(media) { mediaLine(media) }
            if let decision { decisionLine(decision) }
        }
    }

    private func showsMedia(_ state: LibraryMediaState) -> Bool {
        switch state {
        case .available, .onPhone: false
        default: true
        }
    }

    /// Re-evaluated every second while a transfer runs so the elapsed time keeps moving.
    @ViewBuilder private func mediaLine(_ state: LibraryMediaState) -> some View {
        if let start = state.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                text(state.statusText(elapsed: max(0, context.date.timeIntervalSince(start))), tone(state))
            }
        } else {
            text(state.statusText(), tone(state))
        }
    }

    private func decisionLine(_ status: LibraryDecisionStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.medium) {
            text(status.text, tone(status)).accessibilityIdentifier("wilted-library-action-status-\(entryID.rawValue)")
            Spacer(minLength: 0)
            if status == .pendingOnMac {
                Button(action: cancelDecision) { Text("Stop waiting").wiltedFont(.utility) }
                    .buttonStyle(.plain)
                    .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-library-action-cancel-\(entryID.rawValue)")
            }
        }
    }

    private func text(_ string: String, _ tone: WiltedStatusTone) -> some View {
        Text(string)
            .wiltedFont(.utility)
            .foregroundStyle(tone.color(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("wilted-library-media-status-\(entryID.rawValue)")
    }

    private func tone(_ state: LibraryMediaState) -> WiltedStatusTone {
        switch state {
        case .requested, .downloading, .verifying: .active
        case .failed: .failure
        case .notPrepared: .caution
        case .available, .onPhone: .neutral
        }
    }

    private func tone(_ status: LibraryDecisionStatus) -> WiltedStatusTone {
        switch status {
        case .waiting, .confirming: .active
        case .pendingOnMac: .caution
        case .failed: .failure
        }
    }
}
