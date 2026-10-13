import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

extension WiltedMacModel {
    /// Downloaded rows genuinely preparing. A row waiting for the off-peak
    /// window carries a queued `.preparing` stage but is not running, and
    /// `larderPreparableEpisodes` already offers it, so it is excluded here.
    var larderPreparationsInFlight: [WiltedMacEpisode] {
        larderUnfilteredEpisodes(in: .downloaded).filter {
            $0.preparationState.isRunning && !isDeferredForOffPeak($0.id)
        }
    }

    /// The Larder's Available bulk action: the row's Download applied to the
    /// whole group, so acting on a group is one click rather than N.
    func downloadAllAvailableLarderEpisodes() {
        for episode in larderDownloadableEpisodes {
            downloadEpisode(episode)
        }
    }

    /// The Larder's Downloaded bulk action: the row's own step applied to the
    /// group. Preparing stays in Downloaded with progress on each row.
    func prepareAllDownloadedLarderEpisodes() {
        for episode in larderPreparableEpisodes {
            if isDeferredForOffPeak(episode.id) {
                _ = prepareDeferredEpisodeNow(episode)
            } else {
                prepareEpisode(episode)
            }
        }
    }
}

#if canImport(WiltedProducer)
extension WiltedMacModel {
    /// Acts on a feed's kept episodes after its saved policy changed from
    /// `previous` to `next`, the way the global Settings switches act on the
    /// whole Larder. Only a resolved Auto download or Auto prepare that went
    /// from off to on starts anything; switching between two "on" choices, or
    /// switching either off, issues nothing and cancels nothing.
    func startKeptEpisodeWork(
        feedID: String, from previous: FeedAutomationPolicy, to next: FeedAutomationPolicy, at date: Date = Date()
    ) {
        guard !isClosingTemporaryState else { return }
        let defaults = automationSettings.feedAutomationDefaults
        let before = previous.resolved(using: defaults)
        let after = next.resolved(using: defaults)
        if after.autoDownload, !before.autoDownload { downloadKeptEpisodes(inFeed: feedID) }
        if after.autoPrepare, !before.autoPrepare { prepareKeptDownloadedEpisodes(inFeed: feedID, at: date) }
    }

    /// One feed's share of the Available bulk action: each kept episode not
    /// yet downloaded or downloading gets the row's own Download.
    func downloadKeptEpisodes(inFeed feedID: String) {
        for episode in larderDownloadableEpisodes where episode.feedID == feedID {
            downloadEpisode(episode)
        }
    }

    /// One feed's downloaded, unprepared Larder rows, admitted as a download
    /// landing now would be: the prepare-everything override prepares at
    /// once, otherwise the processing policy decides, so an off-peak policy
    /// defers. A row already waiting for its off-peak window keeps its place.
    func prepareKeptDownloadedEpisodes(inFeed feedID: String, at date: Date = Date()) {
        for episode in larderPreparableEpisodes where episode.feedID == feedID && !isDeferredForOffPeak(episode.id) {
            if automationSettings.prepareEverythingDownloaded {
                prepareEpisode(episode)
            } else {
                admitAutomaticPreparation(for: episode, at: date)
            }
        }
    }
}
#endif
