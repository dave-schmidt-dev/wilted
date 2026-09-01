import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a pasted address turned out to be.
public enum PastedLinkKind: Equatable, Sendable {
    /// A podcast feed. Subscribing is the only sensible action.
    case podcastFeed
    /// An ordinary page. Saving it as an article is the only sensible action.
    case article
    /// A page that advertises a feed of its own. The article is still what was
    /// asked for; the feed is offered, never taken, because a blog's feed is a
    /// different subscription from the one article the reader pasted.
    case articleAdvertisingFeed(URL)
}

public enum PastedLinkClassifierError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a complete HTTPS address."
        case .unreachable: "Wilted could not reach that address. Check it, or retry when online."
        }
    }
}

/// Decides whether a pasted address is a podcast feed or an article.
///
/// The decision is made from the body, not the headers: the transport this
/// shares with `PodcastFeedClient` reports only the final URL, the status, and
/// the bytes, and a Content-Type would not settle it anyway -- feeds are served
/// as `text/xml`, `application/xml`, and `application/octet-stream` in the wild.
public struct PastedLinkClassifier: Sendable {
    /// Enough of a document to see its root element and, for a page, the
    /// `<link rel="alternate">` tags that live in `<head>`. Bounded because the
    /// address is untrusted and the whole document is never needed.
    public static let maximumSniffBytes = 128 * 1_024

    private let loader: any PodcastFeedLoading

    public init(loader: any PodcastFeedLoading = URLSessionPodcastFeedLoader()) {
        self.loader = loader
    }

    public func classify(_ url: URL) async throws -> PastedLinkKind {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw PastedLinkClassifierError.invalidURL
        }
        // Only extensions that no article uses short-circuit the fetch. A path
        // that merely contains "feed" is not one of them: an article at
        // /feed-your-brain would be handed to the XML parser and the reader
        // would get a parse error instead of their article.
        if Self.feedExtensions.contains(url.pathExtension.lowercased()) {
            return .podcastFeed
        }

        let response: PodcastFeedHTTPResponse
        do {
            response = try await loader.load(url, maximumBytes: Self.maximumSniffBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PastedLinkClassifierError.unreachable(String(describing: error))
        }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw PastedLinkClassifierError.unreachable("status \(response.statusCode)")
        }
        return Self.classify(body: response.data, baseURL: response.url)
    }

    private static let feedExtensions: Set<String> = ["xml", "rss", "atom"]

    /// The body rule, separated from the fetch so it is testable on its own.
    static func classify(body: Data, baseURL: URL) -> PastedLinkKind {
        let document = String(decoding: body.prefix(maximumSniffBytes), as: UTF8.self)
        let htmlRoot = document.range(of: "<html", options: .caseInsensitive)?.lowerBound
        // Whichever root element appears first decides it. A feed may legally
        // carry the word "html" in a namespace or an escaped payload, and a
        // page may name a feed format in a link tag, so presence alone is not
        // enough -- position is.
        let feedRoot = ["<rss", "<feed", "<rdf:RDF"]
            .compactMap { document.range(of: $0, options: .caseInsensitive)?.lowerBound }
            .min()
        if let feedRoot, htmlRoot == nil || feedRoot < htmlRoot! {
            return .podcastFeed
        }
        if let advertised = advertisedFeedURL(inHTML: document, baseURL: baseURL) {
            return .articleAdvertisingFeed(advertised)
        }
        return .article
    }

    /// The first RSS or Atom `<link rel="alternate">` a page declares.
    ///
    /// Scanned rather than parsed, because real pages are not well-formed XML,
    /// and the scan is deliberately shallow: it reads the attributes of one tag
    /// and resolves one href. The document keeps its original case throughout,
    /// since lowercasing it would corrupt the href's path.
    static func advertisedFeedURL(inHTML html: String, baseURL: URL) -> URL? {
        var remainder = Substring(html)
        while let open = remainder.range(of: "<link", options: .caseInsensitive) {
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.firstIndex(of: ">") else { return nil }
            let tag = afterOpen[..<close]
            remainder = afterOpen[afterOpen.index(after: close)...]
            guard let type = attribute("type", in: tag)?.lowercased(),
                  type == "application/rss+xml" || type == "application/atom+xml",
                  let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.split(separator: " ").contains("alternate"),
                  let href = attribute("href", in: tag),
                  let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  resolved.scheme?.lowercased() == "https", resolved.host != nil
            else { continue }
            return resolved
        }
        return nil
    }

    /// One quoted attribute value from a tag, or nil if the tag does not carry
    /// it. A match must start at an attribute boundary so that `type=` is not
    /// read out of `data-type=`.
    private static func attribute(_ name: String, in tag: Substring) -> String? {
        var remainder = tag
        while let match = remainder.range(of: "\(name)=", options: .caseInsensitive) {
            let precedes: Character? = match.lowerBound == remainder.startIndex
                ? nil
                : remainder[remainder.index(before: match.lowerBound)]
            remainder = remainder[match.upperBound...]
            if let precedes, !precedes.isWhitespace { continue }
            guard let quote = remainder.first, quote == "\"" || quote == "'" else { continue }
            let value = remainder.dropFirst()
            guard let end = value.firstIndex(of: quote) else { return nil }
            return String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
