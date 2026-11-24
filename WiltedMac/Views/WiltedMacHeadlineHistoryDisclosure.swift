import SwiftUI
import WiltedLibrary

/// Recent and saved story actions live together in Reports and the player's story cards.
struct WiltedMacHeadlineHistoryDisclosure: View {
    let model: WiltedMacModel
    @Binding var isExpanded: Bool
    let chooseReadingVoice: () -> Void
    @State private var listenNextRequests: [LibraryListenNextRequestSnapshot] = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            headlinesList
                .task {
                    model.headlineCatalogState.refresh()
                    await refreshListenNextRequests()
                }
                .onChange(of: model.listenNextActionMessage) { _, _ in
                    Task { await refreshListenNextRequests() }
                }
        } label: {
            Text("Recent and saved stories")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .accessibilityIdentifier("wilted-reports-headline-history")
    }

    /// The production list view and its model-backed Listen next actions.
    @MainActor var headlinesList: WiltedHeadlinesList {
        let catalog = model.headlineCatalogState
        return WiltedHeadlinesList(
            recent: catalog.projection?.recent ?? [],
            saved: catalog.projection?.saved ?? [],
            publishers: catalog.projection?.publishers ?? [],
            actionInProgress: catalog.isActionInProgress,
            actionMessage: catalog.actionMessage,
            projectionMessage: catalog.projectionMessage,
            setSaved: { catalog.setSaved($0, isSaved: $1) },
            setMuted: { catalog.setMuted($0, isMuted: $1) },
            listenNextRequests: localListenNextRequests,
            listenNextActionMessage: model.listenNextActionMessage,
            listenNextRequestInProgress: model.isListenNextRequestInProgress,
            requestListenNext: performListenNext,
            cancelListenNext: performCancelListenNext,
            chooseReadingVoice: chooseReadingVoice)
    }

    private var localListenNextRequests: [LibraryListenNextRequestSnapshot] {
        listenNextRequests.filter { $0.requesterDeviceID == model.libraryDeviceID() }
    }

    /// The Recent and Saved card action bound to the list's Listen next and Retry buttons.
    @MainActor func performListenNext(_ story: LibraryHeadlineStory) async {
        do {
            _ = try await model.listenNextRequest(story: story, anchorID: model.playback?.itemID)
        } catch { /* The request presentation carries the visible failure. */ }
        await refreshListenNextRequests()
    }

    /// Cancels the exact request ID bound to a Recent or Saved card's Undo action.
    @MainActor func performCancelListenNext(_ requestID: String) async {
        do { try await model.cancelListenNextRequest(requestID) }
        catch { /* The request presentation carries the visible failure. */ }
        await refreshListenNextRequests()
    }

    @MainActor
    private func refreshListenNextRequests() async {
        listenNextRequests = await model.listenNextSnapshots()
    }
}
