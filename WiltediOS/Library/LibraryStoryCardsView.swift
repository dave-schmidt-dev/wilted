import SwiftUI
import WiltedLibrary

/// The newest story cards stay in the Larder after their announcement has ended.
struct LibraryStoryCardsSection: View {
    @ObservedObject var state: LibraryHeadlinePhoneState
    @ObservedObject var model: LibraryAppModel
    @Environment(\.colorScheme) private var colorScheme

    private var stories: [LibraryHeadlineStory] { Array(model.headlineStories.prefix(3)) }
    private var hasArchive: Bool {
        model.headlineProjection != nil || (!model.accountQuarantined && state.isBoundToLocalOwner && !state.commands.isEmpty)
            || !model.mutedHeadlinePublishers.isEmpty
    }

    var body: some View {
        if !stories.isEmpty || hasArchive || state.writeFailed || state.actionNotice != nil {
            Section {
                if state.refreshFailed, model.headlineProjection != nil {
                    status("Offline. Showing the last headlines from your Mac.", symbol: "icloud.slash")
                }
                if state.writeFailed {
                    status("Headline actions could not be saved on this phone.", symbol: "exclamationmark.circle")
                }
                if let actionNotice = state.actionNotice {
                    status(actionNotice, symbol: "exclamationmark.circle")
                }
                ForEach(stories) { story in
                    LibraryHeadlineStoryCard(
                        state: state, model: model, story: story)
                }
                if hasArchive {
                    NavigationLink {
                        LibraryHeadlineArchiveView(
                            state: state, model: model)
                    } label: {
                        Text("Recent headlines").wiltedFont(.body)
                    }
                    .accessibilityIdentifier("wilted-library-headlines-recent")
                }
            } header: {
                Text("Headlines")
            }
            .accessibilityIdentifier("wilted-library-headlines-section")
        }
    }

    private func status(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("wilted-library-headlines-status")
    }
}

private struct LibraryHeadlineArchiveView: View {
    @ObservedObject var state: LibraryHeadlinePhoneState
    @ObservedObject var model: LibraryAppModel

    @Environment(\.colorScheme) private var colorScheme

    private var recentIDs: Set<String> { Set(model.recentHeadlineStories.map(\.id)) }
    private var savedOlderStories: [LibraryHeadlineStory] {
        (model.headlineProjection?.saved ?? []).filter { !recentIDs.contains($0.id) }
    }

    var body: some View {
        List {
            if model.accountQuarantined {
                Section { Text("Headlines are hidden while this account is under review.").wiltedFont(.body) }
            } else if model.headlineProjection == nil {
                Section {
                    Text(state.refreshFailed ? "Headlines are unavailable while offline." : "No recent headlines yet.")
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
            } else {
                if !model.headlineCommandStories.isEmpty {
                    Section("Pending changes") {
                        ForEach(model.headlineCommandStories) { story in
                            LibraryHeadlineStoryCard(
                                state: state, model: model, story: story)
                        }
                    }
                }
                if !model.recentHeadlineStories.isEmpty {
                    Section("Recent") {
                        ForEach(model.recentHeadlineStories) { story in
                            LibraryHeadlineStoryCard(
                                state: state, model: model, story: story)
                        }
                    }
                }
                if !savedOlderStories.isEmpty {
                    Section("Saved") {
                        ForEach(savedOlderStories) { story in
                            LibraryHeadlineStoryCard(
                                state: state, model: model, story: story)
                        }
                    }
                }
                if !model.mutedHeadlinePublishers.isEmpty {
                    Section("Muted sources") {
                        ForEach(model.mutedHeadlinePublishers) { publisher in
                            HStack {
                                Text(publisher.name).wiltedFont(.body)
                                Spacer()
                                Button("Unmute") {
                                    model.setHeadlinePublisherMuted(publisher.id, isMuted: false)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("wilted-library-headline-unmute-\(publisher.id)")
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .navigationTitle("Headlines")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("wilted-library-headlines-archive")
    }
}

private struct LibraryHeadlineStoryCard: View {
    @ObservedObject var state: LibraryHeadlinePhoneState
    @ObservedObject var model: LibraryAppModel
    let story: LibraryHeadlineStory

    @Environment(\.colorScheme) private var colorScheme

    private var publisher: LibraryHeadlinePublisher? {
        model.headlineProjection?.publishers.first(where: { $0.id == story.publisherID })
    }

    private var storyCommand: LibraryStoryCommandOutboxV1.Command? {
        state.commands.filter { $0.storyID == story.id }.max { $0.createdAt < $1.createdAt }
    }

    private var publisherCommand: LibraryStoryCommandOutboxV1.Command? {
        state.commands.filter { $0.publisherID == story.publisherID }.max { $0.createdAt < $1.createdAt }
    }

    private var listenNextRequest: LibraryListenNextRequestSnapshot? {
        model.listenNextRequest(forStoryID: story.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text(story.title)
                .wiltedFont(.body)
                .fontWeight(.semibold)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text(story.publisherName).wiltedFont(.utility).fontWeight(.medium)
                Text("·").wiltedFont(.utility)
                Text(story.recentAnchorAt, style: .relative).wiltedFont(.utility)
            }
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("wilted-library-headline-metadata-\(story.id)")
            HStack(spacing: WiltedTheme.Spacing.small) {
                if let link = story.link {
                    Link(destination: link) {
                        Label("Read story", systemImage: "safari")
                    }
                    .accessibilityIdentifier("wilted-library-headline-read-\(story.id)")
                }
                Button {
                    model.saveHeadline(story.id, isSaved: !story.isSaved)
                } label: {
                    Label(story.isSaved ? "Saved" : "Save", systemImage: story.isSaved ? "bookmark.fill" : "bookmark")
                }
                .disabled(storyCommand.map { $0.delivery != .failed } == true)
                .accessibilityIdentifier("wilted-library-headline-save-\(story.id)")
                if let publisher {
                    Button {
                        model.setHeadlinePublisherMuted(publisher.id, isMuted: !publisher.isMuted)
                    } label: {
                        Label(publisher.isMuted ? "Unmute source" : "Mute source", systemImage: publisher.isMuted ? "speaker.wave.2" : "speaker.slash")
                    }
                    .disabled(publisherCommand.map { $0.delivery != .failed } == true)
                    .accessibilityIdentifier("wilted-library-headline-mute-\(story.id)")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            LibraryListenNextControl(
                storyID: story.id,
                request: listenNextRequest,
                receivedBytes: listenNextRequest.flatMap { model.listenNextDownloadProgress[$0.requestID] },
                statusText: listenNextRequest.flatMap { model.listenNextStoryStatuses[$0.requestID] },
                message: listenNextRequest.flatMap { model.listenNextStoryMessages[$0.requestID] },
                identifierPrefix: "wilted-library-headline",
                onListenNext: { Task { await model.listenNext(story) } },
                onUndo: { requestID in Task { await model.undoListenNext(requestID: requestID) } },
                onRetry: { requestID in Task { await model.retryListenNext(requestID: requestID) } })
            if let storyCommand { commandStatus(storyCommand) }
            if let publisherCommand { commandStatus(publisherCommand) }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .listRowBackground(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-headline-card-\(story.id)")
    }

    @ViewBuilder
    private func commandStatus(_ command: LibraryStoryCommandOutboxV1.Command) -> some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            if command.delivery == .sent || (command.delivery == .pending && command.detail?.hasPrefix("Update Wilted") != true) {
                ProgressView().controlSize(.small)
            }
            Text(command.detail ?? Self.defaultStatus(command))
                .wiltedFont(.utility)
                .foregroundStyle(command.delivery == .conflict || command.delivery == .failed
                                 ? WiltedTheme.color(.degraded, scheme: colorScheme)
                                 : WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if command.delivery == .conflict {
                if model.canReapplyHeadlineCommand(command.id) {
                    Button("Reapply") { model.reapplyHeadlineCommand(command.id) }
                        .accessibilityIdentifier("wilted-library-headline-reapply-\(command.id)")
                }
            } else if command.delivery == .failed {
                if model.canRetryHeadlineCommand(command.id) {
                    Button("Try again") { model.retryHeadlineCommand(command.id) }
                        .accessibilityIdentifier("wilted-library-headline-retry-\(command.id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-headline-command-status-\(command.id)")
    }

    private static func defaultStatus(_ command: LibraryStoryCommandOutboxV1.Command) -> String {
        switch command.delivery {
        case .pending: "Waiting to sync."
        case .sent: "Waiting for your Mac to confirm."
        case .conflict: "The Mac changed this headline. Reapply to use the current value."
        case .failed: "Your Mac could not apply this action."
        }
    }
}
