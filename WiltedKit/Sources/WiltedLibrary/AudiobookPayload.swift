import Foundation

/// One chapter of an audiobook volume.
public struct AudiobookChapter: Codable, Sendable, Equatable {
    public let title: String
    public let startSeconds: Double

    public init(title: String, startSeconds: Double) {
        self.title = title
        self.startSeconds = startSeconds
    }
}

/// Kind-specific payload of an `audiobook` entry.
///
/// Use `build` to get a payload that is guaranteed to fit `LibraryEntry`: it caps
/// chapters, truncates titles and merges adjacent chapters when needed.
public struct AudiobookPayload: Codable, Sendable, Equatable {
    public enum SourceFormat: String, Codable, Sendable, Equatable {
        case audio
        case epub
        case pdf
    }

    public static let maxChapters = 400
    public static let maxTitleCharacters = 120
    /// Encoded-size budget, below `LibraryEntry.payloadLimitBytes`.
    public static let maxEncodedBytes = 48 * 1024

    public let title: String
    public let author: String?
    public let durationSeconds: Double
    public let chapters: [AudiobookChapter]
    public let sourceFormat: SourceFormat
    public let volumeIndex: Int
    public let volumeCount: Int

    public init(
        title: String,
        author: String? = nil,
        durationSeconds: Double,
        chapters: [AudiobookChapter] = [],
        sourceFormat: SourceFormat,
        volumeIndex: Int = 0,
        volumeCount: Int = 1
    ) {
        self.title = title
        self.author = author
        self.durationSeconds = durationSeconds
        self.chapters = chapters
        self.sourceFormat = sourceFormat
        self.volumeIndex = volumeIndex
        self.volumeCount = volumeCount
    }

    /// Builds a payload within the chapter, title and byte caps.
    ///
    /// More than `maxChapters` chapters are merged in runs of adjacent chapters (each
    /// run keeps its first chapter's title and start). If multi-byte titles still push
    /// the encoding past `maxEncodedBytes`, the cap halves until it fits.
    public static func build(
        title: String,
        author: String? = nil,
        durationSeconds: Double,
        chapters: [AudiobookChapter],
        sourceFormat: SourceFormat,
        volumeIndex: Int = 0,
        volumeCount: Int = 1
    ) -> AudiobookPayload {
        let clean = chapters.map {
            AudiobookChapter(
                title: truncated($0.title),
                startSeconds: $0.startSeconds.isFinite ? max(0, $0.startSeconds) : 0
            )
        }
        var cap = maxChapters
        while true {
            let payload = AudiobookPayload(
                title: truncated(title),
                author: author.map(truncated),
                durationSeconds: durationSeconds.isFinite ? max(0, durationSeconds) : 0,
                chapters: merged(clean, to: cap),
                sourceFormat: sourceFormat,
                volumeIndex: volumeIndex,
                volumeCount: volumeCount
            )
            if cap == 0 || ((try? payload.encoded().count) ?? .max) <= maxEncodedBytes { return payload }
            cap = min(cap, payload.chapters.count) / 2
        }
    }

    /// Sorted-key JSON, so equal payloads always encode to equal bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private static func truncated(_ text: String) -> String {
        String(text.prefix(maxTitleCharacters))
    }

    private static func merged(_ chapters: [AudiobookChapter], to cap: Int) -> [AudiobookChapter] {
        guard chapters.count > cap else { return chapters }
        guard cap > 0 else { return [] }
        let run = (chapters.count + cap - 1) / cap
        return stride(from: 0, to: chapters.count, by: run).map { chapters[$0] }
    }
}
