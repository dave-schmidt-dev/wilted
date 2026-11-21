import SwiftUI

/// Every destination opens with its own name, at one weight, in one place.
/// Three different title treatments across the two apps is what let a
/// composer heading pass for a destination heading.
struct WiltedMacDestination<Content: View, TitleAccessory: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let identifier: String
    /// The reading column's cap. Nil fills the region it is given, for a
    /// destination that is itself one pane of a wider composition.
    var contentWidth: CGFloat? = 760
    var inset: CGFloat = WiltedTheme.Spacing.section
    /// The lettuce over the page, as on iOS's Larder and Settings. It sits over
    /// the scroll view's frame, so it never moves with the text or under the pane.
    var watermark = false
    /// Where the page was scrolled to, by the id of the top visible block. The blocks of `content`
    /// carry `.id`s; an id the page no longer has scrolls nowhere.
    var scrollAnchor: Binding<String?>?
    /// Controls that belong to the destination itself, beside its name: a
    /// playlist's rename and delete. The name still renders exactly once.
    @ViewBuilder let titleAccessory: TitleAccessory
    @ViewBuilder let content: Content
    /// Where the destination's rows begin, as the content reports it: the
    /// lettuce sits below everything above them.
    @State private var rowsTop: CGFloat = 0
    static var topAnchor: String { "destination-top" }

    init(
        title: String, identifier: String,
        contentWidth: CGFloat? = 760, inset: CGFloat = WiltedTheme.Spacing.section,
        watermark: Bool = false, scrollAnchor: Binding<String?>? = nil,
        @ViewBuilder content: () -> Content
    ) where TitleAccessory == EmptyView {
        self.title = title
        self.identifier = identifier
        self.contentWidth = contentWidth
        self.inset = inset
        self.watermark = watermark
        self.scrollAnchor = scrollAnchor
        self.titleAccessory = EmptyView()
        self.content = content()
    }

    init(
        title: String, identifier: String,
        contentWidth: CGFloat? = 760, inset: CGFloat = WiltedTheme.Spacing.section,
        watermark: Bool = false, scrollAnchor: Binding<String?>? = nil,
        @ViewBuilder titleAccessory: () -> TitleAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.identifier = identifier
        self.contentWidth = contentWidth
        self.inset = inset
        self.watermark = watermark
        self.scrollAnchor = scrollAnchor
        self.titleAccessory = titleAccessory()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xLarge) {
                HStack(alignment: .center, spacing: WiltedTheme.Spacing.small) {
                    Text(title)
                        .wiltedFont(.display)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    titleAccessory
                }
                .id(Self.topAnchor)
                content
            }
            .scrollTargetLayout()
            .frame(maxWidth: contentWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(inset)
            .coordinateSpace(name: WiltedMacRowsTopKey.space)
            .onPreferenceChange(WiltedMacRowsTopKey.self) { rowsTop = $0 }
        }
        .scrollPosition(id: scrollAnchor ?? .constant(nil), anchor: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        // Over the rows, as on iOS, whose list rows are opaque cards: behind
        // them the lettuce would never show. Faint and untouchable, so text
        // contrast and clicks are unaffected.
        .overlay { if watermark { LibraryWatermark(fitting: true, topInset: rowsTop) } }
        .accessibilityIdentifier(identifier)
    }
}

/// Where a destination's rows begin, measured from the top of its scrolled
/// content, which is where the viewport starts before any scrolling.
struct WiltedMacRowsTopKey: PreferenceKey {
    static let space = "wilted-destination-content"
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Marks the start of a destination's rows for its watermark.
    func wiltedMarksRowsTop() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WiltedMacRowsTopKey.self,
                    value: proxy.frame(in: .named(WiltedMacRowsTopKey.space)).minY)
            }
        }
    }
}
