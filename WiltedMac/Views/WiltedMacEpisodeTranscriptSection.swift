import SwiftUI

/// The Transcript half of an episode info popover: the saved transcript when
/// there is one, and an honest state when there is not, including Retry for a
/// read that failed.
///
/// The read itself belongs to the popover, which owns the loaded value for as
/// long as it is open, so switching to Notes and back does not read the store
/// twice. This section only draws that value.
struct WiltedMacEpisodeTranscriptSection: View {
    let id: String
    let prefix: String
    /// nil while the first read is still running.
    let load: WiltedMacEpisodeTranscriptLoad?
    let retry: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            switch load {
            case nil:
                loading
            case .loaded(let transcript):
                if transcript.isReadable, let text = transcript.text {
                    Text(text)
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("\(prefix)-transcript-text-\(id)")
                } else {
                    neutral
                }
            case .some(.none):
                neutral
            case .failed:
                failure
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loading: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            ProgressView().controlSize(.small)
            Text("Loading transcript…")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(prefix)-transcript-loading-\(id)")
    }

    /// A saved record that carries no readable text lands here too: it is
    /// still a transcript the episode does not have, not an error to retry.
    private var neutral: some View {
        Text("No transcript was saved for this episode.")
            .wiltedFont(.body)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("\(prefix)-transcript-none-\(id)")
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Could not read the saved transcript.")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", action: retry)
                .accessibilityIdentifier("\(prefix)-notes-retry-\(id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(prefix)-transcript-error-\(id)")
    }
}
