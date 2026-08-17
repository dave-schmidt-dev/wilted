import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ArticleExtractionStage: String, Sendable {
    case validatingURL, fetching, decodingHTML, readingMetadata, selectingContent, finished
}

public enum ArticleExtractionError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case responseTooLarge
    case unsupportedCharset(String)
    case emptyContent
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a complete HTTPS article URL."
        case .invalidResponse: "The article server returned an invalid response."
        case .responseTooLarge: "The article is larger than Wilted's safe extraction limit."
        case .unsupportedCharset(let charset): "The page uses an unsupported character set: \(charset)."
        case .emptyContent: "Wilted could not find readable article text."
        case .unsupported(let reason): "This page is not supported: \(reason)."
        }
    }
}

public struct ExtractedArticle: Equatable, Sendable {
    public let sourceURL: URL
    public let canonicalURL: URL
    public let title: String
    public let source: String
    public let author: String?
    public let body: String

    public init(sourceURL: URL, canonicalURL: URL, title: String, source: String, author: String?, body: String) {
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL
        self.title = title
        self.source = source
        self.author = author
        self.body = body
    }
}

public protocol ArticleLoading: Sendable {
    func load(_ url: URL, maximumBytes: Int, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> Data
}

public struct URLSessionArticleLoader: ArticleLoading, Sendable {
    public init() {}

    public func load(_ url: URL, maximumBytes: Int, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("Wilted/0.1 article reader", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ArticleExtractionError.invalidResponse
        }
        if response.expectedContentLength > Int64(maximumBytes) { throw ArticleExtractionError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? min(Int(response.expectedContentLength), maximumBytes) : 0)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw ArticleExtractionError.responseTooLarge }
            data.append(byte)
            if response.expectedContentLength > 0 {
                onProgress(min(1, Double(data.count) / Double(response.expectedContentLength)))
            } else if data.count.isMultiple(of: 64 * 1_024) {
                onProgress(nil)
            }
        }
        return data
    }
}

public struct NativeArticleExtractor: Sendable {
    public static let maximumHTMLBytes = 5 * 1_024 * 1_024
    private let loader: any ArticleLoading

    public init(loader: any ArticleLoading = URLSessionArticleLoader()) { self.loader = loader }

    public func extract(
        _ url: URL,
        onStatus: @escaping @Sendable (ArticleExtractionStage, Double?) -> Void = { _, _ in }
    ) async throws -> ExtractedArticle {
        onStatus(.validatingURL, nil)
        try Task.checkCancellation()
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw ArticleExtractionError.invalidURL
        }
        onStatus(.fetching, nil)
        let html = try await loader.load(url, maximumBytes: Self.maximumHTMLBytes) { onStatus(.fetching, $0) }
        return try await extract(url, html: html, onStatus: onStatus)
    }

    public func extract(
        _ url: URL,
        html: Data,
        onStatus: @escaping @Sendable (ArticleExtractionStage, Double?) -> Void = { _, _ in }
    ) async throws -> ExtractedArticle {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw ArticleExtractionError.invalidURL
        }
        guard html.count <= Self.maximumHTMLBytes else { throw ArticleExtractionError.responseTooLarge }
        try await checkpoint(.decodingHTML, onStatus)
        let prefix = String(decoding: html.prefix(1_024), as: UTF8.self)
        if let charset = capture(#"(?is)<meta\b[^>]*charset\s*=\s*[\"']?([^\s\"'/>]+)"#, in: prefix)?.lowercased(),
           charset != "utf-8", charset != "utf8" {
            throw ArticleExtractionError.unsupportedCharset(charset)
        }
        guard let document = String(data: html, encoding: .utf8) else { throw ArticleExtractionError.unsupportedCharset("unknown") }
        try await checkpoint(.readingMetadata, onStatus)
        let title = normalize(capture(#"(?is)<meta\b[^>]*(?:property|name)\s*=\s*[\"']og:title[\"'][^>]*content\s*=\s*[\"']([^\"']+)[\"']"#, in: document))
            ?? normalize(stripTags(capture(#"(?is)<title\b[^>]*>(.*?)</title\s*>"#, in: document) ?? ""))
            ?? normalize(stripTags(capture(#"(?is)<h1\b[^>]*>(.*?)</h1\s*>"#, in: document) ?? ""))
        try await checkpoint(.selectingContent, onStatus)
        let fragment = capture(#"(?is)<main\b[^>]*>(.*?)</main\s*>"#, in: document)
            ?? capture(#"(?is)<article\b[^>]*>(.*?)</article\s*>"#, in: document)
            ?? capture(#"(?is)<body\b[^>]*>(.*?)</body\s*>"#, in: document)
            ?? document
        let body = normalize(renderText(fragment))
        let lower = (body ?? "").lowercased()
        let fullText = normalize(decodeEntities(stripTags(document)))?.lowercased() ?? ""
        if document.range(of: #"(?is)<(?:div|main)\b[^>]*id\s*=\s*[\"'](?:app|root)[\"'][^>]*>\s*</(?:div|main)\s*>"#, options: .regularExpression) != nil,
           document.range(of: #"(?is)<script\b"#, options: .regularExpression) != nil,
           body == nil { throw ArticleExtractionError.unsupported("JavaScript required") }
        if fullText.contains("privacy settings") && fullText.contains("manage choices") {
            throw ArticleExtractionError.unsupported("consent wall")
        }
        if lower.contains("subscribe to continue") || lower.contains("become a member") {
            throw ArticleExtractionError.unsupported("paywall")
        }
        guard let title, let body else { throw ArticleExtractionError.emptyContent }
        let canonicalString = capture(#"(?is)<link\b[^>]*rel\s*=\s*[\"']canonical[\"'][^>]*href\s*=\s*[\"']([^\"']+)[\"']"#, in: document)
        let canonical = canonicalString.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL } ?? url
        guard canonical.scheme?.lowercased() == "https", canonical.host != nil else { throw ArticleExtractionError.invalidURL }
        let author = normalize(capture(#"(?is)<meta\b[^>]*(?:name|property)\s*=\s*[\"']author[\"'][^>]*content\s*=\s*[\"']([^\"']*)[\"']"#, in: document))
        onStatus(.finished, 1)
        return ExtractedArticle(sourceURL: url, canonicalURL: canonical, title: decodeEntities(title), source: canonical.host ?? url.host!, author: author.map(decodeEntities), body: body)
    }

    private func checkpoint(_ stage: ArticleExtractionStage, _ status: @Sendable (ArticleExtractionStage, Double?) -> Void) async throws {
        try Task.checkCancellation(); status(stage, nil); await Task.yield(); try Task.checkCancellation()
    }
}

private func capture(_ pattern: String, in value: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
          match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: value) else { return nil }
    return String(value[range])
}

private func renderText(_ html: String) -> String {
    var value = html.replacingOccurrences(of: #"(?is)<(?:script|style|nav|footer|aside)\b[^>]*>.*?</(?:script|style|nav|footer|aside)\s*>"#, with: " ", options: .regularExpression)
    value = value.replacingOccurrences(of: #"(?i)<br\s*/?>|</?(?:p|div|section|h[1-6]|li|pre|code|blockquote)\b[^>]*>"#, with: "\n", options: .regularExpression)
    return decodeEntities(stripTags(value))
}

private func stripTags(_ value: String) -> String { value.replacingOccurrences(of: #"(?s)<[^>]*>"#, with: " ", options: .regularExpression) }

private func decodeEntities(_ value: String) -> String {
    value.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
}

private func normalize(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.replacingOccurrences(of: #"[\t\r ]+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
}
