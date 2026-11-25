import Foundation
import WiltedDomain

/// Maps chapter points onto prepared audio. Ad and shortened-silence gaps
/// snap forward to the next surviving sound; markers after the final sound
/// are omitted instead of becoming a misleading end-of-file chapter.
public enum PodcastChapterMapping {
    public static func map(
        _ chapters: [PodcastChapterMark],
        through kept: [PodcastKeepInterval]
    ) -> [PodcastChapterMark] {
        guard !kept.isEmpty else { return [] }
        return chapters.compactMap { chapter in
            guard chapter.startSeconds.isFinite, chapter.startSeconds >= 0,
                  let mapped = mapPoint(chapter.startSeconds, through: kept) else { return nil }
            return PodcastChapterMark(title: chapter.title, startSeconds: mapped)
        }
    }

    private static func mapPoint(
        _ sourceSeconds: Double,
        through kept: [PodcastKeepInterval]
    ) -> Double? {
        if let interval = kept.first(where: { sourceSeconds >= $0.startSeconds && sourceSeconds < $0.endSeconds }) {
            // Kept intervals split around silence removals; this branch also
            // preserves the exact source-relative point inside audible spans.
            return interval.outputStartSeconds + sourceSeconds - interval.startSeconds
        }
        guard let last = kept.last, sourceSeconds < last.endSeconds else { return nil }
        // Every gap between kept intervals is removed material. This covers
        // both ads and shortened pauses without relying on their labels.
        return kept.first(where: { $0.startSeconds >= sourceSeconds })?.outputStartSeconds
    }
}
