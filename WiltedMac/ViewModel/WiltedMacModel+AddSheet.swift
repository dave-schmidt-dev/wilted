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
    /// Whether the feed at the address lists no audio, so it can only be followed for its articles.
    typealias FeedHasNoAudio = @Sendable (URL) async -> Bool
    /// Reports an import's overall fraction (0...1) and a sentence about the current step.
    typealias ImportProgress = @Sendable (Double, String) -> Void
    /// What an import produced: the library items it made, and whether they were already there.
    typealias ImportOutcome = (itemIDs: [ItemID], alreadyImported: Bool)
    typealias ConvertBook = @MainActor (URL, @escaping ImportProgress) async throws -> ImportOutcome
    typealias ImportAudio = @MainActor ([URL], @escaping ImportProgress) async throws -> ImportOutcome

    /// Where a book import stands, shown in the sheet beneath the field.
    enum ImportState: Equatable {
        case idle
        case working(fraction: Double, detail: String)
        /// Nothing was imported; the text is the reason, in the importer's own words.
        case refused(String)
        case cancelled
        case finished(String)
    }

    /// One result with exactly one primary action.
    struct Row: Identifiable, Equatable {
        enum Action: Equatable { case subscribe, followArticleFeed, following, addArticle }
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
    /// Feeds the session saw list no audio: offered as "Follow as article feed".
    private(set) var articleOnlyFeeds: Set<URL> = []
    private(set) var importState = ImportState.idle
    /// Why an Add article press did not start a run, shown beneath the field.
    private(set) var articleStatusMessage: String?

    @ObservationIgnored private let model: WiltedMacModel
    @ObservationIgnored private let search: Search
    @ObservationIgnored private let classify: Classify
    @ObservationIgnored private let feedHasNoAudio: FeedHasNoAudio
    @ObservationIgnored private let convertBook: ConvertBook
    @ObservationIgnored private let importAudio: ImportAudio
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private let linkDebounce: Duration
    @ObservationIgnored private let searchDebounce: Duration
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        model: WiltedMacModel, search: @escaping Search, classify: @escaping Classify,
        feedHasNoAudio: @escaping FeedHasNoAudio, convertBook: @escaping ConvertBook,
        importAudio: @escaping ImportAudio, linkDebounce: Duration, searchDebounce: Duration
    ) {
        self.model = model
        self.search = search
        self.classify = classify
        self.feedHasNoAudio = feedHasNoAudio
        self.convertBook = convertBook
        self.importAudio = importAudio
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
        if let articleStatusMessage { return articleStatusMessage }
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
        // A feed without audio is followed as an article feed, under its own ID.
        let ids = [try? ItemID.derivePodcastFeed(from: feedURL), try? ItemID.articleFeed(canonicalFeedURL: feedURL)]
            .compactMap { $0?.rawValue }
        return model.subscriptions.contains { ids.contains($0.id) }
    }

    /// Opens with a clean intake status and re-evaluates a restored draft.
    func start() {
        model.podcastFeedDraftStatus = nil
        model.linkDraftStatus = nil
        model.advertisedFeed = nil
        articleStatusMessage = nil
        restart(immediately: true)
    }

    /// Return in the field: answer now rather than after the quiet time.
    func submit() { restart(immediately: true) }

    func cancel() {
        task?.cancel()
        task = nil
        query.cancel()
    }

    /// Stops everything the sheet started, including a book import: nothing runs unseen once it is gone.
    func teardown() {
        cancel()
        cancelImport()
    }

    func close() {
        teardown()
        model.isPresentingComposer = false
    }

    /// Follows a show. A followed or in-flight show is never subscribed twice.
    func subscribe(_ row: Row) {
        guard row.action == .subscribe || row.action == .followArticleFeed,
              let url = row.feedURL, !isFollowed(url), !isSubscribing else { return }
        model.podcastFeedDraftStatus = nil
        model.subscribeToPodcastFeed(url)
    }

    /// Adds the pasted page as one article. The sheet stays open with the
    /// owner's text until the model confirms that a run actually started.
    func addArticle(_ row: Row) {
        guard row.action == .addArticle, let url = row.articleURL else { return }
        guard WiltedMacModel.articleURL(from: url.absoluteString) != nil else {
            articleStatusMessage = WiltedMacModel.invalidArticleURLDetail
            return
        }
        task?.cancel()
        task = nil
        model.urlDraft = url.absoluteString
        guard model.addArticle() else {
            articleStatusMessage = model.preparation?.detail ?? WiltedMacModel.invalidArticleURLDetail
            return
        }
        articleStatusMessage = nil
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
            action: isFollowed(feed) ? .following : (articleOnlyFeeds.contains(feed) ? .followArticleFeed : .subscribe),
            feedURL: feed, articleURL: nil
        )
    }

    private func restart(immediately: Bool) {
        task?.cancel()
        task = nil
        articleStatusMessage = nil
        resolvedFeed = nil
        advertisedFeed = nil
        articleOnlyFeeds = []
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
                let noAudio = await feedHasNoAudio(url)
                guard generation == query.generation else { return .init(generation: generation, outcome: .cancelled) }
                if noAudio { articleOnlyFeeds.insert(url) }
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

// MARK: - Book import

extension WiltedMacAddSession {
    static let libraryUnavailable = AudiobookImportError.unsupportedInput("The local larder is unavailable.")
    private static let bookExtensions: Set<String> = ["epub", "pdf"]

    var isImporting: Bool { importTask != nil }

    /// Imports what the person chose or dropped: audio files or one folder as an audiobook, one EPUB or PDF
    /// as a book converted to speech. Refusals land in `importState` with the importer's own reason.
    func importBook(from urls: [URL]) {
        guard !isImporting else { return }
        let books = urls.filter { Self.bookExtensions.contains($0.pathExtension.lowercased()) }
        if urls.isEmpty {
            importState = .refused("Choose audio files, a folder of audio files, an EPUB or a PDF.")
            return
        }
        if !books.isEmpty, urls.count > 1 {
            importState = .refused("Import one EPUB or PDF at a time, on its own.")
            return
        }
        importState = .working(fraction: 0, detail: "Starting")
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        let report: ImportProgress = { [weak self] fraction, detail in
            Task { @MainActor in self?.noteProgress(fraction, detail) }
        }
        importTask = Task { [weak self] in
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            guard let self else { return }
            let outcome: Result<ImportOutcome, Error>
            do {
                if let book = books.first {
                    outcome = .success(try await self.convertBook(book, report))
                } else {
                    outcome = .success(try await self.importAudio(urls, report))
                }
            } catch {
                outcome = .failure(error)
            }
            await self.finishImport(outcome)
        }
    }

    /// Stops a running import; the importers remove any partial output themselves.
    func cancelImport() {
        guard importTask != nil else { return }
        importTask?.cancel()
        importState = .cancelled
    }

    /// Lets a test wait for the in-flight import.
    func settleImport() async { await importTask?.value }

    /// Puts the sheet in a given import state without running an import (snapshots).
    func showImportForPreview(_ state: ImportState) { importState = state }

    private func noteProgress(_ fraction: Double, _ detail: String) {
        guard case .working = importState else { return }
        importState = .working(fraction: min(max(fraction, 0), 1), detail: detail)
    }

    private func finishImport(_ outcome: Result<ImportOutcome, Error>) async {
        let wasCancelled = importState == .cancelled || Task.isCancelled
        importTask = nil
        switch outcome {
        case let .success(result):
            let count = result.itemIDs.count
            importState = .finished(
                result.alreadyImported ? "That book is already in your library."
                    : count > 1 ? "Imported in \(count) parts. Find it in your library."
                    : "Imported. Find it in your library."
            )
            await model.reloadLibraryRows()
        case let .failure(error):
            switch error {
            case is CancellationError, AudiobookImportError.cancelled, BookConversionError.cancelled,
                 BookExtractionError.cancelled:
                importState = .cancelled
            default:
                importState = wasCancelled ? .cancelled : .refused(error.localizedDescription)
            }
        }
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
        feedHasNoAudio: WiltedMacAddSession.FeedHasNoAudio? = nil,
        convertBook: WiltedMacAddSession.ConvertBook? = nil,
        importAudio: WiltedMacAddSession.ImportAudio? = nil,
        linkDebounce: Duration = .milliseconds(400),
        searchDebounce: Duration = PodcastCatalogLookupClient.searchDebounce
    ) -> WiltedMacAddSession {
        let catalogue = PodcastCatalogLookupClient()
        let classifier = pastedLinkClassifier
        let offline = fixtureMode
        let feedClient = podcastFeedClient
        return WiltedMacAddSession(
            model: self,
            search: search ?? { term in offline ? [] : try await catalogue.search(term: term) },
            classify: classify ?? { url in offline ? .article : try await classifier.classify(url) },
            feedHasNoAudio: feedHasNoAudio ?? { url in
                offline ? false : (try? await feedClient.load(url))?.episodes.isEmpty == true
            },
            convertBook: convertBook ?? { [unowned self] url, progress in
                guard let store else { throw WiltedMacAddSession.libraryUnavailable }
                let result = try await BookConversion(store: store).convert(from: url) { step in
                    progress(step.fraction, step.detail)
                }
                return (result.itemIDs, result.alreadyImported)
            },
            importAudio: importAudio ?? { [unowned self] urls, progress in
                guard let store else { throw WiltedMacAddSession.libraryUnavailable }
                let result = try await AudiobookImporter(store: store).importBook(from: urls) { step in
                    progress(step.fraction, step.detail)
                }
                return (result.itemIDs, result.alreadyImported)
            },
            linkDebounce: linkDebounce, searchDebounce: searchDebounce
        )
    }
}
