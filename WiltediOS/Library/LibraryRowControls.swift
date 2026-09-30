import SwiftUI
import WiltedDomain
import WiltedLibrary

/// The decision line of a row: its buttons, or the state of the decision in flight. The state is
/// spelled out, never carried by color alone.
struct LibraryDecisionControl: View {
    let entryID: ItemID
    let actions: [LibraryDecisionAction]
    let status: LibraryDecisionStatus?
    let perform: (LibraryDecisionAction) -> Void
    let cancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !actions.isEmpty || status != nil {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                if let status { statusLine(status) }
                if !actions.isEmpty {
                    HStack(spacing: WiltedTheme.Spacing.medium) {
                        ForEach(actions, id: \.identifier) { action in
                            Button(action.title, systemImage: action.systemImage) { perform(action) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                                .accessibilityIdentifier("wilted-library-action-\(action.identifier)-\(entryID.rawValue)")
                        }
                    }
                }
            }
            .padding(.top, WiltedTheme.Spacing.xSmall)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-library-action-\(entryID.rawValue)")
        }
    }

    private func statusLine(_ status: LibraryDecisionStatus) -> some View {
        HStack(alignment: .center, spacing: WiltedTheme.Spacing.medium) {
            Label {
                Text(status.text)
                    .wiltedFont(.utility)
                    .foregroundStyle(tone(status).color(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol(status)).foregroundStyle(tone(status).color(colorScheme))
            }
            .accessibilityIdentifier("wilted-library-action-status-\(entryID.rawValue)")
            Spacer(minLength: 0)
            if status == .pendingOnMac {
                Button("Stop waiting", action: cancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-library-action-cancel-\(entryID.rawValue)")
            }
        }
    }

    private func tone(_ status: LibraryDecisionStatus) -> WiltedStatusTone {
        switch status {
        case .waiting, .confirming: .active
        case .pendingOnMac: .caution
        case .failed: .failure
        }
    }

    private func symbol(_ status: LibraryDecisionStatus) -> String {
        switch status {
        case .waiting: "clock"
        case .confirming: "checkmark.circle"
        case .pendingOnMac: "exclamationmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// The audio line of a Larder row: what state the episode's audio is in, live progress while it
/// moves, and the one action that fits. The state is always spelled out, never carried by color alone.
struct LibraryMediaControl: View {
    let entryID: ItemID
    let state: LibraryMediaState
    let perform: (LibraryMediaAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            HStack(alignment: .center, spacing: WiltedTheme.Spacing.medium) {
                status
                Spacer(minLength: 0)
                action
            }
            progress
        }
        .padding(.top, WiltedTheme.Spacing.xSmall)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-media-\(entryID.rawValue)")
    }

    /// Re-evaluated every second while a transfer runs so the elapsed time keeps moving.
    @ViewBuilder private var status: some View {
        if let start = state.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                statusText(elapsed: context.date.timeIntervalSince(start))
            }
        } else {
            statusText(elapsed: 0)
        }
    }

    private func statusText(elapsed: TimeInterval) -> some View {
        Label {
            Text(state.statusText(elapsed: max(0, elapsed)))
                .wiltedFont(.utility)
                .foregroundStyle(tone.color(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tone.color(colorScheme))
        }
        .accessibilityIdentifier("wilted-library-media-status-\(entryID.rawValue)")
    }

    @ViewBuilder private var progress: some View {
        switch state {
        case .downloading:
            if let fraction = state.fraction { ProgressView(value: fraction) } else { ProgressView() }
        case .requested, .verifying:
            ProgressView()
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .available: button("Get audio", .request, id: "get", symbol: "arrow.down.circle")
        case .requested, .downloading: button("Cancel", .cancel, id: "cancel")
        case .verifying: EmptyView()
        case .onPhone: button("Remove from phone", .removeFromPhone, id: "remove")
        case .failed: button("Retry", .request, id: "retry")
        case .notPrepared: button("Check again", .request, id: "retry")
        }
    }

    private func button(_ title: String, _ action: LibraryMediaAction, id: String, symbol: String? = nil) -> some View {
        Button { perform(action) } label: {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            .accessibilityIdentifier("wilted-library-media-\(id)-\(entryID.rawValue)")
    }

    private var tone: WiltedStatusTone {
        switch state {
        case .available: .neutral
        case .requested, .downloading, .verifying: .active
        case .onPhone: .positive
        case .failed: .failure
        case .notPrepared: .caution
        }
    }

    private var symbol: String {
        switch state {
        case .available: "icloud.and.arrow.down"
        case .requested: "clock"
        case .downloading, .verifying: "arrow.down.circle"
        case .onPhone: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .notPrepared: "exclamationmark.circle"
        }
    }
}
