import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WiltedDomain

final class PodcastRSSParser: NSObject, XMLParserDelegate {
    private struct Item {
        var title: String?
        var guid: String?
        var author: String?
        var publishedAt: Date?
        var enclosureURL: URL?
        var enclosureType: String?
        var enclosureLength: Int64?
        var duration: Double?
        var artworkURL: URL?
        /// The item's plain RSS `<link>` text, unresolved. Atom links carry
        /// their address in an attribute and a namespace, and are not read.
        var link: String?
        var transcriptSources: [PodcastTranscriptSource] = []
        /// Candidate show notes keyed by element, resolved after the item
        /// closes: feeds publish the same notes under two or three names and
        /// the fullest one is not always first.
        var notesCandidates: [String: String] = [:]
    }

    private let feedURL: URL
    private let createdAt: Date
    private var channelTitle: String?
    private var channelAuthor: String?
    private var channelArtworkURL: URL?
    private var currentItem: Item?
    private var completedItems: [Item] = []
    private var text = ""
    private var textElement: String?
    /// The current `<link>` outgrew `PodcastEpisode.maximumEpisodeLinkLength`; it is dropped, not fatal.
    private var linkOverflowed = false
    private var parseFailure: PodcastFeedClientError?

    init(feedURL: URL, createdAt: Date) {
        self.feedURL = feedURL
        self.createdAt = createdAt
    }

    func parse(_ data: Data) throws -> LoadedPodcastFeed {
        guard !declaresExternalEntity(data) else { throw PodcastFeedClientError.externalEntity }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw parseFailure ?? PodcastFeedClientError.malformedXML }
        if let parseFailure { throw parseFailure }
        guard let title = bounded(channelTitle, maximum: 1_024) else {
            throw PodcastFeedClientError.invalidMetadata("channel title")
        }
        let author = try optionalText(channelAuthor, maximum: 512, field: "channel author")
        let artworkURL = safeArtworkURL(channelArtworkURL)
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: title, author: author,
            artworkURL: artworkURL, createdAt: Timestamp(createdAt)
        )
        var episodes: [PodcastEpisode] = []
        for item in completedItems {
            guard let enclosureURL = item.enclosureURL else { continue }
            guard PodcastFeedClient.isHTTPS(enclosureURL) else {
                throw PodcastFeedClientError.invalidMetadata("enclosure URL")
            }
            guard let enclosureType = item.enclosureType, supportedAudioTypes.contains(enclosureType) else {
                throw PodcastFeedClientError.unsupportedEnclosureMediaType(item.enclosureType ?? "missing")
            }
            guard let title = bounded(item.title, maximum: 1_024) else {
                throw PodcastFeedClientError.invalidMetadata("episode title")
            }
            let guid = try optionalText(item.guid, maximum: 1_024, field: "episode GUID")
            let author = try optionalText(item.author, maximum: 512, field: "episode author")
            let artworkURL = safeArtworkURL(item.artworkURL)
            let episodeLink = Self.episodeLink(item.link, feedURL: feedURL, enclosureURL: enclosureURL)
            let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL)
            episodes.append(try PodcastEpisode(
                itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: guid,
                title: title, author: author, publishedTime: item.publishedAt.map(Timestamp.init),
                enclosureURL: enclosureURL, enclosureMediaType: enclosureType,
                enclosureByteCount: item.enclosureLength, durationSeconds: item.duration,
                artworkURL: artworkURL, transcriptSources: item.transcriptSources,
                notes: Self.notes(from: item.notesCandidates),
                episodeLink: episodeLink,
                createdAt: Timestamp(createdAt)
            ))
        }
        let (kept, dropped) = Self.newestEpisodes(episodes)
        return LoadedPodcastFeed(feed: feed, episodes: kept, droppedEpisodeCount: dropped)
    }

    /// The episode's own page from an RSS `<link>`, or nil when it is unsafe.
    ///
    /// Like notes and transcripts this is an optional extra and never fails the
    /// feed. A relative address resolves against the feed; only http(s) with a
    /// host and no credentials is kept, and an address that is just the
    /// enclosure or the feed itself is not a page about the episode.
    static func episodeLink(_ raw: String?, feedURL: URL, enclosureURL: URL) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !raw.contains(where: { $0.isWhitespace || $0.isNewline }),
              let resolved = URL(string: raw, relativeTo: feedURL)?.absoluteURL,
              PodcastEpisode.isValidEpisodeLink(resolved)
        else { return nil }
        func withoutFragment(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.fragment = nil
            return components?.string ?? url.absoluteString
        }
        let candidate = withoutFragment(resolved)
        guard candidate != withoutFragment(feedURL), candidate != withoutFragment(enclosureURL) else { return nil }
        return resolved
    }

    /// Show notes are an optional extra, like transcripts: they never fail the
    /// feed. The longest candidate wins because `content:encoded` is usually
    /// the full notes and `description` a summary of them, but not always, and
    /// the longer one is never the worse glossary. Over-long notes are cut,
    /// not refused.
    static func notes(from candidates: [String: String]) -> String? {
        let text = candidates.values
            .map(plainText(fromHTML:))
            .filter { !$0.isEmpty }
            .max { $0.count < $1.count }
        guard let text else { return nil }
        return String(text.prefix(PodcastEpisode.maximumNotesLength))
    }

    /// Element names, as `XMLParser` reports them with namespaces processed,
    /// that carry show notes; `encoded` is `content:encoded`, `summary` is
    /// `itunes:summary`.
    static let notesElements: Set<String> = ["description", "encoded", "summary"]
    /// Notes may run long; every other captured field is bounded far lower.
    static let maximumNotesBytes = 65_536

    /// Keeps the newest `PodcastFeedClient.maximumEpisodeCount` episodes and
    /// reports how many were dropped.
    ///
    /// Recency comes from the published time; an undated episode sorts behind
    /// every dated one because there is nothing to argue it is recent. Ties and
    /// undated episodes keep feed order, and the survivors are returned in feed
    /// order so truncation never reshuffles a feed that was under the ceiling.
    static func newestEpisodes(_ episodes: [PodcastEpisode]) -> (kept: [PodcastEpisode], dropped: Int) {
        guard episodes.count > PodcastFeedClient.maximumEpisodeCount else { return (episodes, 0) }
        let ranked = episodes.enumerated().sorted { lhs, rhs in
            switch (lhs.element.publishedTime?.date, rhs.element.publishedTime?.date) {
            case let (left?, right?) where left != right: return left > right
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }
        let survivors = ranked.prefix(PodcastFeedClient.maximumEpisodeCount)
            .sorted { $0.offset < $1.offset }
            .map(\.element)
        return (survivors, episodes.count - survivors.count)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        parseFailure = .externalEntity
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        parseFailure = .externalEntity
        parser.abortParsing()
        return nil
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if parseFailure == nil { parseFailure = .malformedXML }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        if name == "item" {
            currentItem = Item()
        }
        if name == "enclosure", currentItem != nil {
            currentItem?.enclosureURL = attributeDict["url"].flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            currentItem?.enclosureType = normalizedMediaType(attributeDict["type"])
            currentItem?.enclosureLength = attributeDict["length"].flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil }
        } else if name == "image", let href = attributeDict["href"], let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if currentItem != nil { currentItem?.artworkURL = url } else { channelArtworkURL = url }
        } else if name == "transcript", currentItem != nil {
            appendTranscriptSource(attributeDict)
        }
        if capturesText(name) || (name == "link" && currentItem != nil && (namespaceURI ?? "").isEmpty) {
            textElement = name
            text = ""
            linkOverflowed = false
        }
    }

    /// Records one `<podcast:transcript>` tag.
    ///
    /// A malformed or unsupported entry is skipped rather than failing the
    /// feed. A transcript is an optional extra: refusing the whole feed because
    /// one publisher wrote a bad transcript URL would cost the episodes too.
    /// The cap is the domain's, applied here so a feed cannot make the episode
    /// initialiser throw from the parse path.
    private func appendTranscriptSource(_ attributes: [String: String]) {
        guard var item = currentItem, item.transcriptSources.count < PodcastEpisode.maximumTranscriptSources else { return }
        guard let href = attributes["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: href), PodcastFeedClient.isHTTPS(url),
              let type = attributes["type"]?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else { return }
        let language = attributes["language"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = try? PodcastTranscriptSource(
            url: url, mediaType: type,
            languageCode: (language?.isEmpty ?? true) ? nil : language,
            isCaptions: attributes["rel"]?.lowercased() == "captions"
        ) else { return }
        guard !item.transcriptSources.contains(where: { $0.url == source.url }) else { return }
        item.transcriptSources.append(source)
        currentItem = item
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string, to: parser)
    }

    /// Notes are almost always CDATA-wrapped HTML, which arrives here rather
    /// than as characters.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        append(string, to: parser)
    }

    private func append(_ string: String, to parser: XMLParser) {
        guard let textElement else { return }
        if Self.notesElements.contains(textElement) {
            // Over-long notes are truncated at the item, not fatal to the feed;
            // stop accumulating rather than abort.
            guard text.utf8.count < Self.maximumNotesBytes else { return }
            text.append(string)
            return
        }
        if textElement == "link" {
            // An address longer than the episode allows can never be kept once it is resolved, and it
            // is an optional extra: stop accumulating instead of failing the feed.
            guard !linkOverflowed else { return }
            guard text.utf8.count + string.utf8.count <= PodcastEpisode.maximumEpisodeLinkLength else {
                linkOverflowed = true; text = ""; return
            }
            text.append(string)
            return
        }
        guard text.utf8.count + string.utf8.count <= 4_096 else {
            parseFailure = .invalidMetadata("text field too long"); parser.abortParsing(); return
        }
        text.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if textElement == name {
            applyText(text, element: name)
            textElement = nil
            text = ""
        }
        if name == "item", let item = currentItem {
            completedItems.append(item)
            currentItem = nil
        }
    }

    private func capturesText(_ name: String) -> Bool {
        switch name {
        case "title", "guid", "pubdate", "published", "updated", "duration", "author", "creator", "managingeditor": true
        // Notes only matter on an item; a channel description is not captured
        // at all, so it cannot trip the per-field byte limit either.
        case _ where Self.notesElements.contains(name): currentItem != nil
        default: false
        }
    }

    private func applyText(_ value: String, element: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if currentItem != nil {
            switch element {
            case _ where Self.notesElements.contains(element): currentItem?.notesCandidates[element] = value
            case "link": currentItem?.link = value
            case "title": currentItem?.title = value
            case "guid": currentItem?.guid = value
            case "author", "creator": currentItem?.author = value
            case "pubdate", "published", "updated": currentItem?.publishedAt = parseDate(value)
            case "duration":
                guard let duration = parseDuration(value), duration.isFinite, duration > 0 else {
                    parseFailure = .invalidMetadata("episode duration")
                    return
                }
                currentItem?.duration = duration
            default: break
            }
        } else {
            switch element {
            case "title": channelTitle = value
            case "author", "creator", "managingeditor": channelAuthor = value
            default: break
            }
        }
    }
}

private let supportedAudioTypes: Set<String> = [
    "audio/aac", "audio/flac", "audio/m4a", "audio/mp3", "audio/mp4", "audio/mpeg",
    "audio/ogg", "audio/opus", "audio/wav", "audio/x-flac", "audio/x-m4a", "audio/x-wav",
]

private func declaresExternalEntity(_ data: Data) -> Bool {
    let document = decodeXMLDocument(data)
    let pattern = #"(?is)<!--.*?-->|<!\[CDATA\[.*?\]\]>|<!\s*(?:doctype|entity)\b"#
    let tokenPattern = #"(?is)^<!\s*(?:doctype|entity)\b"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(document.startIndex..<document.endIndex, in: document)
    return expression.matches(in: document, range: range).contains { match in
        guard let range = Range(match.range, in: document) else { return false }
        return document[range].range(of: tokenPattern, options: .regularExpression) != nil
    }
}

private func decodeXMLDocument(_ data: Data) -> String {
    let prefix = Array(data.prefix(4))
    if prefix.starts(with: [0x00, 0x00, 0xFE, 0xFF]) || prefix.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
        return String(data: data, encoding: .utf32) ?? ""
    }
    if prefix.starts(with: [0xFE, 0xFF]) || prefix.starts(with: [0xFF, 0xFE]) {
        return String(data: data, encoding: .utf16) ?? ""
    }
    if prefix.starts(with: [0x00, 0x00, 0x00, 0x3C]) {
        return String(data: data, encoding: .utf32BigEndian) ?? ""
    }
    if prefix.starts(with: [0x3C, 0x00, 0x00, 0x00]) {
        return String(data: data, encoding: .utf32LittleEndian) ?? ""
    }
    if prefix.starts(with: [0x00, 0x3C]) {
        return String(data: data, encoding: .utf16BigEndian) ?? ""
    }
    if prefix.count >= 2, prefix[0] == 0x3C, prefix[1] == 0x00 {
        return String(data: data, encoding: .utf16LittleEndian) ?? ""
    }
    return String(decoding: data, as: UTF8.self)
}

/// Show notes as readable text: block tags become line breaks, list items
/// become dashes, links keep their address after the text (the address is
/// often the only spelling of a sponsor or a guest's site that speech-to-text
/// will never produce), everything else is stripped, and entities decoded.
///
/// Hand-rolled rather than `NSAttributedString(html:)`: that route loads
/// WebKit, must run on the main thread, and is the wrong tool for a parser
/// that runs off it on every refresh. Plain text without tags is also a
/// safer thing to keep and hand to a language model than markup.
func plainText(fromHTML html: String) -> String {
    var text = html
    func replace(_ pattern: String, with template: String) {
        text = text.replacingOccurrences(
            of: pattern, with: template, options: [.regularExpression, .caseInsensitive]
        )
    }
    replace(#"<\s*(script|style)[^>]*>[\s\S]*?<\s*/\s*\1\s*>"#, with: "")
    replace(#"<!--[\s\S]*?-->"#, with: "")
    replace(#"<\s*a\b[^>]*\bhref\s*=\s*"([^"]*)"[^>]*>([\s\S]*?)<\s*/\s*a\s*>"#, with: "$2 ($1)")
    replace(#"<\s*a\b[^>]*\bhref\s*=\s*'([^']*)'[^>]*>([\s\S]*?)<\s*/\s*a\s*>"#, with: "$2 ($1)")
    replace(#"<\s*br\s*/?\s*>"#, with: "\n")
    // An item opens its own line; its close adds nothing, or every list
    // would be double-spaced.
    replace(#"<\s*li\b[^>]*>"#, with: "\n- ")
    replace(#"<\s*/\s*li\s*>"#, with: "")
    replace(#"<\s*/\s*(p|div|ul|ol|h[1-6]|tr|blockquote|pre|table)\s*>"#, with: "\n")
    replace(#"<\s*(p|div|h[1-6]|tr|blockquote|pre|table)\b[^>]*>"#, with: "\n")
    replace(#"<[^>]+>"#, with: "")
    text = decodingHTMLEntities(text)
    // "text (url)" where the text already is the address reads twice; keep one.
    replace(#"(\S+) \(\s*(https?://)?(www\.)?\1/?\s*\)"#, with: "$1")
    // ICU spells a code point `\x{...}`; Swift's `\u{...}` is not a regex
    // escape and an invalid pattern silently replaces nothing.
    let lines = text.components(separatedBy: "\n").map {
        $0.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
    var collapsed: [String] = []
    for line in lines where !(line.isEmpty && collapsed.last?.isEmpty != false) {
        // Markup indentation between items became a blank line; consecutive
        // items stay together.
        if line.hasPrefix("- "), collapsed.last == "", collapsed.dropLast().last?.hasPrefix("- ") == true {
            collapsed.removeLast()
        }
        collapsed.append(line)
    }
    return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func decodingHTMLEntities(_ text: String) -> String {
    let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "copy": "\u{00A9}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
    ]
    var result = ""
    var remainder = Substring(text)
    while let ampersand = remainder.firstIndex(of: "&") {
        result += remainder[..<ampersand]
        let afterAmpersand = remainder[remainder.index(after: ampersand)...]
        guard let semicolon = afterAmpersand.firstIndex(of: ";"),
              afterAmpersand.distance(from: afterAmpersand.startIndex, to: semicolon) <= 8 else {
            result.append("&")
            remainder = afterAmpersand
            continue
        }
        let name = String(afterAmpersand[..<semicolon])
        let decoded: String?
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else if name.hasPrefix("#") {
            decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else {
            decoded = named[name]
        }
        if let decoded {
            result += decoded
            remainder = afterAmpersand[afterAmpersand.index(after: semicolon)...]
        } else {
            result.append("&")
            remainder = afterAmpersand
        }
    }
    result += remainder
    return result
}

private func normalizedMediaType(_ value: String?) -> String? {
    value?.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

private func bounded(_ value: String?, maximum: Int) -> String? {
    guard let value else { return nil }
    let normalized = value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    return !normalized.isEmpty && normalized.utf8.count <= maximum ? normalized : nil
}

private func optionalText(_ value: String?, maximum: Int, field: String) throws -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    guard let bounded = bounded(value, maximum: maximum) else { throw PodcastFeedClientError.invalidMetadata(field) }
    return bounded
}

/// Artwork advertised over plain HTTP is upgraded to HTTPS, not dropped.
///
/// Cover art is decoration, and real feeds still advertise it over plain HTTP:
/// Mac Power Users did in the 2026-08-31 import survey, which is why its row
/// showed the placeholder microphone while every other feed had art. Refusing
/// the whole podcast over its logo would lose every episode to fix nothing, and
/// dropping the URL loses the art for a host that almost always serves the same
/// bytes over TLS -- files.relay.fm does. So the scheme is rewritten and
/// nothing else is: same host, same path, same query. Wilted still never loads
/// the insecure URL. If the host has no HTTPS listener the fetch fails and the
/// row falls back to the placeholder, exactly as it did before.
private func safeArtworkURL(_ value: URL?) -> URL? {
    guard let value, value.host != nil, value.user == nil, value.password == nil else { return nil }
    if PodcastFeedClient.isHTTPS(value) { return value }
    guard value.scheme?.lowercased() == "http",
          var components = URLComponents(url: value, resolvingAgainstBaseURL: false) else { return nil }
    components.scheme = "https"
    guard let upgraded = components.url, PodcastFeedClient.isHTTPS(upgraded) else { return nil }
    return upgraded
}

private func parseDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
}

private func parseDuration(_ value: String) -> Double? {
    let fields = value.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count > 1 else { return Double(value) }
    guard fields.count <= 3 else { return nil }
    let components = fields.compactMap { Double($0) }
    guard components.count == fields.count, components.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
    let duration = components.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    return duration.isFinite ? duration : nil
}
