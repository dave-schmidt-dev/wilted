import Foundation

public struct NativeStaticExtractor: Sendable {
    public init() {}

    public func extract(
        _ request: ExtractionRequest,
        onStatus: @Sendable (ExtractionStatus) -> Void = { _ in }
    ) async throws -> ExtractionResult {
        try await checkpoint(.validatingURL, onStatus: onStatus)
        guard let scheme = request.sourceURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              request.sourceURL.host != nil,
              request.sourceURL.user == nil,
              request.sourceURL.password == nil else {
            throw ExtractionError.invalidURL
        }

        try await checkpoint(.decodingHTML, onStatus: onStatus)
        let html = try decode(request.html)

        try await checkpoint(.readingMetadata, onStatus: onStatus)
        let title = normalized(firstMatch(in: html, patterns: [
            #"(?is)<meta\b[^>]*(?:property|name)\s*=\s*[\"']og:title[\"'][^>]*content\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#,
            #"(?is)<title\b[^>]*>(.*?)</title\s*>"#,
            #"(?is)<h1\b[^>]*>(.*?)</h1\s*>"#,
        ]).map(stripTags))
        let metadata = ArticleMetadata(
            author: metaContent("author", in: html),
            description: metaContent("description", in: html),
            canonicalURL: canonicalURL(in: html)
        )

        try await checkpoint(.selectingContent, onStatus: onStatus)
        let fragment = firstMatch(in: html, patterns: [
            #"(?is)<main\b[^>]*>(.*?)</main\s*>"#,
            #"(?is)<article\b[^>]*>(.*?)</article\s*>"#,
            #"(?is)<body\b[^>]*>(.*?)</body\s*>"#,
        ]) ?? html
        let body = normalized(renderText(fragment))
        if isScriptOnlyShell(html: html, visibleBody: body) {
            return finish(.init(outcome: .controlledUnsupported, title: title, body: nil, metadata: metadata, reason: "javascript-required"), onStatus)
        }
        if isConsentWall(html: html, visibleBody: body) {
            return finish(.init(outcome: .controlledUnsupported, title: title, body: nil, metadata: metadata, reason: "consent-wall"), onStatus)
        }
        if isPaywallShell(html: html, visibleBody: body) {
            return finish(.init(outcome: .headlineOnly, title: title, body: nil, metadata: metadata, reason: "paywall"), onStatus)
        }
        guard let body, !body.isEmpty else {
            return finish(.init(outcome: .failed, title: title, body: nil, metadata: metadata, reason: "empty-content"), onStatus)
        }
        return finish(.init(outcome: .extracted, title: title, body: body, metadata: metadata), onStatus)
    }

    private func checkpoint(
        _ status: ExtractionStatus,
        onStatus: @Sendable (ExtractionStatus) -> Void
    ) async throws {
        try Task.checkCancellation()
        onStatus(status)
        await Task.yield()
        try Task.checkCancellation()
    }

    private func finish(_ result: ExtractionResult, _ onStatus: @Sendable (ExtractionStatus) -> Void) -> ExtractionResult {
        onStatus(.finished)
        return result
    }

    private func decode(_ data: Data) throws -> String {
        let prefix = String(decoding: data.prefix(1024), as: UTF8.self)
        if let charset = firstMatch(in: prefix, patterns: [#"(?is)<meta\b[^>]*charset\s*=\s*[\"']?([^\s\"'/>]+)"#])?.lowercased(),
           charset != "utf-8", charset != "utf8" {
            throw ExtractionError.unsupportedCharset(charset)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw ExtractionError.undecodableHTML }
        return html
    }

    private func metaContent(_ name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return normalized(firstMatch(in: html, patterns: [
            "(?is)<meta\\b[^>]*(?:name|property)\\s*=\\s*[\\\"']\(escaped)[\\\"'][^>]*content\\s*=\\s*[\\\"']([^\\\"']*)[\\\"'][^>]*>",
            "(?is)<meta\\b[^>]*content\\s*=\\s*[\\\"']([^\\\"']*)[\\\"'][^>]*(?:name|property)\\s*=\\s*[\\\"']\(escaped)[\\\"'][^>]*>",
        ]).map(decodeEntities))
    }

    private func canonicalURL(in html: String) -> String? {
        normalized(firstMatch(in: html, patterns: [
            #"(?is)<link\b[^>]*rel\s*=\s*[\"']canonical[\"'][^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#,
            #"(?is)<link\b[^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*rel\s*=\s*[\"']canonical[\"'][^>]*>"#,
        ]))
    }

    // These are intentionally bounded signals for the probe, not a claim of broad
    // publisher compatibility. Ambiguous pages remain ordinary extraction/failure.
    private func isScriptOnlyShell(html: String, visibleBody: String?) -> Bool {
        let hasEmptyAppRoot = html.range(
            of: #"(?is)<(?:div|main)\b[^>]*id\s*=\s*[\"'](?:app|root)[\"'][^>]*>\s*</(?:div|main)\s*>"#,
            options: .regularExpression
        ) != nil
        let hasScript = html.range(of: #"(?is)<script\b"#, options: .regularExpression) != nil
        return hasEmptyAppRoot && hasScript && (visibleBody?.isEmpty ?? true)
    }

    private func isConsentWall(html: String, visibleBody: String?) -> Bool {
        let text = (visibleBody ?? decodeEntities(stripTags(html))).lowercased()
        let hasPrivacyLanguage = text.contains("privacy settings") || text.contains("consent preferences")
        let hasChoiceControl = html.range(of: #"(?is)<button\b[^>]*>.*?(?:accept|manage choices).*?</button\s*>"#, options: .regularExpression) != nil
        let hasDialogStructure = html.range(of: #"(?is)(?:role\s*=\s*[\"']dialog[\"']|class\s*=\s*[\"'][^\"']*consent[^\"']*[\"'])"#, options: .regularExpression) != nil
        return hasPrivacyLanguage && hasChoiceControl && hasDialogStructure
    }

    private func isPaywallShell(html: String, visibleBody: String?) -> Bool {
        let text = visibleBody?.lowercased() ?? ""
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let hasSubscriptionLanguage = text.contains("subscribe to continue") || text.contains("become a member")
        let hasWallStructure = html.range(of: #"(?is)class\s*=\s*[\"'][^\"']*(?:paywall|subscription-wall)[^\"']*[\"']"#, options: .regularExpression) != nil
        return hasSubscriptionLanguage && hasWallStructure && words.count < 40
    }

    private func firstMatch(in value: String, patterns: [String]) -> String? {
        let range = NSRange(value.startIndex..., in: value)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: range),
                  match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: value) else { continue }
            return String(value[matchRange])
        }
        return nil
    }

    private func renderText(_ html: String) -> String {
        var value = html
        value = value.replacingOccurrences(of: #"(?is)<(?:script|style|nav|footer|aside)\b[^>]*>.*?</(?:script|style|nav|footer|aside)\s*>"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)<br\s*/?>|</?(?:p|div|section|h[1-6]|li|pre|code|blockquote)\b[^>]*>"#, with: "\n", options: .regularExpression)
        return decodeEntities(stripTags(value))
    }

    private func stripTags(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?s)<[^>]*>"#, with: " ", options: .regularExpression)
    }

    private func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: #"[\t\r ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
