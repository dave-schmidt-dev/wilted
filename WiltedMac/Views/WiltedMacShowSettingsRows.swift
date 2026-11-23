import SwiftUI

/// One preference on a show's settings page, with its inherited value and reset action.
struct WiltedMacShowSettingRow<Control: View>: View {
    let title: String
    let defaultValue: String
    var detail: String? = nil
    let isOverridden: Bool
    let resetIdentifier: String
    let resetLabel: String
    let control: Control
    let reset: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: WiltedTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                HStack(spacing: WiltedTheme.Spacing.xSmall) {
                    if isOverridden {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    Text(title).wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    if isOverridden {
                        Button("Reset", action: reset)
                            .buttonStyle(.borderless)
                            .accessibilityLabel(resetLabel)
                            .accessibilityIdentifier(resetIdentifier)
                    }
                }
                Text("Default: \(defaultValue)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                if let detail {
                    Text(detail)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: WiltedTheme.Spacing.large)
            control
        }
        .accessibilityElement(children: .contain)
    }
}

struct WiltedMacShowSettingsResetControl: View {
    let board: WiltedMacFeedPolicyBoard
    let feedID: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var undo: WiltedMacShowSettingsResetUndo?
    @State private var undoFailed = false
    @State private var isUndoing = false

    private var customizedNames: [String] { board.customizedSettingNames(for: feedID) }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            if !customizedNames.isEmpty {
                Text("Customized: \(customizedNames.joined(separator: ", "))")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-show-settings-customized-list")
                Button("Reset all") {
                    undo = board.resetAllOverrides(for: feedID)
                    undoFailed = false
                }
                .disabled(isUndoing)
                .accessibilityIdentifier("wilted-show-settings-reset-all")
            }
            if let undo {
                HStack(spacing: WiltedTheme.Spacing.medium) {
                    Text(undoFailed ? "Settings could not be restored. Try Undo again." : "Settings reset.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-show-settings-reset-status")
                    Spacer()
                    Button(isUndoing ? "Undoing…" : "Undo") { undoReset(undo) }
                        .disabled(isUndoing)
                        .accessibilityIdentifier("wilted-show-settings-reset-undo")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func undoReset(_ undo: WiltedMacShowSettingsResetUndo) {
        guard !isUndoing else { return }
        isUndoing = true
        Task {
            let restored = await board.undoResetAllOverrides(undo)
            undoFailed = !restored
            if restored { self.undo = nil }
            isUndoing = false
        }
    }
}

struct WiltedMacRestoreCutEpisodesControl: View {
    let board: WiltedMacFeedPolicyBoard
    let feedID: String
    let showTitle: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmedCandidateIDs: [String]?
    @State private var candidatesChanged = false

    private var candidateIDs: [String] { board.restorableCutEpisodeIDs(feedID) }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            if board.isAdFree(feedID), !candidateIDs.isEmpty {
                Button(Self.title(count: candidateIDs.count)) {
                    candidatesChanged = false
                    confirmedCandidateIDs = candidateIDs
                }
                .disabled(!board.isLoaded(feedID))
                .accessibilityLabel(
                    "Restore \(candidateIDs.count) cut "
                        + "\(candidateIDs.count == 1 ? "episode" : "episodes") of \(showTitle)"
                )
                .accessibilityIdentifier("wilted-feed-policy-restore-cuts")
                .confirmationDialog(
                    confirmationTitle,
                    isPresented: Binding(
                        get: { confirmedCandidateIDs != nil },
                        set: { if !$0 { confirmedCandidateIDs = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    if let confirmedCandidateIDs {
                        Button(Self.confirmationActionTitle(count: confirmedCandidateIDs.count)) {
                            self.confirmedCandidateIDs = nil
                            candidatesChanged = !board.restoreCuts(
                                for: feedID, candidateIDs: confirmedCandidateIDs
                            )
                        }
                    }
                    Button("Cancel", role: .cancel) { confirmedCandidateIDs = nil }
                }
                Text(
                    "Wilted cut these before you marked the show ad-free. It downloads each original again "
                    + "and puts back what was cut. Your place in each is kept."
                )
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            }
            if candidatesChanged {
                Text("The eligible episodes changed. Check the updated count and confirm again.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feed-policy-restore-count-changed")
            }
        }
    }

    static func title(count: Int) -> String {
        count == 1 ? "Restore 1 Cut Episode" : "Restore \(count) Cut Episodes"
    }

    static func confirmationTitle(count: Int) -> String {
        count == 1 ? "Restore 1 cut episode?" : "Restore \(count) cut episodes?"
    }

    static func confirmationActionTitle(count: Int) -> String {
        count == 1 ? "Restore 1 Episode" : "Restore \(count) Episodes"
    }

    private var confirmationTitle: String {
        guard let confirmedCandidateIDs else { return "Restore cut episodes?" }
        return Self.confirmationTitle(count: confirmedCandidateIDs.count)
    }
}
