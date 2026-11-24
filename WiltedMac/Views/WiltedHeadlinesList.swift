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
                Button(story.isSaved ? "Unsave" : "Save") { setSaved(!story.isSaved) }
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

    static func readableLink(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct WiltedHeadlinesList: View {
    let recent: [LibraryHeadlineStory]
    let saved: [LibraryHeadlineStory]
    let publishers: [LibraryHeadlinePublisher]
    let actionInProgress: Bool
    let actionMessage: String?
    var projectionMessage: String? = nil
    let setSaved: (LibraryHeadlineStory, Bool) -> Void
    let setMuted: (LibraryHeadlineStory, Bool) -> Void

    private var mutedPublisherIDs: Set<String> {
        Set(publishers.filter(\.isMuted).map(\.id))
    }

    private var unsavedRecent: [LibraryHeadlineStory] {
        recent.filter { !$0.isSaved }
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
            if unsavedRecent.isEmpty && saved.isEmpty && projectionMessage == nil {
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
            storySection("Recent headlines", stories: unsavedRecent)
            storySection("Saved stories", stories: saved)
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
                    WiltedHeadlineStoryCard(
                        story: story,
                        isMuted: mutedPublisherIDs.contains(story.publisherID),
                        actionInProgress: actionInProgress,
                        setSaved: { setSaved(story, $0) },
                        setMuted: { setMuted(story, $0) })
                }
            }
        }
    }
}
