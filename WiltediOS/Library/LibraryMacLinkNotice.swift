import SwiftUI

/// The Larder's one notice while the Mac has not linked this device: the Mac reads requests only from a
/// device it knows, so until it does, no download can be answered and the rows offer none. A spinner shows
/// that the phone is working on it; the notice leaves, and the downloads return, when the link arrives.
struct LibraryMacLinkNotice: View {
    /// "iPad" or "iPhone".
    let deviceKind: String
    @Environment(\.colorScheme) private var colorScheme

    static let title = "Connecting to your Mac"

    static func detail(deviceKind: String) -> String {
        "Downloads start once your Mac links this \(deviceKind). Keep Wilted open on your Mac."
    }

    var body: some View {
        HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
            ProgressView()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text(Self.title).wiltedFont(.body)
                Text(Self.detail(deviceKind: deviceKind))
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wilted-library-mac-link-notice")
    }
}
