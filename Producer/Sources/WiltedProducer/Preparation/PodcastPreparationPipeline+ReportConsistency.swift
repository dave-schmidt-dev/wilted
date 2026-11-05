import Foundation
import OSLog
import WiltedDomain

extension PodcastPreparationPipeline {
    enum ReportConsistencyRejection: String {
        case outcomeShape
        case keepMap
    }

    private static let reportConsistencyLogger = Logger(
        subsystem: "com.zerodelta.wilted", category: "PreparationWorkerResponse"
    )

    static func logReportConsistencyRejection(
        _ reason: ReportConsistencyRejection,
        removedCount: Int,
        keptCount: Int,
        silenceCount: Int
    ) {
        reportConsistencyLogger.error(
            "report_rejected reason=\(reason.rawValue, privacy: .public) removed=\(removedCount, privacy: .public) kept=\(keptCount, privacy: .public) silence=\(silenceCount, privacy: .public)"
        )
    }

    static func isKnownHeldReason(_ reason: String) -> Bool {
        ["programme-boundary", "credits-boundary-unresolved", "programme-boundary-conflict",
         "boundary-review-unresolved", "sponsor-prefix-programme-found", "total-share-ceiling",
         "pod-continuation-bracket", "house-promotion-disabled"].contains(reason)
    }

    /// Validate each original-time gap independently. This prevents a pause
    /// and an advertisement from joining across even a very short kept span.
    static func timelineMatchesKeepMap(
        removed: [PreparationStatus.PreparationTimeline.RemovedInterval],
        kept: [PreparationStatus.PreparationTimeline.KeptInterval],
        silence: [Range<Double>] = []
    ) -> Bool {
        guard !removed.isEmpty || !kept.isEmpty else { return true }
        typealias Piece = (start: Double, end: Double, pause: Bool)
        let tolerance = 0.001
        let orderedKept = kept.sorted { $0.originalStartSeconds < $1.originalStartSeconds }
        let adPieces: [Piece] = removed.map {
            (start: $0.originalStartSeconds, end: $0.originalEndSeconds, pause: false)
        }
        let pausePieces: [Piece] = silence.map {
            (start: $0.lowerBound, end: $0.upperBound, pause: true)
        }
        let pieces: [Piece] = (adPieces + pausePieces)
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        let gaps = makeGaps(from: orderedKept, through: pieces.map { $0.end }.max() ?? 0)

        var grouped = Array(repeating: [Piece](), count: gaps.count)
        for piece in pieces {
            guard let index = gaps.firstIndex(where: {
                piece.start >= $0.start - tolerance && piece.end <= $0.end + tolerance
                    && min(piece.end, $0.end) > max(piece.start, $0.start)
            }) else { return false }
            grouped[index].append(piece)
        }

        for (gap, gapPieces) in zip(gaps, grouped) {
            guard !gapPieces.isEmpty else { return false }
            var merged: [Piece] = []
            for piece in gapPieces {
                if let last = merged.last {
                    if piece.start < last.end - tolerance { return false }
                    if abs(piece.start - last.end) <= tolerance {
                        guard last.pause || piece.pause else { return false }
                        merged[merged.count - 1].end = max(last.end, piece.end)
                        merged[merged.count - 1].pause = piece.pause
                        continue
                    }
                }
                merged.append(piece)
            }
            guard merged.count == 1,
                  abs(merged[0].start - gap.start) <= tolerance,
                  abs(merged[0].end - gap.end) <= tolerance else { return false }
        }
        return true
    }

    private static func makeGaps(
        from kept: [PreparationStatus.PreparationTimeline.KeptInterval],
        through end: Double
    ) -> [(start: Double, end: Double)] {
        var gaps: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for interval in kept {
            if interval.originalStartSeconds > cursor {
                gaps.append((cursor, interval.originalStartSeconds))
            }
            cursor = interval.originalEndSeconds
        }
        if end > cursor {
            gaps.append((cursor, end))
        }
        return gaps
    }
}
