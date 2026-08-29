import SwiftUI

/// Surface geometry shared by the Mac producer and the iPhone listener.
///
/// Before this existed the two apps carried three independent card
/// treatments — `WiltedMacCard`, the listener's square `Rectangle().stroke`
/// rows, and the listener's rounded settings cards — so the same concept drew
/// three different shapes. Geometry lives here so a change reaches both apps.
public extension WiltedTheme {
    enum Radius {
        /// Cards, settings groups, and article rows.
        public static let card: CGFloat = 8
        /// Text fields and other inline controls.
        public static let control: CGFloat = 6
    }
}

/// The one card treatment: a `.card` fill with a hairline `.steel` edge.
public struct WiltedCardModifier: ViewModifier {
    let colorScheme: ColorScheme
    let padding: CGFloat

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                WiltedTheme.color(.card, scheme: colorScheme),
                in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WiltedTheme.Radius.card)
                    .stroke(WiltedTheme.color(.steel, scheme: colorScheme), lineWidth: 1)
            )
    }
}

public extension View {
    /// Applies the shared Wilted card surface.
    func wiltedCard(_ colorScheme: ColorScheme, padding: CGFloat = WiltedTheme.Spacing.large) -> some View {
        modifier(WiltedCardModifier(colorScheme: colorScheme, padding: padding))
    }
}

/// The meaning a status line carries, independent of the color that renders it.
///
/// `W-INV-010` requires that color never carry state alone, so this maps to a
/// token rather than to a literal color, and callers pair it with text. Both
/// apps previously wrote this switch inline — the listener wrote it twice.
public enum WiltedStatusTone: Sendable {
    case neutral
    case active
    case positive
    case caution
    case failure

    public func color(_ scheme: ColorScheme) -> Color {
        switch self {
        case .neutral: WiltedTheme.color(.secondaryText, scheme: scheme)
        case .active: WiltedTheme.color(.progress, scheme: scheme)
        case .positive: WiltedTheme.color(.success, scheme: scheme)
        case .caution: WiltedTheme.color(.stale, scheme: scheme)
        case .failure: WiltedTheme.color(.error, scheme: scheme)
        }
    }
}

/// A labelled value row. Shared so the Mac Settings destination and the
/// listener Settings tab cannot drift apart in spacing, weight, or alignment.
public struct WiltedSettingsRow: View {
    @Environment(\.colorScheme) private var colorScheme
    private let label: String
    private let value: String
    private let identifier: String
    private let tone: WiltedStatusTone

    public init(
        _ label: String,
        value: String,
        identifier: String,
        tone: WiltedStatusTone = .neutral
    ) {
        self.label = label
        self.value = value
        self.identifier = identifier
        self.tone = tone
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.medium) {
            Text(label)
                .font(WiltedTheme.font(.body))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Spacer(minLength: WiltedTheme.Spacing.large)
            Text(value)
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(tone.color(colorScheme))
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
        // Also carried as a value. AppKit and UIKit disagree about which field
        // a combined SwiftUI element surfaces its text through, so a row that
        // reads correctly on iPhone was unreadable to macOS automation.
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }
}

/// The explicit account-review gate.
///
/// Neither app silently adopts a changed iCloud account: local work is
/// quarantined and stays quarantined until this is pressed. The Mac had this
/// control from the start; the listener showed a non-retryable red line and no
/// way out, so a quarantined iPhone was a dead end. Shared so the wording and
/// the gating cannot diverge again.
public struct WiltedAccountRecoveryNotice: View {
    @Environment(\.colorScheme) private var colorScheme
    private let identifier: String
    private let action: () -> Void

    public init(identifier: String = WiltedScreenCopy.useCurrentAccountIdentifier, action: @escaping () -> Void) {
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text(WiltedScreenCopy.useCurrentAccountDetail)
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Button(WiltedScreenCopy.useCurrentAccount, action: action)
                .buttonStyle(.borderedProminent)
                .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, WiltedTheme.Spacing.xSmall)
    }
}

/// The transcript disclosure, in primitives so both apps render it identically.
///
/// The listener and the producer read transcripts from different types, so this
/// deliberately takes resolved strings rather than a domain value. When text is
/// missing it says why instead of rendering nothing.
public struct WiltedTranscriptSection: View {
    @Environment(\.colorScheme) private var colorScheme
    private let isReadable: Bool
    private let title: String
    private let text: String?
    private let unavailableLabel: String
    private let identifier: String

    public init(
        isReadable: Bool,
        title: String,
        text: String?,
        unavailableLabel: String,
        identifier: String
    ) {
        self.isReadable = isReadable
        self.title = title
        self.text = text
        self.unavailableLabel = unavailableLabel
        self.identifier = identifier
    }

    public var body: some View {
        Group {
            if isReadable, let text {
                DisclosureGroup(title) {
                    Text(text)
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .textSelection(.enabled)
                        .padding(.top, WiltedTheme.Spacing.small)
                }
                .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            } else {
                Label(unavailableLabel, systemImage: "doc.text.magnifyingglass")
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }
}

/// A persistent transcript panel for constrained playback surfaces.
///
/// The player keeps transport controls outside this scroll view, so reading a
/// long article never scrolls those controls away. The panel fills only the
/// height its parent reserves and owns its own vertical scrolling.
public struct WiltedTranscriptPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    private let isReadable: Bool
    private let title: String
    private let text: String?
    private let unavailableLabel: String
    private let identifier: String

    public init(
        isReadable: Bool,
        title: String,
        text: String?,
        unavailableLabel: String,
        identifier: String
    ) {
        self.isReadable = isReadable
        self.title = title
        self.text = text
        self.unavailableLabel = unavailableLabel
        self.identifier = identifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text(title)
                .font(WiltedTheme.font(.title))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))

            Divider()

            ScrollView {
                Group {
                    if isReadable, let text {
                        Text(text)
                            .font(WiltedTheme.font(.body))
                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                            .textSelection(.enabled)
                    } else {
                        Label(unavailableLabel, systemImage: "doc.text.magnifyingglass")
                            .font(WiltedTheme.font(.utility))
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier(identifier)
        }
        .padding(WiltedTheme.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            WiltedTheme.color(.card, scheme: colorScheme),
            in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WiltedTheme.Radius.card)
                .stroke(WiltedTheme.color(.steel, scheme: colorScheme), lineWidth: 1)
        )
    }
}

/// A titled group of settings rows.
public struct WiltedSettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let title: String
    private let content: Content

    public init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(title)
                .font(WiltedTheme.font(.title))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            content
        }
        .wiltedCard(colorScheme)
    }
}
