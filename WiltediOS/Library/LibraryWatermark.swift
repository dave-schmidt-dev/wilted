import SwiftUI
import WiltedDomain

/// A large lettuce, cropped by the bottom corner, drawn faintly over a page. The same mark sits
/// behind Settings and the Larder so the two read as one app. It never takes a touch.
struct LibraryWatermark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(.lettuce)
            .font(.system(size: 380))
            .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.09))
            .rotationEffect(.degrees(-14))
            .offset(x: 80, y: 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
