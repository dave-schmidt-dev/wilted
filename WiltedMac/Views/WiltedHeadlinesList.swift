import SwiftUI
import WiltedLibrary

struct WiltedHeadlineStoryCard: View {
    let story: LibraryHeadlineStory
    let isMuted: Bool
    let actionInProgress: Bool
    let setSaved: (Bool) -> Void
    let setMuted: (Bool) -> Void
    var isSpeakingHeadline = false
    var stopReading: () -> Void = {}
    var listenNextRequest: LibraryListenNextRequestSnapshot? = nil
    var listenNextActionMessage: String? = nil
    var listenNextRequestInProgress = false
    var requestListenNext: @MainActor () async -> Void = {}
    var cancelListenNext: @MainActor (String) async -> Void = { _ in }
    var chooseReadingVoice: () -> Void = {}
    @State private var isUpdatingListenNext = false

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack {
                Text(story.publisherName)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                Spacer()
                if let publishedAt = story.publishedAt {
                    Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
            }
            Text(story.title)
                .wiltedFont(.body)
                .fixedSize(horizontal: false, vertical: true)
            listenNextControl
            if isSpeakingHeadline {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Image(systemName: "speaker.wave.2.fill")
                        .accessibilityHidden(true)
                    Text("Reading this story")
                        .wiltedFont(.utility)
                    Button("Stop reading", action: stopReading)
                        .fixedSize()
                        .accessibilityLabel("Stop reading")
                        .disabled(actionInProgress)
                        .accessibilityIdentifier("wilted-headline-stop-\(story.id)")
                }
            }
            WiltedMacFlowLayout(spacing: WiltedTheme.Spacing.medium) {
                if let link = Self.readableLink(story.link) {
                    Link("Read story", destination: link)
                        .accessibilityIdentifier("wilted-headline-read-\(story.id)")
                } else {
                    Text("Article link unavailable")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                Button(story.isSaved ? "Remove from Notebook" : "Save to Notebook") { setSaved(!story.isSaved) }
                    .disabled(actionInProgress)
                    .accessibilityIdentifier("wilted-headline-save-\(story.id)")
                if isMuted {
                    Text("Muted")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    Button("Undo") { setMuted(false) }
                        .disabled(actionInProgress)
                        .accessibilityIdentifier("wilted-headline-unmute-\(story.publisherID)")
                } else {
                    Button("Mute this source") { setMuted(true) }
                        .disabled(actionInProgress)
                        .accessibilityIdentifier("wilted-headline-mute-\(story.publisherID)")
                }
            }
        }
        .wiltedFont(.utility)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WiltedTheme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
                .fill(WiltedTheme.color(.card, scheme: colorScheme)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-headline-card-\(story.id)")
    }

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder private var listenNextControl: some View {
        if let request = listenNextRequest, request.status != .completed {
            switch request.status {
            case .pending, .sent, .preparing:
                HStack(spacing: WiltedTheme.Spacing.small) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(listenNextActionMessage ?? "Preparing story audio…")
                        .wiltedFont(.utility)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Undo queue") { cancel(request.requestID) }
                        .disabled(isUpdatingListenNext)
                        .accessibilityIdentifier("wilted-headline-listen-next-undo-\(story.id)")
                }
                .accessibilityIdentifier("wilted-headline-listen-next-preparing-\(story.id)")
            case .ready, .selected:
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Label("Queued after current episode", systemImage: "text.book.closed.fill")
                        .labelStyle(.titleAndIcon)
                        .wiltedFont(.utility)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Undo queue") { cancel(request.requestID) }
                        .disabled(isUpdatingListenNext)
                        .accessibilityIdentifier("wilted-headline-listen-next-undo-\(story.id)")
                }
                .accessibilityIdentifier("wilted-headline-listen-next-queued-\(story.id)")
            case .playing:
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Label("Playing this story", systemImage: "speaker.wave.2.fill")
                        .labelStyle(.titleAndIcon)
                        .wiltedFont(.utility)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Stop story") { cancel(request.requestID) }
                        .disabled(isUpdatingListenNext)
                        .accessibilityIdentifier("wilted-headline-listen-next-stop-\(story.id)")
                }
            case .failed:
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Text(Self.listenNextFailureMessage(request.failure))
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { retry() }
                        .disabled(isUpdatingListenNext || listenNextRequestInProgress)
                        .accessibilityIdentifier("wilted-headline-listen-next-retry-\(story.id)")
                    if request.failure == .missingVoice {
                        Button("Choose voice", action: chooseVoice)
                            .accessibilityIdentifier("wilted-headline-listen-next-choose-voice-\(story.id)")
                    }
                }
            case .cancelled:
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Text("Story request cancelled")
                        .wiltedFont(.utility)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Listen next") { retry() }
                        .disabled(isUpdatingListenNext || listenNextRequestInProgress)
                        .accessibilityIdentifier("wilted-headline-listen-next-\(story.id)")
                }
            case .completed:
                EmptyView()
            }
        } else {
            HStack(spacing: WiltedTheme.Spacing.small) {
                Button("Listen next") { retry() }
                    .disabled(isUpdatingListenNext || listenNextRequestInProgress)
                    .accessibilityIdentifier("wilted-headline-listen-next-\(story.id)")
                if let listenNextActionMessage {
                    Text(listenNextActionMessage)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-headline-listen-next-status-\(story.id)")
                    if listenNextActionMessage == Self.listenNextFailureMessage(.missingVoice) {
                        Button("Choose voice", action: chooseVoice)
                            .accessibilityIdentifier("wilted-headline-listen-next-choose-voice-\(story.id)")
                    }
                }
            }
        }
    }

    /// Runs the same action bound to the Listen next and Retry buttons.
    @MainActor func retry() {
        guard !isUpdatingListenNext else { return }
        isUpdatingListenNext = true
        Task { @MainActor in
            defer { isUpdatingListenNext = false }
            await requestListenNext()
        }
    }

    /// Runs the same request-scoped cancellation action bound to Undo and Stop.
    @MainActor func cancel(_ requestID: String) {
        guard !isUpdatingListenNext else { return }
        isUpdatingListenNext = true
        Task { @MainActor in
            defer { isUpdatingListenNext = false }
            await cancelListenNext(requestID)
        }
    }

    /// Routes the same action bound to each Choose voice button.
    @MainActor func chooseVoice() {
        chooseReadingVoice()
    }

    static func listenNextFailureMessage(_ failure: LibraryListenNextStatus.Failure?) -> String {
        switch failure {
        case .missingVoice: "Choose a voice to listen to stories."
        case .unsafeArticle: "This story link is not safe to read aloud."
        case .unavailableStory: "This story is no longer available."
        case .narrationFailed: "Story audio could not be prepared."
        case .transferFailed: "Story audio could not be transferred."
        case nil: "Story audio could not be prepared."
        }
    }

    static func readableLink(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct WiltedHeadlinesList: View {
    let recent: [LibraryHeadlineStory]
    let publishers: [LibraryHeadlinePublisher]
    let actionInProgress: Bool
    let actionMessage: String?
    var projectionMessage: String? = nil
    let setSaved: (LibraryHeadlineStory, Bool) -> Void
    let setMuted: (LibraryHeadlineStory, Bool) -> Void
    var listenNextRequests: [LibraryListenNextRequestSnapshot] = []
    var listenNextActionMessage: String? = nil
    var listenNextRequestInProgress = false
    var requestListenNext: @MainActor (LibraryHeadlineStory) async -> Void = { _ in }
    var cancelListenNext: @MainActor (String) async -> Void = { _ in }
    var chooseReadingVoice: () -> Void = {}
    @State private var lastListenNextStoryID: String?

    private var mutedPublisherIDs: Set<String> {
        Set(publishers.filter(\.isMuted).map(\.id))
    }

    private var recentStories: [LibraryHeadlineStory] {
        recent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            if let projectionMessage {
                Text(projectionMessage)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-headlines-load-status")
            }
            if recentStories.isEmpty && projectionMessage == nil {
                Text("New stories from your headline feeds will appear here for seven days.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-headlines-empty")
            }
            if let actionMessage {
                Text(actionMessage)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-headline-action-status")
            }
            storySection("Recent headlines", stories: recentStories)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    private func storySection(_ title: String, stories: [LibraryHeadlineStory]) -> some View {
        if !stories.isEmpty {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Text(title).wiltedFont(.utility)
                ForEach(stories) { story in
                    storyCard(for: story)
                }
            }
        }
    }

    /// Builds the exact card used for the given Recent or Saved row.
    @MainActor func storyCard(for story: LibraryHeadlineStory) -> WiltedHeadlineStoryCard {
        WiltedHeadlineStoryCard(
            story: story,
            isMuted: mutedPublisherIDs.contains(story.publisherID),
            actionInProgress: actionInProgress,
            setSaved: { setSaved(story, $0) },
            setMuted: { setMuted(story, $0) },
            isSpeakingHeadline: false,
            listenNextRequest: latestListenNextRequest(for: story),
            listenNextActionMessage: actionMessage(for: story),
            listenNextRequestInProgress: listenNextRequestInProgress,
            requestListenNext: { await performListenNext(for: story) },
            cancelListenNext: cancelListenNext,
            chooseReadingVoice: chooseReadingVoice)
    }

    private func latestListenNextRequest(for story: LibraryHeadlineStory) -> LibraryListenNextRequestSnapshot? {
        listenNextRequests
            .filter { $0.storyID == story.id }
            .max { $0.createdAt < $1.createdAt }
    }

    private func actionMessage(for story: LibraryHeadlineStory) -> String? {
        guard lastListenNextStoryID == story.id else { return nil }
        if let request = latestListenNextRequest(for: story),
           ![.pending, .sent, .preparing].contains(request.status) {
            return nil
        }
        return listenNextActionMessage
    }

    /// The action supplied to each rendered Recent or Saved card, preserving its story identity.
    @MainActor func performListenNext(for story: LibraryHeadlineStory) async {
        lastListenNextStoryID = story.id
        await requestListenNext(story)
    }
}
