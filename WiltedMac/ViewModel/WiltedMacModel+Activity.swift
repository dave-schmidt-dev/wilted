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

        let counts = preparationCounts
        let preparing = counts.preparing
        let preparationWaiting = counts.waiting
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

    /// Preparations running now and waiting for the one slot, each item counted once.
    ///
    /// A queued episode already shows a "preparing" state, and an off-peak one waits for the
    /// window, so both count as waiting. Prepare Again keeps the episode's prepared state and
    /// tracks its run in `prepareAgainRows`, so its active phases count as preparing.
    var preparationCounts: (preparing: Int, waiting: Int) {
        var waitingIDs = Set(preparationQueue.entries.map(\.id))
        for (id, row) in prepareAgainRows where row.phase == .waiting { waitingIDs.insert(id) }
        for episode in episodes where isDeferredForOffPeak(episode.id) { waitingIDs.insert(episode.id) }

        var preparingIDs = Set(episodes.filter { $0.preparationState.isRunning }.map(\.id))
        for (id, row) in prepareAgainRows where row.isRunning && row.phase != .waiting { preparingIDs.insert(id) }
        preparingIDs.subtract(waitingIDs)

        // One article is prepared at a time. A cancelled or failed one is no longer running.
        let articlePhase = larderArticlePreparation?.phase
        let articleRunning = articlePreparationIsPending
            || (articlePhase != nil && articlePhase != .cancelled && articlePhase != .failed)
        return (preparingIDs.count + (articleRunning ? 1 : 0), waitingIDs.count)
    }
}
