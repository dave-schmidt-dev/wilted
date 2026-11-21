import SwiftUI

/// The heading of one Feeds group, with its count; clicking it folds or opens the group.
struct WiltedMacFeedSectionHeader: View {
    let section: WiltedMacFeedSection
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: WiltedTheme.Spacing.xSmall) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(section.kind.title)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Text("\(section.subscriptions.count)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, WiltedTheme.Spacing.small)
        .accessibilityLabel("\(section.kind.title), \(section.subscriptions.count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("wilted-feeds-section-\(section.kind.rawValue)")
    }
}
