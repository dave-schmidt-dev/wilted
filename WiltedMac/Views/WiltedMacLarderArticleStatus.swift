import SwiftUI

/// The article preparation currently in flight, or a finished run the owner
/// can retry or dismiss. It sits once at the top of the Larder list rather
/// than on a row: an article has no Larder row until its audio is ready.
struct WiltedMacLarderArticlePreparationRow: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let preparation = model.larderArticlePreparation {
            HStack(spacing: WiltedTheme.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preparation.phase.title)
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    Text(preparation.detail)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let fraction = preparation.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 80)
                        .accessibilityLabel(preparation.phase.title)
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                        .accessibilityIdentifier("wilted-larder-article-preparation-progress")
                } else if !preparation.phase.isTerminal {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(preparation.phase.title)
                        .accessibilityIdentifier("wilted-larder-article-preparation-progress")
                }
                if preparation.cancellable {
                    Button("Cancel") { model.cancelPreparation() }
                        .accessibilityIdentifier("wilted-larder-article-preparation-cancel")
                }
                if preparation.phase == .failed {
                    Button("Retry") { model.retryArticlePreparation() }
                        .accessibilityIdentifier("wilted-larder-article-preparation-retry")
                }
                if preparation.phase == .cancelled || preparation.phase == .failed {
                    Button("Dismiss") { model.dismissArticlePreparation() }
                        .accessibilityIdentifier("wilted-larder-article-preparation-dismiss")
                }
            }
            .padding(.vertical, WiltedTheme.Spacing.small)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-larder-article-preparation")
        }
    }
}
