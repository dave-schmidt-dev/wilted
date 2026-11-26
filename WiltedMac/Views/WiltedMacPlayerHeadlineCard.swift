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

enum WiltedMacHeadlineTickerMotion {
    static func shouldAutoScroll(
        reduceMotion: Bool,
        isHovering: Bool,
        hasKeyboardFocus: Bool,
        isPresentingStory: Bool,
        storyCount: Int
    ) -> Bool {
        storyCount > 1 && !reduceMotion && !isHovering && !hasKeyboardFocus && !isPresentingStory
    }
}

enum WiltedMacHeadlineTickerSelection {
    static func currentStory(
        matching snapshot: LibraryHeadlineStory,
        in projection: LibraryHeadlineProjection?
    ) -> LibraryHeadlineStory {
        projection?.saved.first(where: { $0.id == snapshot.id })
            ?? projection?.recent.first(where: { $0.id == snapshot.id })
            ?? snapshot
    }
}

/// A compact, optional strip for opening recent headlines without interrupting playback.
struct WiltedMacHeadlineTicker: View {
    @Bindable private var model: WiltedMacModel
    private let stories: [LibraryHeadlineStory]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedStorySnapshot: LibraryHeadlineStory?
    @State private var isHovering = false
    @State private var nextScrollIndex = 1
    @FocusState private var focusedStoryID: String?

    init(model: WiltedMacModel, stories: [LibraryHeadlineStory]) {
        _model = Bindable(model)
        self.stories = Array(stories.prefix(20))
    }

    private var autoScrollEnabled: Bool {
        WiltedMacHeadlineTickerMotion.shouldAutoScroll(
            reduceMotion: reduceMotion,
            isHovering: isHovering,
            hasKeyboardFocus: focusedStoryID != nil,
            isPresentingStory: selectedStorySnapshot != nil,
            storyCount: stories.count)
    }

    private var scrollTaskIdentity: [String] {
        [autoScrollEnabled ? "moving" : "still"] + stories.map(\.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: WiltedTheme.Spacing.medium) {
                Label("Headlines", systemImage: "newspaper")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize()

                if stories.isEmpty {
                    Text("No recent stories yet")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: WiltedTheme.Spacing.medium) {
                            ForEach(stories) { story in
                                Button {
                                    selectedStorySnapshot = story
                                } label: {
                                    HStack(spacing: WiltedTheme.Spacing.xSmall) {
                                        Text(story.publisherName)
                                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                        Text(story.title)
                                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                                            .lineLimit(1)
                                            .frame(maxWidth: 360, alignment: .leading)
                                    }
                                    .wiltedFont(.utility)
                                    .padding(.horizontal, WiltedTheme.Spacing.small)
                                    .padding(.vertical, WiltedTheme.Spacing.xSmall)
                                    .background(
                                        WiltedTheme.color(.page, scheme: colorScheme),
                                        in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .focused($focusedStoryID, equals: story.id)
                                .help("Open story actions")
                                .accessibilityLabel("\(story.publisherName): \(story.title)")
                                .accessibilityHint(
                                    "Show story actions. Read the article, queue audio after the current episode, or save it to Notebook.")
                                .accessibilityIdentifier("wilted-headline-ticker-story-\(story.id)")
                                .id(story.id)
                            }
                        }
                        .padding(.vertical, WiltedTheme.Spacing.xSmall)
                    }
                    .scrollIndicators(.hidden)
                    .accessibilityIdentifier("wilted-headline-ticker-stories")
                }
            }
            .padding(.horizontal, WiltedTheme.Spacing.medium)
            .padding(.vertical, WiltedTheme.Spacing.xSmall)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(WiltedTheme.color(.card, scheme: colorScheme))
            .overlay(alignment: .top) {
                WiltedTheme.color(.steel, scheme: colorScheme).frame(height: 1)
            }
            .onHover { isHovering = $0 }
            .popover(item: $selectedStorySnapshot, arrowEdge: .bottom) { snapshot in
                storyActions(for: snapshot)
            }
            .task(id: scrollTaskIdentity) {
                guard autoScrollEnabled else { return }
                nextScrollIndex %= stories.count
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) }
                    catch { return }
                    guard autoScrollEnabled, !Task.isCancelled else { return }
                    let targetIndex = nextScrollIndex
                    let animation: Animation? = targetIndex == 0 ? nil : .linear(duration: 1.4)
                    withAnimation(animation) {
                        proxy.scrollTo(stories[targetIndex].id, anchor: .leading)
                    }
                    nextScrollIndex = (targetIndex + 1) % stories.count
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-headline-ticker")
        }
    }

    @ViewBuilder
    private func storyActions(for snapshot: LibraryHeadlineStory) -> some View {
        let story = WiltedMacHeadlineTickerSelection.currentStory(
            matching: snapshot, in: model.headlineCatalogState.projection)
        WiltedMacPlayerHeadlineCard(
            model: model,
            story: story,
            isSpeakingHeadline: model.speakingBulletin?.kind == .headline
                && model.speakingBulletin?.headlineStoryID == story.id,
            stopReading: model.skipSpokenBulletin)
            .id(story.id)
            .frame(width: 440)
            .padding(WiltedTheme.Spacing.small)
    }
}
