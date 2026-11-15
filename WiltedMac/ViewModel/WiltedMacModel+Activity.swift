import Foundation
import Observation

#if canImport(WiltedProducer)
import WiltedProducer
#endif

extension WiltedMacModel {
    /// Builds the summary rows for the Mac Activity presentation.
    var activitySummary: WiltedMacActivitySummary {
        let syncStatus = librarySyncStatus
        let headline = syncStatus.headline
        let tone = syncStatus.tone
        let deviceChangesRead = WiltedMacLibrarySyncStatus.timeLabel(librarySyncActivity.lastCheckedAt)
        let media = librarySyncActivity.media

        let uploadingTitle: String? = {
            guard let uploadingID = media?.preupload?.uploadingID else { return nil }
            let allItems = episodes.map(WiltedMacLibraryItem.init(episode:)) + articles.map(WiltedMacLibraryItem.article)
            return allItems.first(where: { $0.id == uploadingID })?.title
        }()

        let requestLine = librarySyncDiagnostics
        let directDownloadsOn = isDirectDownloadsEnabled

        let runningEpisodesCount = episodes.filter { $0.preparationState.isRunning }.count
        // One article is prepared at a time. A cancelled or failed one is no longer running.
        let articlePhase = larderArticlePreparation?.phase
        let articleRunning = articlePreparationIsPending
            || (articlePhase != nil && articlePhase != .cancelled && articlePhase != .failed)
        let preparing = runningEpisodesCount + (articleRunning ? 1 : 0)

        let preparationWaiting = preparationQueue.entries.count
        let automationStatusText = automationStatus.settingsStatusText

        let input = WiltedMacActivitySummary.Input(
            headline: headline,
            tone: tone,
            deviceChangesRead: deviceChangesRead,
            media: media,
            uploadingTitle: uploadingTitle,
            requestLine: requestLine,
            directDownloadsOn: directDownloadsOn,
            preparing: preparing,
            preparationWaiting: preparationWaiting,
            automationStatus: automationStatusText
        )

        return WiltedMacActivitySummary.make(input) { date in
            WiltedMacLibrarySyncStatus.timeLabel(date)
        }
    }
}
