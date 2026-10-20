import Foundation

/// A description of an error that is safe to persist and to log as public text.
///
/// `String(describing:)` of a URL error carries the failing URL with its query string, and a
/// podcast enclosure URL can hold a per-listener token. URL errors become `domain/code` plus the
/// failing URL's host; any other error keeps its description with every embedded URL cut to
/// `scheme://host`, so a nested URL error or a payload string cannot carry a path or query.
public enum LogSafeError {
    public static func describe(_ error: Error) -> String {
        let nserror = error as NSError
        guard nserror.domain == NSURLErrorDomain else {
            return scrubbingURLs(String(describing: error))
        }
        var description = "NSURLErrorDomain/\(nserror.code)"
        let host = (nserror.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host
            ?? (nserror.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            .flatMap { URLComponents(string: $0)?.host }
        if let host {
            description += " host=\(host)"
        }
        return description
    }

    /// `text` with every `scheme://...` run reduced to `scheme://host`.
    public static func scrubbingURLs(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(
            pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>;,})]*"#
        ) else { return text }
        let original = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: original.length))
        var scrubbed = text
        for match in matches.reversed() {
            let url = original.substring(with: match.range)
            let scheme = url.prefix { $0 != ":" }
            let host = URLComponents(string: url)?.host ?? ""
            guard let range = Range(match.range, in: scrubbed) else { continue }
            scrubbed.replaceSubrange(range, with: "\(scheme)://\(host)")
        }
        return scrubbed
    }
}
