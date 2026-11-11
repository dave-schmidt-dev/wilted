import SwiftUI
import WiltedLibrary

#if canImport(WiltedProducer)
/// Ad-removal feedback under the scrubber of every form of the Mac player (side pane, rail and
/// full window): "Ad here" at the playhead, and "Good cut" or "Not an ad" just after a cut. A press
/// is acknowledged at once, in words, with Undo (`WiltedMacModel+AdFeedback`); the entries wait in
/// Settings > Ad feedback for review.
struct WiltedMacAdFeedbackBar: View {
    @Bindable var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let acknowledgement = model.adFeedback.acknowledgement
        if model.offersAdFeedback || acknowledgement != nil {
            // One row where it fits. Narrower, the buttons wrap and the acknowledgement takes its
            // own line, so no button is pushed past the edge.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    buttons
                    Spacer(minLength: 0)
                    if let acknowledgement { status(acknowledgement) }
                }
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                    if model.offersAdFeedback { WiltedMacFlowLayout { buttons } }
                    if let acknowledgement {
                        HStack(spacing: WiltedTheme.Spacing.small) { status(acknowledgement) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-player-ad-feedback")
        }
    }

    @ViewBuilder private var buttons: some View {
        if model.offersAdFeedback {
            button(.adHere)
            if model.adFeedbackNearbyCut != nil {
                button(.goodCut)
                button(.notAnAd)
            }
        }
    }

    @ViewBuilder private func status(_ acknowledgement: WiltedMacAdFeedbackController.Acknowledgement) -> some View {
        let feedback = model.adFeedback
        Text(acknowledgement.text)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .accessibilityIdentifier("wilted-player-ad-feedback-status")
        if acknowledgement.saved {
            Button("Undo") { Task { await feedback.undo() } }
                .controlSize(.small)
                .disabled(feedback.isSaving)
                .help("Take back this feedback")
                .accessibilityIdentifier("wilted-player-ad-feedback-undo")
        }
    }

    private func button(_ kind: AdFeedbackKind) -> some View {
        Button { Task { await model.recordAdFeedback(kind) } } label: {
            Label(kind.title, systemImage: kind.systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.adFeedback.isSaving)
        .help(Self.help(kind))
        .accessibilityIdentifier("wilted-player-ad-feedback-\(kind.rawValue)")
    }

    static func help(_ kind: AdFeedbackKind) -> String {
        switch kind {
        case .adHere: "Mark an ad that is still in the audio at the playhead"
        case .goodCut: "The cut just played removed an ad"
        case .notAnAd: "The cut just played removed something that was not an ad"
        }
    }
}
#endif
