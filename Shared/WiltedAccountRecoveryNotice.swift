import SwiftUI

/// One native review control; approval has different consequences for author and listener.
public struct WiltedAccountRecoveryNotice: View {
    public enum Role { case mac, phone }
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirming = false
    private let identifier: String
    private let role: Role
    private let action: () -> Void
    public init(identifier: String = WiltedScreenCopy.useCurrentAccountIdentifier, role: Role = .mac, action: @escaping () -> Void) {
        self.identifier = identifier; self.role = role; self.action = action
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Current iCloud account: name unavailable.")
                .wiltedFont(.utility).foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            Button(WiltedScreenCopy.useCurrentAccount) { confirming = true }
                .buttonStyle(.borderedProminent).tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget).accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Review this library", isPresented: $confirming) {
            Button(role == .mac ? "Send this library" : "Replace saved library", action: action)
                .accessibilityIdentifier("wilted-account-confirm")
            Button("Keep held", role: .cancel) {}.accessibilityIdentifier("wilted-account-keep-held")
        } message: {
            Text(role == .mac ? WiltedScreenCopy.macAccountReviewDetail : WiltedScreenCopy.useCurrentAccountDetail)
        }
    }
}

/// The same neutral author-age line on both apps. No elapsed-age cutoff means fresh or converged.
public enum WiltedPublicationAge {
    public static func summary(_ publishedAt: Date?, verified: Bool, now: Date = Date()) -> String {
        guard let publishedAt else { return "Mac publication unknown" }
        guard publishedAt <= now else { return "Mac publication clock uncertain" }
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .full
        let age = formatter.localizedString(for: publishedAt, relativeTo: now)
        return "\(verified ? "Mac last published" : "Saved Mac last published") \(age)"
    }
    public static func detail(_ publishedAt: Date?) -> String {
        guard let publishedAt else { return "No account-associated Mac publication time is saved." }
        return "Mac publication: \(publishedAt.formatted(date: .abbreviated, time: .standard)). Author evidence does not prove this phone has the same library."
    }
    public static func qualifier(verified: Bool, pending: Bool, failed: Bool, held: Bool) -> String? {
        if held { return "Saved library · account review required." }
        if pending { return "Saved library · refresh pending." }
        if failed { return "Saved library · refresh failed." }
        if !verified { return "Saved library · account unverified." }
        return nil
    }
}

/// Shipping status region reused by both roots and Settings, with secondary facts in native help.
public struct WiltedPublicationNotice: View {
    private let summary: String
    private let detail: String
    private let qualifier: String?
    @Environment(\.colorScheme) private var colorScheme
    public init(summary: String, detail: String, qualifier: String? = nil) {
        self.summary = summary; self.detail = detail; self.qualifier = qualifier
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text(summary).foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme)).accessibilityIdentifier("wilted-author-publication")
            if let qualifier { Text(qualifier).foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme)) }
        }
        .wiltedFont(.utility).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine).accessibilityLabel([summary, qualifier, detail].compactMap { $0 }.joined(separator: " "))
#if os(macOS)
        .help(detail)
#endif
    }
}
