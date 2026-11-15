import SwiftUI

/// The undo toast: what just happened, with Undo, pinned over the bottom of the window.
///
/// It sits over the content rather than in the scrolling list, so it is on screen wherever the
/// list is scrolled to and on every destination. Resting the pointer on it keeps it there.
struct WiltedMacUndoToastView: View {
    let center: WiltedMacUndoToastCenter
    let offer: WiltedMacUndoOffer
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.large) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text(offer.message)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-undo-toast-message")
                if center.earlierCount > 0 {
                    Text(Self.earlierCopy(center.earlierCount))
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-undo-toast-earlier")
                }
            }
            Button("Undo") { center.undo(offer.id) }
                .help("Undo (\u{2318}Z)")
                .accessibilityLabel("Undo: \(offer.message)")
                .accessibilityIdentifier("wilted-undo-toast-undo")
        }
        .padding(.horizontal, WiltedTheme.Spacing.large)
        .padding(.vertical, WiltedTheme.Spacing.small)
        .frame(maxWidth: 460)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            WiltedTheme.color(.card, scheme: colorScheme),
            in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WiltedTheme.Radius.card)
                .stroke(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme), lineWidth: 1)
        )
        .onHover { center.setHeld($0) }
        .onDisappear { center.setHeld(false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-undo-toast")
    }

    /// The line under the message when earlier actions can still be undone too.
    static func earlierCopy(_ count: Int) -> String {
        count == 1 ? "1 earlier change can also be undone." : "\(count) earlier changes can also be undone."
    }
}

/// Pins the undo toast over the bottom of a view and connects it to the window's Undo command.
struct WiltedMacUndoToastHost: ViewModifier {
    let center: WiltedMacUndoToastCenter
    /// False while another host covers this one, so the toast is drawn and announced once.
    var isPresenting = true
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isPresenting, let offer = center.current {
                    WiltedMacUndoToastView(center: center, offer: offer)
                        .padding(.bottom, WiltedTheme.Spacing.large)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: center.current?.id)
            .onChange(of: center.current?.id) { _, _ in
                // A toast is silent to VoiceOver unless it is announced: nothing moves focus to it.
                guard isPresenting, let offer = center.current else { return }
                AccessibilityNotification.Announcement(WiltedMacUndoToastCenter.announcement(for: offer)).post()
            }
            .onAppear { center.attach(undoManager) }
            .onChange(of: undoManager) { _, manager in center.attach(manager) }
    }
}
