import SwiftUI
import WiltedDomain
import WiltedLibrary

/// Ad-removal feedback under the full player's transport: "Ad here" at the playhead, and "Good cut"
/// or "Not an ad" just after a cut. A press is acknowledged at once, in words, with Undo for as long
/// as it can still be taken back (`LibraryAppModel+AdFeedback`).
struct LibraryAdFeedbackBar: View {
    @ObservedObject var model: LibraryAppModel
    @ObservedObject var player: LibraryPlayer
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let kinds = model.adFeedbackKinds(for: player.item, at: player.position)
        if !kinds.isEmpty || model.adFeedbackAcknowledgement != nil {
            VStack(spacing: WiltedTheme.Spacing.xSmall) {
                HStack(spacing: WiltedTheme.Spacing.large) {
                    ForEach(kinds, id: \.self) { kind in
                        Button { record(kind) } label: {
                            Label(kind.title, systemImage: kind.systemImage)
                                .wiltedFont(.utility)
                                .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("wilted-player-ad-feedback-\(kind.rawValue)")
                    }
                }
                if let acknowledgement = model.adFeedbackAcknowledgement {
                    HStack(spacing: WiltedTheme.Spacing.small) {
                        Text(acknowledgement.text)
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .accessibilityIdentifier("wilted-player-ad-feedback-status")
                        if !acknowledgement.intentID.isEmpty {
                            Button("Undo") { model.undoAdFeedback() }
                                .wiltedFont(.utility)
                                .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                                .accessibilityIdentifier("wilted-player-ad-feedback-undo")
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-player-ad-feedback")
        }
    }

    private func record(_ kind: AdFeedbackKind) {
        guard let item = player.item else { return }
        model.recordAdFeedback(kind, item: item, playedSeconds: player.position)
    }
}
