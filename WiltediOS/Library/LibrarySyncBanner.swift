import SwiftUI
import WiltedLibrary

/// The single sync status banner at the top of the Larder: one state at a time, so iCloud trouble is
/// never said twice (a "paused" line beside a "rate limiting" one). Every source of sync status
/// (the account review, the gate's wait and retry, and a failed fetch) resolves to one of these;
/// the Settings sync card reads the same precedence through `LibrarySettingsFormat.sync`.
enum LibrarySyncBanner: Equatable {
    /// The iCloud account changed; the replica is held until the listener decides.
    case accountReview
    /// iCloud pushed back: waiting for a future time, or retrying now (with an activity indicator).
    case throttle(text: String, retrying: Bool)
    /// A fetch failed for another reason.
    case problem(String)
    case publication

    /// Precedence: an account review blocks everything, then iCloud pushing back, then a plain failure.
    static func resolve(quarantined: Bool, throttleNotice: String?, retrying: Bool, error: String?) -> LibrarySyncBanner? {
        if quarantined { return .accountReview }
        if let throttleNotice { return .throttle(text: throttleNotice, retrying: retrying) }
        if let error { return .problem(error) }
        return nil
    }
}

struct LibrarySyncBannerView: View {
    let banner: LibrarySyncBanner
    var publicationSummary: String = "Mac publication unknown"
    var publicationDetail: String = "No account-associated Mac publication time is saved."
    var publicationQualifier: String? = nil
    let onRecover: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            WiltedPublicationNotice(summary: publicationSummary, detail: publicationDetail, qualifier: publicationQualifier)
            statusContent
        }
    }
    @ViewBuilder private var statusContent: some View {
        switch banner {
        case .publication: EmptyView()
        case .accountReview:
            WiltedAccountRecoveryNotice(role: .phone, action: onRecover)
        case let .throttle(text, retrying):
            HStack(spacing: WiltedTheme.Spacing.small) {
                // Live progress while the retry runs: a spinner, never the old time (no silent waits).
                if retrying {
                    ProgressView().accessibilityIdentifier("wilted-library-throttle-progress")
                } else {
                    Image(systemName: "hourglass").accessibilityHidden(true)
                }
                Text(text)
            }
            .wiltedFont(.utility)
            .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("wilted-library-throttle")
        case let .problem(text):
            Text(text)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
                .accessibilityIdentifier("wilted-library-error")
        }
    }
}
