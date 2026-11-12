import SwiftUI

/// The question asked before a newly added feed that looks paid or ad-free is saved.
///
/// Attached both to the window root and to the add sheet, with only one active at a
/// time, so it can present whether or not the sheet is open.
struct WiltedMacAdFreeFeedPromptAlert: ViewModifier {
    let model: WiltedMacModel
    let isActive: Bool

    static let title = "This might be an ad-free feed"

    static func message(showTitle: String) -> String {
        "It looks like \(showTitle) might be an ad-free feed. Would you like to exclude it from ad removal?"
    }

    func body(content: Content) -> some View {
        content.alert(
            Self.title,
            isPresented: Binding(
                get: { isActive && model.pendingAdFreeFeedPrompt != nil },
                // Dismissing any other way keeps ad removal on; a button's own answer wins.
                set: { if !$0, isActive { model.adFreeFeedPromptWasDismissed() } }
            ),
            presenting: model.pendingAdFreeFeedPrompt
        ) { _ in
            Button("Exclude from Ad Removal") { model.answerAdFreeFeedPrompt(exclude: true) }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("wilted-ad-free-prompt-exclude")
            Button("Keep Removing Ads", role: .cancel) { model.answerAdFreeFeedPrompt(exclude: false) }
                .accessibilityIdentifier("wilted-ad-free-prompt-keep")
        } message: { prompt in
            Text(Self.message(showTitle: prompt.title))
        }
    }
}
