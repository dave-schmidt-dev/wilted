import Foundation
import Observation
import WiltedDomain
import WiltedProducer

/// The one Add sheet's logic: one field, classified as you type. A link is
/// classified by the document, anything else searches Apple's catalogue.
/// `AddQuery` owns the state and drops stale answers; this class owns the
/// debounce, the task, and the routing of a chosen row onto the existing
/// Subscribe and Add article intake paths.
///
/// The field's text lives in `WiltedMacModel.urlDraft`, so a half-typed query
/// survives navigation and relaunch like every other draft.
@MainActor
@Observable
final class WiltedMacAddSession {
    typealias Search = @Sendable (String) async throws -> [PodcastCatalogShow]
    typealias Classify = @Sendable (URL) async throws -> PastedLinkKind

    /// One result with exactly one primary action.
    struct Row: Identifiable, Equatable {
        enum Action: Equatable { case subscribe, following, addArticle }
        let id: String
        let title: String
        let detail: String
        let action: Action
        let feedURL: URL?
        let articleURL: URL?
    }

    private(set) var query = AddQuery()
    /// The feed behind a pasted podcast link: the link itself, or the feed an
    /// Apple Podcasts show page resolved to (with the show's title).
    private(set) var resolvedFeed: (url: URL, title: String?)?
    /// A feed the pasted article page advertises; offered, never taken.
    private(set) var advertisedFeed: URL?

    @ObservationIgnored private let model: WiltedMacModel
    @ObservationIgnored private let search: Search
    @ObservationIgnored private let classify: Classify
    @ObservationIgnored private let linkDebounce: Duration
    @ObservationIgnored private let searchDebounce: Duration
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        model: WiltedMacModel, search: @escaping Search, classify: @escaping Classify,
        linkDebounce: Duration, searchDebounce: Duration
    ) {
        self.model = model
        self.search = search
        self.classify = classify
        self.linkDebounce = linkDebounce
        self.searchDebounce = searchDebounce
    }

    /// The single field.
    var text: String {
        get { model.urlDraft }
        set {
            model.urlDraft = newValue
            restart(immediately: false)
        }
    }

    var isWorking: Bool {
        switch query.state {
        case .classifying, .searching: true
        default: false
        }
    }

    /// What the intake last said about a Subscribe (including the article-feed refusal).
    var intakeMessage: String? { model.podcastFeedDraftStatus }
    var isSubscribing: Bool { model.isCheckingPodcastSubscription }

    /// Words for the sheet's current state; nil when the result list speaks for itself.
    var statusMessage: String? {
        switch query.state {
        case .idle: "Search for a podcast, or paste a link to a feed, a show or an article."
        case .classifying: "Checking that address\u{2026}"
        case .searching: "Searching\u{2026}"
        case let .results(results): results.isEmpty ? "No podcasts found. Try other words, or paste a link." : nil
        case .article, .podcastFeed: nil
        case let .unsupported(reason): reason
        case .unreachable: "Wilted could not finish that. Check the connection, then try again."
        case .cancelled: "Cancelled. Change the text to start again."
        }
    }

    var rows: [Row] {
        switch query.state {
        case let .results(results):
            return results.map { result in
                Row(
                    id: "show-\(result.show.collectionID)", title: result.show.title,
                    detail: result.show.author ?? result.show.feedURL.host ?? "",
                    action: isFollowed(result.show.feedURL) ? .following : .subscribe,
                    feedURL: result.show.feedURL, articleURL: nil
                )
            }
        case let .podcastFeed(pasted):
            let feed = resolvedFeed?.url ?? pasted
            return [feedRow(id: "feed", feed: feed, title: resolvedFeed?.title, detail: "Podcast")]
        case let .article(url):
            var rows = [Row(
                id: "article", title: Self.display(url), detail: "Article",
                action: .addArticle, feedURL: nil, articleURL: url
            )]
            if let advertisedFeed {
                rows.append(feedRow(
                    id: "advertised", feed: advertisedFeed, title: nil, detail: "Podcast feed on this page"
                ))
            }
            return rows
        default:
            return []
        }
    }

    /// Whether the feed is already a subscription, by its namespaced feed ID (W-INV-003).
    func isFollowed(_ feedURL: URL) -> Bool {
        guard let id = try? ItemID.derivePodcastFeed(from: feedURL) else { return false }
        return model.subscriptions.contains { $0.id == id.rawValue }
    }

    /// Opens with a clean intake status and re-evaluates a restored draft.
    func start() {
        model.podcastFeedDraftStatus = nil
        model.linkDraftStatus = nil
        model.advertisedFeed = nil
        restart(immediately: true)
    }

    /// Return in the field: answer now rather than after the quiet time.
    func submit() { restart(immediately: true) }

    func cancel() {
        task?.cancel()
        task = nil
        query.cancel()
    }

    func close() {
        task?.cancel()
        task = nil
        model.isPresentingComposer = false
    }

    /// Follows a show. A followed or in-flight show is never subscribed twice.
    func subscribe(_ row: Row) {
        guard row.action == .subscribe, let url = row.feedURL, !isFollowed(url), !isSubscribing else { return }
        model.podcastFeedDraftStatus = nil
        model.subscribeToPodcastFeed(url)
    }

    /// Adds the pasted page as one article and closes the sheet.
    func addArticle(_ row: Row) {
        guard row.action == .addArticle, let url = row.articleURL else { return }
        task?.cancel()
        task = nil
        model.urlDraft = url.absoluteString
        model.addArticle()
        model.urlDraft = ""
        query = AddQuery()
        resolvedFeed = nil
        advertisedFeed = nil
        model.isPresentingComposer = false
    }

    /// Lets a test wait for the in-flight classification or search.
    func settle() async { await task?.value }

    // MARK: Private

    /// An address as a person reads it: host and path, without scheme or trailing slash.
    private static func display(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        let path = url.path == "/" ? "" : url.path
        return host + path
    }

    private func feedRow(id: String, feed: URL, title: String?, detail: String) -> Row {
        Row(
            id: id, title: title ?? Self.display(feed), detail: detail,
            action: isFollowed(feed) ? .following : .subscribe, feedURL: feed, articleURL: nil
        )
    }

    private func restart(immediately: Bool) {
        task?.cancel()
        task = nil
        resolvedFeed = nil
        advertisedFeed = nil
        let effect = query.begin(model.urlDraft)
        let delay: Duration
        switch effect {
        case .none: return
        case .classify: delay = immediately ? .zero : linkDebounce
        case .search: delay = immediately ? .zero : searchDebounce
        }
        task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            await self.run(effect)
        }
    }

    private func run(_ effect: AddQuery.Effect) async {
        let answer: AddQuery.Answer?
        switch effect {
        case .none:
            answer = nil
        case let .classify(url, generation):
            answer = await classifyAnswer(url, generation: generation)
        case .search:
            answer = await AddQuery.run(
                effect, classify: { _ in .article }, search: search
            )
        }
        guard let answer, !Task.isCancelled else { return }
        query.apply(answer, isFollowed: { [self] in isFollowed($0.feedURL) })
    }

    private func classifyAnswer(_ url: URL, generation: Int) async -> AddQuery.Answer {
        let kind: AddQuery.LinkKind
        do {
            let found = try await classify(url)
            guard generation == query.generation else { return .init(generation: generation, outcome: .cancelled) }
            switch found {
            case .podcastFeed:
                resolvedFeed = (url, nil)
                kind = .podcastFeed
            case .article:
                kind = .article
            case let .articleAdvertisingFeed(feed):
                advertisedFeed = feed
                kind = .article
            case let .podcastCatalogShow(show):
                resolvedFeed = (show.feedURL, show.title)
                kind = .podcastFeed
            }
        } catch let error as PodcastCatalogLookupError where error != .cancelled {
            kind = .unsupported(WiltedMacModel.appleLookupFailureStatus(error))
        } catch is CancellationError {
            return .init(generation: generation, outcome: .cancelled)
        } catch {
            return .init(generation: generation, outcome: .failed)
        }
        return .init(generation: generation, outcome: .classified(kind))
    }
}

extension WiltedMacModel {
    /// Whether the Add sheet is open. The one flag every entry point sets.
    var isPresentingAddSheet: Bool {
        get { isPresentingComposer }
        set { isPresentingComposer = newValue }
    }

    func presentAddSheet() { isPresentingAddSheet = true }

    /// A session wired to the live classifier and Apple's catalogue search.
    /// Tests pass their own closures and a zero debounce.
    func makeAddSession(
        search: WiltedMacAddSession.Search? = nil,
        classify: WiltedMacAddSession.Classify? = nil,
        linkDebounce: Duration = .milliseconds(400),
        searchDebounce: Duration = PodcastCatalogLookupClient.searchDebounce
    ) -> WiltedMacAddSession {
        let catalogue = PodcastCatalogLookupClient()
        let classifier = pastedLinkClassifier
        let offline = fixtureMode
        return WiltedMacAddSession(
            model: self,
            search: search ?? { term in offline ? [] : try await catalogue.search(term: term) },
            classify: classify ?? { url in offline ? .article : try await classifier.classify(url) },
            linkDebounce: linkDebounce, searchDebounce: searchDebounce
        )
    }
}
