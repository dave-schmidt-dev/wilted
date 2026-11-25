import SwiftUI
import WiltedLibrary

/// Keeps the featured story's catalog and Listen next controls together in Now Playing.
struct WiltedMacPlayerHeadlineCard: View {
    @Environment(\.colorScheme) private var colorScheme

    enum NarrationStatus: Equatable {
        case chooseVoice
        case preparing
        case unavailable
    }

    let model: WiltedMacModel
    let story: LibraryHeadlineStory
    let isSpeakingHeadline: Bool
    let stopReading: () -> Void
    var narrationStatus: NarrationStatus? = nil
    @State private var listenNextRequests: [LibraryListenNextRequestSnapshot] = []
    @State private var listenNextActionStoryID: String?

    private var listenNextRequest: LibraryListenNextRequestSnapshot? {
        listenNextRequests
            .filter { $0.requesterDeviceID == model.libraryDeviceID() && $0.storyID == story.id }
            .max { $0.createdAt < $1.createdAt }
    }

    private var listenNextActionMessage: String? {
        guard listenNextActionStoryID == story.id else { return nil }
        if let listenNextRequest,
           ![.pending, .sent, .preparing].contains(listenNextRequest.status) {
            return nil
        }
        return model.listenNextActionMessage
    }

    static func listenNextAlreadyOffersVoiceChoice(
        request: LibraryListenNextRequestSnapshot?, actionMessage: String?
    ) -> Bool {
        if let request, request.status == .failed, request.failure == .missingVoice { return true }
        return actionMessage == WiltedHeadlineStoryCard.listenNextFailureMessage(.missingVoice)
    }

    private var listenNextAlreadyOffersVoiceChoice: Bool {
        Self.listenNextAlreadyOffersVoiceChoice(
            request: listenNextRequest, actionMessage: listenNextActionMessage)
    }

    /// The production story card and its Listen next bindings, also used by the headless action tests.
    @MainActor var storyCard: WiltedHeadlineStoryCard {
        let catalog = model.headlineCatalogState
        let isMuted = catalog.projection?.publishers.contains {
            $0.id == story.publisherID && $0.isMuted
        } ?? false
        return WiltedHeadlineStoryCard(
            story: story,
            isMuted: isMuted,
            actionInProgress: catalog.isActionInProgress,
            setSaved: { catalog.setSaved(story, isSaved: $0) },
            setMuted: { catalog.setMuted(story, isMuted: $0) },
            isSpeakingHeadline: isSpeakingHeadline,
            stopReading: stopReading,
            listenNextRequest: listenNextRequest,
            listenNextActionMessage: listenNextActionMessage,
            listenNextRequestInProgress: model.isListenNextRequestInProgress,
            requestListenNext: performListenNext,
            cancelListenNext: performCancelListenNext,
            chooseReadingVoice: model.openReadingVoiceSettings)
    }

    var body: some View {
        let catalog = model.headlineCatalogState
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            storyCard
            narrationStatusView
            if let message = catalog.actionMessage {
                Text(message)
                    .wiltedFont(.utility)
                    .accessibilityIdentifier("wilted-headline-action-status")
            }
        }
        .task { await refreshListenNextRequests() }
        .onChange(of: model.listenNextActionMessage) { _, _ in
            Task { await refreshListenNextRequests() }
        }
    }

    @ViewBuilder
    private var narrationStatusView: some View {
        switch narrationStatus {
        case .chooseVoice:
            if listenNextAlreadyOffersVoiceChoice {
                EmptyView()
            } else {
                Button("Choose story voice", action: chooseNarrationVoice)
                    .accessibilityIdentifier("wilted-headline-choose-story-voice-\(story.id)")
            }
        case .preparing:
            HStack(spacing: WiltedTheme.Spacing.small) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Preparing headline audio…")
                    .wiltedFont(.utility)
            }
            .accessibilityIdentifier("wilted-headline-narration-preparing-\(story.id)")
        case .unavailable:
            Text("Headline audio unavailable")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                .accessibilityIdentifier("wilted-headline-narration-unavailable-\(story.id)")
        case nil:
            EmptyView()
        }
    }

    @MainActor
    func chooseNarrationVoice() {
        model.openReadingVoiceSettings()
    }

    @MainActor
    private func refreshListenNextRequests() async {
        listenNextRequests = await model.listenNextSnapshots()
    }

    @MainActor
    /// The request action bound to the featured card; keep its story and playback anchor together.
    func performListenNext() async {
        listenNextActionStoryID = story.id
        do {
            _ = try await model.listenNextRequest(story: story, anchorID: model.playback?.itemID)
        } catch { /* The request presentation carries the visible failure. */ }
        await refreshListenNextRequests()
    }

    @MainActor
    /// Cancels the exact visible request selected by the card's Undo or Stop action.
    func performCancelListenNext(_ requestID: String) async {
        do { try await model.cancelListenNextRequest(requestID) }
        catch { /* The request presentation carries the visible failure. */ }
        await refreshListenNextRequests()
    }
}
