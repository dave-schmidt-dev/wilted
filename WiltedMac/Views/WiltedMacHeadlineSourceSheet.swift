import SwiftUI
import WiltedDomain

#if canImport(WiltedProducer)
import WiltedProducer

/// Lets Reports select a followed article feed or add one as a headline source.
struct WiltedMacHeadlineSourceSheet: View {
    let model: WiltedMacModel
    let policyBoard: WiltedMacFeedPolicyBoard
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var feedAddress = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var articleFeeds: [WiltedMacSubscription] {
        model.subscriptions.filter { policyBoard.isArticleFeed($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text("Headline feeds")
                .wiltedFont(.title)
            Text("Choose an article feed or enter its address. Its posts will leave the Keep/Skip inbox.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if policyBoard.isLoading {
                ProgressView("Loading article feeds…")
                    .controlSize(.small)
                    .accessibilityIdentifier("wilted-reports-headline-sources-loading")
            } else if let failure = policyBoard.loadFailureMessage {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { Task { await policyBoard.retryReload() } }
                    .disabled(!policyBoard.canRetry)
                    .accessibilityIdentifier("wilted-reports-headline-sources-retry")
            } else if articleFeeds.isEmpty {
                Text("No article feeds yet.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(articleFeeds, id: \.id) { subscription in
                            if policyBoard.isNews(subscription.id) {
                                Label(subscription.title, systemImage: "checkmark.circle.fill")
                                    .wiltedFont(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, WiltedTheme.Spacing.small)
                                    .accessibilityIdentifier("wilted-reports-headline-source-active-\(subscription.id)")
                            } else {
                                Button {
                                    choose(subscription)
                                } label: {
                                    HStack {
                                        Text(subscription.title)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("Use")
                                            .wiltedFont(.utility)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, WiltedTheme.Spacing.small)
                                }
                                .buttonStyle(.plain)
                                .disabled(isWorking)
                                .accessibilityIdentifier("wilted-reports-headline-source-\(subscription.id)")
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()

            TextField("Article feed address", text: $feedAddress)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)
                .accessibilityIdentifier("wilted-reports-headline-feed-address")
                .onSubmit(addHeadlineFeed)
            Button("Add headline feed", action: addHeadlineFeed)
                .disabled(isWorking || feedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("wilted-reports-headline-feed-add")

            if isWorking {
                ProgressView("Adding headline feed…")
                    .controlSize(.small)
                    .accessibilityIdentifier("wilted-reports-headline-feed-progress")
            }
            if let errorMessage {
                Text(errorMessage)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-reports-headline-feed-error")
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 480, height: 560)
        .interactiveDismissDisabled(isWorking)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-reports-headline-source-sheet")
        .task {
            if policyBoard.loadState == .idle { await policyBoard.reload() }
        }
    }

    private func choose(_ subscription: WiltedMacSubscription) {
        guard !isWorking else { return }
        guard policyBoard.setNews(true, for: subscription.id) else {
            errorMessage = "Could not save this choice. Try again."
            return
        }
        isWorking = true
        errorMessage = nil
        Task {
            await policyBoard.settle()
            guard let feedID = try? ItemID(rawValue: subscription.id), let store = model.store,
                  (try? await store.isNews(feedID: feedID)) == true else {
                fail("Could not save this choice. Try again.")
                return
            }
            await model.bulletinHub.refreshNewsSourceReadiness()
            dismiss()
        }
    }

    private func addHeadlineFeed() {
        guard !isWorking else { return }
        let address = feedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil,
              let feedID = try? ItemID.articleFeed(canonicalFeedURL: url) else {
            errorMessage = "Enter a complete HTTPS article feed address."
            return
        }
        if let existing = articleFeeds.first(where: { $0.id == feedID.rawValue }) {
            choose(existing)
            return
        }
        errorMessage = nil
        isWorking = true
        Task {
            guard !model.isRefreshingPodcasts, !model.isCheckingPodcastSubscription else {
                fail("A feed check is running. Try again when it finishes.")
                return
            }
            guard await model.subscribeToHeadlineFeed(url) else {
                fail(model.podcastFeedDraftStatus ?? "Could not add headline feed. Check the address and try again.")
                return
            }
            await model.bulletinHub.refreshNewsSourceReadiness()
            dismiss()
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        isWorking = false
    }
}
#endif
