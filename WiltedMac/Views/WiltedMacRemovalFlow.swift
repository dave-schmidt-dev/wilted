import SwiftUI

// MARK: - Confirmed removal

/// What a confirmed removal acts on, with the copy its dialog and status use.
enum WiltedMacRemovalTarget: Hashable {
    case feed(WiltedMacSubscription)
    case article(WiltedMacArticle)

    var dialogTitle: String {
        switch self {
        case .feed(let subscription): "Unsubscribe \(subscription.title)?"
        case .article(let article): "Delete \(article.title)?"
        }
    }

    var dialogMessage: String {
        switch self {
        case .feed: "Removes this subscription, its episodes, their saved positions and their downloaded audio."
        case .article: "Delete this article and queue its library removal together."
        }
    }

    var confirmLabel: String {
        switch self {
        case .feed: "Confirm unsubscribe"
        case .article: "Confirm delete"
        }
    }

    var removedCopy: String {
        switch self {
        case .feed: "Unsubscribed. Downloaded audio was deleted."
        case .article: "Article deleted."
        }
    }
}

/// One confirmed removal: the dialog request, the single commit in flight,
/// and the failure a Retry repeats.
///
/// The view showing the dialog holds this, because the model keeps only
/// library state. A commit is marked in flight before anything is spawned,
/// so a second confirm while it runs is ignored rather than queued, and a
/// failure leaves the row where it was with the error and Retry beside it.
@MainActor @Observable
final class WiltedMacRemovalFlow {
    enum Phase: Equatable { case saving, saved, failed }

    static let savingCopy = "Saving removal…"
    static let failedCopy = "Removal save failed. Nothing was removed; retry is available."

    /// The removal awaiting the listener's answer. It drives the dialog.
    private(set) var requested: WiltedMacRemovalTarget?
    private(set) var target: WiltedMacRemovalTarget?
    private(set) var phase: Phase?

    var isSaving: Bool { phase == .saving }

    var statusText: String? {
        switch phase {
        case .saving: Self.savingCopy
        case .saved: target?.removedCopy
        case .failed: Self.failedCopy
        case nil: nil
        }
    }

    func request(_ target: WiltedMacRemovalTarget) {
        guard !isSaving else { return }
        requested = target
    }

    /// Dismissing the dialog writes nothing.
    func cancel() { requested = nil }

    func confirm(_ target: WiltedMacRemovalTarget, model: WiltedMacModel) {
        requested = nil
        commit(target, model: model)
    }

    func retry(model: WiltedMacModel) {
        guard phase == .failed, let target else { return }
        commit(target, model: model)
    }

    private func commit(_ target: WiltedMacRemovalTarget, model: WiltedMacModel) {
#if canImport(WiltedProducer)
        guard !isSaving else { return }
        self.target = target
        phase = .saving
        model.trackSubscriptionWrite { [weak self, weak model] in
            guard let model else { return }
            do {
                switch target {
                case .feed(let subscription): try await model.commitUnsubscribe(subscription)
                case .article(let article): try await model.commitArticleRemoval(article)
                }
                self?.phase = .saved
            } catch {
                self?.phase = .failed
            }
        }
#endif
    }
}

/// The removal's own status line, with Retry after a failed save.
struct WiltedMacRemovalStatusLine: View {
    let flow: WiltedMacRemovalFlow
    let model: WiltedMacModel
    /// Empty for the Feeds card; the article id for an article row.
    var identifierSuffix = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let text = flow.statusText {
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text(text)
                    .wiltedFont(.utility)
                    .foregroundStyle((flow.phase == .failed ? WiltedStatusTone.failure : .neutral).color(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-delete-save-status\(identifierSuffix)")
                if flow.phase == .failed {
                    Button("Retry") { flow.retry(model: model) }
                        .accessibilityIdentifier("wilted-delete-retry\(identifierSuffix)")
                }
            }
        }
    }
}

extension View {
    /// The native confirmation for a `WiltedMacRemovalFlow` request.
    func wiltedRemovalConfirmation(_ flow: WiltedMacRemovalFlow, model: WiltedMacModel) -> some View {
        confirmationDialog(
            flow.requested?.dialogTitle ?? "",
            isPresented: Binding(get: { flow.requested != nil }, set: { if !$0 { flow.cancel() } }),
            titleVisibility: .visible,
            presenting: flow.requested
        ) { target in
            Button(target.confirmLabel, role: .destructive) { flow.confirm(target, model: model) }
                .accessibilityIdentifier("wilted-delete-confirm")
            Button("Cancel", role: .cancel) { flow.cancel() }
                .accessibilityIdentifier("wilted-delete-cancel")
        } message: { target in
            Text(target.dialogMessage)
        }
    }
}
