import Foundation
import SwiftData
import WiltedDomain

// MARK: - Feed document

/// One post an article feed lists. The link is the page to extract; the page's
/// own canonical URL (which decides the article's ID) is only known once it has
/// been extracted, and may differ from this link.
public struct ArticleFeedItem: Equatable, Sendable {
    public let guid: String?
    public let title: String
    public let link: URL
    public let publishedAt: Date?

    public init(guid: String?, title: String, link: URL, publishedAt: Date?) {
        self.guid = guid; self.title = title; self.link = link; self.publishedAt = publishedAt
    }

    /// The item's identity inside `feedURL`: its GUID, else its link.
    public func id(feedURL: URL) throws -> ItemID {
        try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: link)
    }
}

/// A parsed article feed: its channel title and the posts it lists, newest first.
public struct ArticleFeedDocument: Equatable, Sendable {
    public let title: String
    public let author: String?
    public let items: [ArticleFeedItem]
}

/// A feed Wilted follows for its posts rather than for audio.
public struct ArticleFeed: Equatable, Sendable {
    public let itemID: ItemID
    public let canonicalURL: URL
    public let title: String
    public let author: String?
    public let createdAt: Timestamp

    public init(canonicalURL: URL, title: String, author: String? = nil, createdAt: Timestamp) throws {
        let normalized = try ItemID.canonicalURL(canonicalURL)
        guard !title.isEmpty, title.count <= 1_024 else {
            throw DomainError.invalidValue(field: "title", reason: "must contain 1...1024 characters")
        }
        itemID = try ItemID.articleFeed(canonicalFeedURL: normalized)
        self.canonicalURL = normalized; self.title = title; self.author = author; self.createdAt = createdAt
    }
}

public enum ArticleFeedParseError: Error, Equatable, Sendable {
    case malformedXML
    case externalEntity
    case missingTitle
}

/// Reads the posts of an RSS 2.0 or Atom feed. It never reads enclosures: a feed
/// with audio is a podcast, and `PodcastRSSParser` owns that.
public enum ArticleFeedParser {
    /// A feed listing more posts than this keeps its newest.
    public static let maximumItemCount = 200

    public static func parse(_ data: Data, feedURL: URL) throws -> ArticleFeedDocument {
        if let refusal = UntrustedXML.refusal(in: data, doctype: .allowBare) {
            throw refusal.isDeclarationRefusal ? ArticleFeedParseError.externalEntity : ArticleFeedParseError.malformedXML
        }
        let reader = Reader(feedURL: feedURL)
        let parser = UntrustedXML.makeParser(data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        guard parser.parse(), reader.failure == nil else { throw reader.failure ?? .malformedXML }
        guard let title = reader.channelTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw ArticleFeedParseError.missingTitle
        }
        let ranked = reader.items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.publishedAt, rhs.element.publishedAt) {
            case let (left?, right?) where left != right: return left > right
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }
        return ArticleFeedDocument(
            title: String(title.prefix(1_024)), author: reader.channelAuthor,
            items: ranked.prefix(maximumItemCount).map(\.element)
        )
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Draft { var title = "", guid: String?, link: String?, atomLink: String?, date: String?, hasEnclosure = false }
        let feedURL: URL
        var channelTitle: String?
        var channelAuthor: String?
        var items: [ArticleFeedItem] = []
        var failure: ArticleFeedParseError?
        private var draft: Draft?
        private var text = ""
        private var capturing = false

        init(feedURL: URL) { self.feedURL = feedURL }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let element = name.lowercased()
            if element == "item" || element == "entry" { draft = Draft() }
            if draft != nil, element == "link", (namespaceURI ?? "").isEmpty || namespaceURI?.contains("Atom") == true {
                let rel = attributeDict["rel"] ?? "alternate"
                if let href = attributeDict["href"], rel == "alternate", draft?.atomLink == nil { draft?.atomLink = href }
            }
            capturing = ["title", "link", "guid", "id", "pubdate", "published", "updated", "date", "author", "creator", "name"]
                .contains(element)
            text = ""
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            failure = .externalEntity
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            failure = .externalEntity
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if capturing { text += string } }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if capturing, let value = String(data: CDATABlock, encoding: .utf8) { text += value }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = name.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { capturing = false; text = "" }
            if element == "item" || element == "entry" { finishDraft(); return }
            guard capturing, !value.isEmpty else { return }
            if var current = draft {
                switch element {
                case "title": if current.title.isEmpty { current.title = value }
                case "link": if (namespaceURI ?? "").isEmpty { current.link = value }
                case "guid", "id": if current.guid == nil { current.guid = value }
                case "pubdate", "published", "date", "updated": if current.date == nil { current.date = value }
                default: break
                }
                draft = current
            } else if element == "title", channelTitle == nil {
                channelTitle = value
            } else if element == "name" || element == "creator" || element == "author", channelAuthor == nil {
                channelAuthor = String(value.prefix(512))
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failure = failure ?? .malformedXML }

        private func finishDraft() {
            defer { draft = nil }
            guard let draft, let raw = draft.link ?? draft.atomLink,
                  let link = URL(string: raw, relativeTo: feedURL)?.absoluteURL,
                  link.scheme?.lowercased() == "https", link.host?.isEmpty == false,
                  link.user == nil, link.password == nil,
                  link.absoluteString.count <= PodcastEpisode.maximumEpisodeLinkLength else { return }
            let title = draft.title.isEmpty ? link.absoluteString : String(draft.title.prefix(1_024))
            let guid = draft.guid.flatMap { $0.utf8.count <= 1_024 ? $0 : nil }
            items.append(ArticleFeedItem(guid: guid, title: title, link: link, publishedAt: draft.date.flatMap(Self.date)))
        }

        private static func date(_ raw: String) -> Date? {
            let iso = ISO8601DateFormatter()
            if let value = iso.date(from: raw) { return value }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = iso.date(from: raw) { return value }
            let rfc = DateFormatter()
            rfc.locale = Locale(identifier: "en_US_POSIX")
            for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss zzz"] {
                rfc.dateFormat = format
                if let value = rfc.date(from: raw) { return value }
            }
            return nil
        }
    }
}

extension PodcastFeedClient {
    /// Loads a feed's posts rather than its episodes, over the same HTTPS-only,
    /// size-bounded transport as `load(_:)`.
    public func loadArticleFeed(_ url: URL) async throws -> ArticleFeedDocument {
        guard Self.isHTTPS(url) else { throw PodcastFeedClientError.invalidURL }
        do {
            let response = try await loader.load(url, maximumBytes: Self.maximumFeedBytes)
            try Task.checkCancellation()
            guard response.data.count <= Self.maximumFeedBytes else { throw PodcastFeedClientError.responseTooLarge }
            guard (200..<300).contains(response.statusCode) else {
                throw PodcastFeedClientError.invalidResponse(response.statusCode)
            }
            guard Self.isHTTPS(response.url) else { throw PodcastFeedClientError.invalidURL }
            return try ArticleFeedParser.parse(response.data, feedURL: url)
        } catch is CancellationError {
            throw PodcastFeedClientError.cancelled
        } catch let error as PodcastFeedClientError {
            throw error
        } catch let error as ArticleFeedParseError {
            throw error == .externalEntity ? PodcastFeedClientError.externalEntity : PodcastFeedClientError.malformedXML
        } catch {
            throw Task.isCancelled ? PodcastFeedClientError.cancelled : PodcastFeedClientError.transport(String(describing: error))
        }
    }
}

// MARK: - Store

extension LocalLibraryStore {
    /// Inserts or updates an article feed. It is a `PodcastFeedRecord` row with an
    /// `article.feed` source kind, because `PodcastFeed` only accepts a podcast ID.
    public func save(articleFeed feed: ArticleFeed) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.PodcastFeedRecord>())
        if let existing = records.first(where: { $0.id == feed.itemID.rawValue }) {
            existing.title = feed.title; existing.author = feed.author
            existing.canonicalURL = feed.canonicalURL.absoluteString
        } else {
            // `PodcastFeed` only accepts a podcast ID, so the row starts as the podcast feed
            // for the same address and takes the article feed's identity and kind.
            let stand = try PodcastFeed(itemID: ItemID.derivePodcastFeed(from: feed.canonicalURL),
                                        canonicalURL: feed.canonicalURL, title: feed.title,
                                        author: feed.author, createdAt: feed.createdAt)
            let record = LocalLibrarySchemaV17Models.PodcastFeedRecord(stand, sourceKind: ArticleFeedSourceKind.value)
            record.id = feed.itemID.rawValue
            context.insert(record)
        }
        try context.save()
    }

    public func articleFeed(for feedID: ItemID) throws -> ArticleFeed? {
        try articleFeeds().first { $0.itemID == feedID }
    }

    /// Every followed article feed, by title.
    public func articleFeeds() throws -> [ArticleFeed] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.PodcastFeedRecord>())
            .filter { $0.sourceKind == ArticleFeedSourceKind.value }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .compactMap { record in
                guard let url = URL(string: record.canonicalURL),
                      let feed = try? ArticleFeed(canonicalURL: url, title: record.title, author: record.author,
                                                  createdAt: Timestamp(record.createdAt)),
                      feed.itemID.rawValue == record.id else { return nil }
                return feed
            }
    }
}

enum ArticleFeedSourceKind {
    /// The stored `sourceKind` of an article feed (the library kind's raw value).
    static let value = "article.feed"
}

// MARK: - Refresh

/// What one refresh of an article feed did with the posts it listed.
public struct ArticleFeedRefreshResult: Equatable, Sendable {
    /// Posts left for the reader to keep or skip: no rule or policy decided them.
    public var offered: [ArticleFeedItem] = []
    /// Posts kept and prepared; each saved as an article carrying the feed's ID.
    public var prepared: [ArticleFeedItem] = []
    public var skipped: [ArticleFeedItem] = []
    /// Kept posts whose preparation failed. They are decided nothing, so the next refresh tries again.
    public var failed: [ArticleFeedItem] = []
    /// Posts not offered because an earlier refresh or the reader already dealt with them.
    public var alreadyConsumedCount = 0
}

/// Lists an article feed's posts and applies the feed's keep/skip rules and
/// policy to them, the way a podcast refresh does for episodes.
public struct ArticleFeedRefresh: Sendable {
    /// Prepares the page at a link and returns the ID of the article it saved,
    /// which is derived from the page's canonical URL and so may not match the link.
    public typealias Prepare = @Sendable (URL) async throws -> ItemID

    private let store: LocalLibraryStore
    private let defaults: FeedAutomationGlobalDefaults
    private let now: @Sendable () -> Date

    public init(store: LocalLibraryStore, defaults: FeedAutomationGlobalDefaults = .standard,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.defaults = defaults; self.now = now
    }

    /// Refreshes one followed feed. `progress` is told what is happening, one
    /// line per post that is prepared, so a long refresh never sits silent (W-INV-001).
    public func refresh(
        feed: ArticleFeed, document: ArticleFeedDocument, prepare: Prepare?,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> ArticleFeedRefreshResult {
        let policy = try await store.feedAutomationPolicy(for: feed.itemID).resolved(using: defaults)
        let rules = try await store.episodeMatchRules(for: feed.itemID)
        var result = ArticleFeedRefreshResult()
        var pending: [(item: ArticleFeedItem, id: ItemID, source: EpisodeDecisionSource, rule: UUID?)] = []
        var seen = Set<ItemID>()
        for item in document.items {
            let id = try item.id(feedURL: feed.canonicalURL)
            // A feed that repeats a post is offered it once.
            if !seen.insert(id).inserted { result.alreadyConsumedCount += 1; continue }
            if try await isConsumed(item, id: id) { result.alreadyConsumedCount += 1; continue }
            let match = try rules.evaluate(EpisodeMatchEpisode(id: id.rawValue, title: item.title, notes: ""))
            switch match {
            case let .skip(ruleID):
                try await store.save(episodeDecision: decision(id, .skip, .rule, ruleID))
                result.skipped.append(item)
            case let .keep(ruleID):
                pending.append((item, id, .rule, ruleID))
            case .noMatch, .timedOut:
                pending.append((item, id, .policy, nil))
            }
        }
        // Rules keep unconditionally; the policy keeps up to its limit, oldest first.
        let keptIDs = Set(try await store.articleIDs(forFeed: feed.itemID).map(\.rawValue))
        let planned = FeedAdmissionPlanner.plan(
            candidates: pending.filter { $0.source == .policy }.map {
                FeedAdmissionCandidate(id: $0.id.rawValue, releaseDate: $0.item.publishedAt ?? .distantPast)
            },
            keptEpisodeIDs: keptIDs, playingEpisodeID: nil, partHeardEpisodeIDs: [], manualDecisions: [:], policy: policy
        )
        let keepNow = Set(planned.filter { $0.outcome == .keepNow }.map(\.candidate.id))
        for entry in pending {
            guard entry.source == .rule || keepNow.contains(entry.id.rawValue) else {
                result.offered.append(entry.item); continue
            }
            guard let prepare else { result.offered.append(entry.item); continue }
            progress("Preparing \(entry.item.title)")
            if try await keep(entry.item, id: entry.id, feed: feed, source: entry.source, ruleID: entry.rule, prepare: prepare) {
                result.prepared.append(entry.item)
            } else {
                result.failed.append(entry.item)
            }
        }
        return result
    }

    /// The reader's own keep: prepares the post and records it consumed. Returns
    /// false when preparation failed, leaving the post undecided.
    @discardableResult
    public func keep(_ item: ArticleFeedItem, feed: ArticleFeed, prepare: Prepare) async throws -> Bool {
        try await keep(item, id: item.id(feedURL: feed.canonicalURL), feed: feed, source: .manual, ruleID: nil, prepare: prepare)
    }

    /// The reader's own skip: the post is never offered again.
    public func skip(_ item: ArticleFeedItem, feed: ArticleFeed) async throws {
        try await store.save(episodeDecision: decision(item.id(feedURL: feed.canonicalURL), .skip, .manual, nil))
    }

    private func keep(_ item: ArticleFeedItem, id: ItemID, feed: ArticleFeed, source: EpisodeDecisionSource,
                      ruleID: UUID?, prepare: Prepare) async throws -> Bool {
        let articleID: ItemID
        do { articleID = try await prepare(item.link) } catch is CancellationError { throw CancellationError() } catch { return false }
        // The article is saved by preparation; the feed's claim on it is added here.
        try await store.assign(articleID: articleID, toFeed: feed.itemID)
        try await store.save(episodeDecision: decision(id, .keep, source, ruleID))
        // The resulting article ID is consumed too, so a page that resolves to an article
        // this post's link is not (a different canonical URL) is still never offered twice.
        try await store.save(episodeDecision: decision(articleID, .keep, source, ruleID))
        return true
    }

    /// True when the reader or an earlier refresh already decided the post, or its
    /// page is already an article (added by hand, or by another post).
    private func isConsumed(_ item: ArticleFeedItem, id: ItemID) async throws -> Bool {
        if try await store.episodeDecision(for: id) != nil { return true }
        guard let linkArticleID = try? ItemID.derive(from: item.link) else { return false }
        if try await store.episodeDecision(for: linkArticleID) != nil { return true }
        return try await store.article(for: linkArticleID) != nil
    }

    private func decision(_ id: ItemID, _ value: EpisodeDecision, _ source: EpisodeDecisionSource, _ ruleID: UUID?)
        -> EpisodeDecisionRecord {
        EpisodeDecisionRecord(episodeID: id, decision: value, source: source, ruleID: ruleID, decidedAt: Timestamp(now()))
    }
}

// MARK: - Preparation

extension PreparationCoordinator {
    /// Prepares the article at `url` and returns the ID of the article it saved.
    public func prepareArticle(url: URL, progress: @Sendable (String) -> Void = { _ in }) async throws -> ItemID {
        let run = start(url: url)
        var terminal: PreparationStatus?
        for await status in run.statuses {
            progress(status.detail)
            if status.terminal { terminal = status }
        }
        try Task.checkCancellation()
        guard terminal?.terminalResult?.outcome == .succeeded, let id = resolvedItemID(forRun: run.runID) else {
            throw ArticlePreparationError.failed(terminal?.terminalResult?.error?.message ?? "Preparation did not finish.")
        }
        return id
    }
}

public enum ArticlePreparationError: Error, Equatable, Sendable {
    case failed(String)
}
