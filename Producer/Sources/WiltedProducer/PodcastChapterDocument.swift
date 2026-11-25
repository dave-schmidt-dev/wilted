import CoreFoundation
import Foundation
import WiltedDomain

/// Loads the publisher's bounded JSON chapters document over validated HTTPS.
public protocol PodcastChapterDocumentLoading: Sendable {
    func load(_ url: URL, maximumBytes: Int) async throws -> Data
}

public struct PublicHTTPSPodcastChapterLoader: PodcastChapterDocumentLoading, Sendable {
    private let transport: PublicHTTPSArticleTransport

    public init() { transport = PublicHTTPSArticleTransport() }

    init(resolver: any ArticleAddressResolving, transferClient: any PinnedArticleTransferring) {
        transport = PublicHTTPSArticleTransport(resolver: resolver, transferClient: transferClient)
    }

    public func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        try await transport.loadPodcastChapterDocument(url, maximumBytes: maximumBytes)
    }
}

/// Strict Podcasting 2.0 JSON chapters reader. Invalid or over-limit documents
/// are refused as a whole so callers can fall back to embedded ID3 chapters.
public enum PodcastChapterDocument {
    public static let maximumDocumentBytes = 256 * 1_024
    public static let maximumRawChapters = 400
    public static let maximumTitleBytes = 512
    public static let maximumTitleCharacters = 120

    public static func parse(_ data: Data) -> [PodcastChapterMark]? {
        guard !data.isEmpty, data.count <= maximumDocumentBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? String,
              version.range(of: #"^1(?:\.[0-9]+){0,2}$"#, options: .regularExpression) != nil,
              let objects = root["chapters"] as? [[String: Any]],
              !objects.isEmpty, objects.count <= maximumRawChapters else { return nil }

        var result: [PodcastChapterMark] = []
        var previousStart = -Double.infinity
        for (index, object) in objects.enumerated() {
            guard let number = object["startTime"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let start = number.doubleValue
            guard start.isFinite, start >= 0, start >= previousStart else { return nil }
            previousStart = start
            if let rawTOC = object["toc"] {
                guard let toc = rawTOC as? NSNumber, CFGetTypeID(toc) == CFBooleanGetTypeID() else { return nil }
                if !toc.boolValue { continue }
            }
            if let rawTitle = object["title"] {
                guard let title = rawTitle as? String, title.utf8.count <= maximumTitleBytes else { return nil }
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(PodcastChapterMark(
                    title: trimmed.isEmpty ? "Chapter \(index + 1)" : String(trimmed.prefix(maximumTitleCharacters)),
                    startSeconds: start
                ))
            } else {
                result.append(PodcastChapterMark(title: "Chapter \(index + 1)", startSeconds: start))
            }
        }
        return result.isEmpty ? nil : result
    }
}
