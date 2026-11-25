import Foundation
import OSLog
import WiltedDomain

private let chapterPreparationLogger = Logger(subsystem: "com.zerodelta.wilted", category: "PodcastChapters")

extension PodcastPreparationPipeline {
    /// Valid linked JSON wins; failed or malformed optional metadata falls
    /// back to the downloaded enclosure's ID3 CHAP frames.
    func chapterMarks(for episode: PodcastEpisode, audioURL: URL) async throws -> [PodcastChapterMark] {
        if let source = episode.chapterSource {
            do {
                let data = try await chapterLoader.load(
                    source.url, maximumBytes: PodcastChapterDocument.maximumDocumentBytes)
                if let chapters = PodcastChapterDocument.parse(data) { return chapters }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                chapterPreparationLogger.error("Publisher chapters were unavailable; checking the downloaded audio")
            }
        }
        return ID3PodcastChapterReader.read(from: audioURL) ?? []
    }

    /// Chapter persistence is optional metadata. A sidecar failure leaves the
    /// newly prepared audio valid and playable, while the warning is visible
    /// in the preparation journal.
    func savePreparedChapterMarks(
        _ source: [PodcastChapterMark],
        for episodeID: ItemID,
        revisionID: RevisionID,
        keepIntervals: [PodcastKeepInterval]
    ) async {
        let prepared = PodcastChapterMapping.map(source, through: keepIntervals)
        do {
            try await store.savePreparedPodcastChapters(prepared, for: episodeID, revisionID: revisionID)
        } catch {
            chapterPreparationLogger.error("Prepared chapters could not be saved for episode \(episodeID.rawValue, privacy: .public)")
        }
    }
}
