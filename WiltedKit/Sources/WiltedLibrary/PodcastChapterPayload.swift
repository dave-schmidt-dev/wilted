import Foundation
import WiltedDomain

/// Chapter starts for one exact prepared podcast revision.
public struct LibraryPodcastChapters: Codable, Equatable, Sendable {
    public static let maximumChapters = 400
    public static let maximumTitleCharacters = 120
    public static let maximumEncodedBytes = 32 * 1_024

    public let entryID: ItemID
    public let revisionID: RevisionID
    /// Prepared-clock chapter starts. Equal times retain publisher order.
    public let chapters: [PodcastChapterMark]

    public init(entryID: ItemID, revisionID: RevisionID, chapters: [PodcastChapterMark]) throws {
        guard chapters.count <= Self.maximumChapters,
              chapters.allSatisfy({ $0.startSeconds.isFinite && $0.startSeconds >= 0 && !$0.title.isEmpty && $0.title.count <= Self.maximumTitleCharacters }),
              zip(chapters, chapters.dropFirst()).allSatisfy({ $0.1.startSeconds >= $0.0.startSeconds }) else {
            throw DomainError.invalidValue(field: "podcastChapters", reason: "chapter starts must be ordered, finite, non-negative and bounded")
        }
        self.entryID = entryID
        self.revisionID = revisionID
        self.chapters = chapters
        guard (try? Self.encoder.encode(self).count) ?? .max <= Self.maximumEncodedBytes else {
            throw DomainError.invalidValue(field: "podcastChapters", reason: "exceeds the chapter payload limit")
        }
    }

    /// Builds a bounded chapter set by keeping the longest usable prefix.
    /// Keeping a prefix preserves publisher order when several starts collapse
    /// onto one point after ad removal.
    public static func capped(
        entryID: ItemID,
        revisionID: RevisionID,
        chapters: [PodcastChapterMark]
    ) -> LibraryPodcastChapters? {
        let clean = chapters.prefix(maximumChapters).enumerated().compactMap { index, chapter -> PodcastChapterMark? in
            guard chapter.startSeconds.isFinite, chapter.startSeconds >= 0 else { return nil }
            let trimmed = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmed.isEmpty ? "Chapter \(index + 1)" : String(trimmed.prefix(maximumTitleCharacters))
            return PodcastChapterMark(title: title, startSeconds: chapter.startSeconds)
        }
        guard !clean.isEmpty else { return nil }
        let ordered = clean.enumerated().sorted { lhs, rhs in
            lhs.element.startSeconds == rhs.element.startSeconds
                ? lhs.offset < rhs.offset
                : lhs.element.startSeconds < rhs.element.startSeconds
        }.map(\.element)
        var low = 1
        var high = ordered.count
        var best: LibraryPodcastChapters?
        while low <= high {
            let middle = (low + high) / 2
            if let candidate = try? LibraryPodcastChapters(entryID: entryID, revisionID: revisionID,
                                                           chapters: Array(ordered.prefix(middle))) {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private enum CodingKeys: CodingKey { case entryID, revisionID, chapters }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(entryID: c.decode(ItemID.self, forKey: .entryID),
                      revisionID: c.decode(RevisionID.self, forKey: .revisionID),
                      chapters: c.decode([PodcastChapterMark].self, forKey: .chapters))
    }
}

/// Navigation rules that retain a selected chapter identity when several
/// source chapters map to the same prepared-clock instant.
public struct PodcastChapterNavigator: Equatable, Sendable {
    public static let restartThreshold: TimeInterval = 3
    public let chapters: [PodcastChapterMark]

    public init(chapters: [PodcastChapterMark]) { self.chapters = chapters }

    public func index(at position: TimeInterval, selectedIndex: Int? = nil) -> Int? {
        guard !chapters.isEmpty else { return nil }
        if let selectedIndex, chapters.indices.contains(selectedIndex) {
            let start = chapters[selectedIndex].startSeconds
            let nextDistinct = chapters.dropFirst(selectedIndex + 1).first { $0.startSeconds > start }?.startSeconds
            if position >= start, nextDistinct.map({ position < $0 }) ?? true { return selectedIndex }
        }
        guard let latestStartIndex = chapters.lastIndex(where: { $0.startSeconds <= position }) else { return 0 }
        let latestStart = chapters[latestStartIndex].startSeconds
        return chapters.firstIndex(where: { $0.startSeconds == latestStart }) ?? latestStartIndex
    }

    public func nextIndex(at position: TimeInterval, selectedIndex: Int? = nil) -> Int? {
        guard let index = index(at: position, selectedIndex: selectedIndex), index + 1 < chapters.count else { return nil }
        return index + 1
    }

    public func previousIndex(at position: TimeInterval, selectedIndex: Int? = nil) -> Int? {
        guard let index = index(at: position, selectedIndex: selectedIndex) else { return nil }
        if position - chapters[index].startSeconds > Self.restartThreshold { return index }
        return index > 0 ? index - 1 : nil
    }
}
