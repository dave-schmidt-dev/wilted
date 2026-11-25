import SwiftUI

/// The same quiet saved-time line on the shelf and in the player.
struct WiltedMacSavedTimeLine: View {
    let text: String?
    let identifier: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let text {
            Text(text)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .lineLimit(1)
                .accessibilityIdentifier(identifier)
        }
    }
}
