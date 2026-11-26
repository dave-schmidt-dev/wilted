import SwiftUI
import WiltedLibrary

/// Names the exact headline being read and keeps its original article link after speech ends.
struct LibraryNowPlayingHeadlineCard: View {
    @ObservedObject var controller: LibraryInterruptionController
    @ObservedObject var headlineState: LibraryHeadlinePhoneState
    @ObservedObject var model: LibraryAppModel
    @Environment(\.colorScheme) private var colorScheme

    private var bulletin: Bulletin? { controller.nowPlayingHeadline }
    private var canonicalStory: LibraryHeadlineStory? {
        guard headlineState.isBoundToLocalOwner, let bulletin else { return nil }
        return model.canonicalHeadlineStory(for: bulletin)
    }

    var body: some View {
        if let bulletin {
            let isReading = controller.activeSpokenHeadline?.id == bulletin.id
                && controller.activeSpokenHeadline?.text == bulletin.text
            let wasRead = controller.lastSpokenHeadline?.id == bulletin.id
                && controller.lastSpokenHeadline?.text == bulletin.text
            let stateLabel = isReading ? "Reading this story" : wasRead ? "Last story read" : "Story available"
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Label(
                    stateLabel,
                    systemImage: isReading ? "speaker.wave.2.fill" : "newspaper")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(stateLabel)
                    .accessibilityIdentifier("wilted-player-headline-state")
                Text(bulletin.headline ?? bulletin.text)
                    .wiltedFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-player-headline-title")
                if let publisher = bulletin.publisherName, !publisher.isEmpty {
                    Text(publisher)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-player-headline-publisher")
                }
                if let link = bulletin.link {
                    Link("Read story", destination: link)
                        .wiltedFont(.body)
                        .accessibilityIdentifier("wilted-player-headline-read-\(bulletin.headlineStoryID ?? bulletin.id)")
                        .accessibilityValue(link.absoluteString)
                } else {
                    Text("Story link unavailable")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-player-headline-link-unavailable")
                }
                if let issue = controller.bulletinAudioIssue(for: bulletin) {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                        Text(issue)
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("wilted-player-headline-audio-issue")
                        Button("Retry") { controller.retryBulletinAudio(bulletin) }
                            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                            .accessibilityIdentifier("wilted-player-headline-audio-retry")
                    }
                }
                if let story = canonicalStory {
                    let request = model.listenNextRequest(forStoryID: story.id)
                    LibraryListenNextControl(
                        storyID: story.id,
                        request: request,
                        receivedBytes: request.flatMap { model.listenNextDownloadProgress[$0.requestID] },
                        statusText: request.flatMap { model.listenNextStoryStatuses[$0.requestID] },
                        message: request.flatMap { model.listenNextStoryMessages[$0.requestID] },
                        identifierPrefix: "wilted-player-headline",
                        onListenNext: { Task { await model.listenNext(story) } },
                        onUndo: { requestID in Task { await model.undoListenNext(requestID: requestID) } },
                        onRetry: { requestID in Task { await model.retryListenNext(requestID: requestID) } })
                }
            }
            .wiltedCard(colorScheme, padding: WiltedTheme.Spacing.medium)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-player-headline-story-card")
        }
    }

}
