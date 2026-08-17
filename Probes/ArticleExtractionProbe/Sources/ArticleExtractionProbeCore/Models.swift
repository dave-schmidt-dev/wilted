import Foundation

public enum ExtractionOutcome: String, Codable, CaseIterable, Sendable {
    case extracted
    case headlineOnly
    case controlledUnsupported
    case failed
}

public enum ExtractionStatus: String, Codable, Sendable {
    case validatingURL
    case decodingHTML
    case readingMetadata
    case selectingContent
    case finished
}

public struct ExtractionRequest: Sendable {
    public let sourceURL: URL
    public let html: Data

    public init(sourceURL: URL, html: Data) {
        self.sourceURL = sourceURL
        self.html = html
    }
}

public struct ArticleMetadata: Codable, Equatable, Sendable {
    public var author: String?
    public var description: String?
    public var canonicalURL: String?

    public init(author: String? = nil, description: String? = nil, canonicalURL: String? = nil) {
        self.author = author
        self.description = description
        self.canonicalURL = canonicalURL
    }
}

public struct ExtractionResult: Codable, Equatable, Sendable {
    public let outcome: ExtractionOutcome
    public let title: String?
    public let body: String?
    public let metadata: ArticleMetadata
    public let reason: String?

    public init(
        outcome: ExtractionOutcome,
        title: String?,
        body: String?,
        metadata: ArticleMetadata,
        reason: String? = nil
    ) {
        self.outcome = outcome
        self.title = title
        self.body = body
        self.metadata = metadata
        self.reason = reason
    }
}

public enum ExtractionError: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedCharset(String)
    case undecodableHTML

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Only absolute HTTP and HTTPS URLs are accepted."
        case .unsupportedCharset(let charset): "Unsupported declared charset: \(charset)"
        case .undecodableHTML: "HTML is not valid in its declared encoding."
        }
    }
}
