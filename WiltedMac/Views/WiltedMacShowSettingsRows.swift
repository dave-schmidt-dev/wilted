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
