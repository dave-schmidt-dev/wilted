#if canImport(WiltedProducer)
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

extension WiltedMacModel {
    struct PodcastPlaybackOriginRecord: Codable {
        let libraryPath: String
        let episodeIDs: [String]
        let currentEpisodeID: String
        let origin: String
    }

    static func podcastPlaybackOriginPreferenceKey(for libraryURL: URL) -> String {
        let identity = libraryURL.standardizedFileURL.resolvingSymlinksInPath().path
        return podcastPlaybackOriginPreferenceKeyPrefix + Data(identity.utf8).base64EncodedString()
    }

    private var podcastPlaybackOriginLibraryPath: String {
        libraryURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func restoredPodcastPlaybackOrigin(for state: PodcastQueueState) -> Bool? {
        let key = Self.podcastPlaybackOriginPreferenceKey(for: libraryURL)
        guard let data = preferences.data(forKey: key),
              let record = try? JSONDecoder().decode(PodcastPlaybackOriginRecord.self, from: data),
              record.libraryPath == podcastPlaybackOriginLibraryPath,
              record.episodeIDs == state.episodeIDs.map(\.rawValue),
              record.currentEpisodeID == state.currentEpisodeID?.rawValue else {
            preferences.removeObject(forKey: key)
            return nil
        }
        switch record.origin {
        case "larder": return true
        case "generic": return false
        default:
            preferences.removeObject(forKey: key)
            return nil
        }
    }

    func persistPodcastPlaybackOrigin(for state: PodcastQueueState) {
        guard isPodcastPlayback, !isRestoringPodcastPlayback,
              let currentEpisodeID = currentPodcastEpisodeID,
              state.currentEpisodeID?.rawValue == currentEpisodeID else { return }
        persistPodcastPlaybackOrigin(currentEpisodeID: currentEpisodeID, episodeIDs: state.episodeIDs.map(\.rawValue))
    }

    private func persistPodcastPlaybackOrigin(currentEpisodeID: String, episodeIDs: [String]) {
        guard isPodcastPlayback, !isRestoringPodcastPlayback,
              episodeIDs.contains(currentEpisodeID) else { return }
        let record = PodcastPlaybackOriginRecord(
            libraryPath: podcastPlaybackOriginLibraryPath,
            episodeIDs: episodeIDs,
            currentEpisodeID: currentEpisodeID,
            origin: isLarderQueuePlayback ? "larder" : "generic"
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        preferences.set(data, forKey: Self.podcastPlaybackOriginPreferenceKey(for: libraryURL))
    }

    func clearPodcastPlaybackOrigin() {
        preferences.removeObject(forKey: Self.podcastPlaybackOriginPreferenceKey(for: libraryURL))
        isLarderQueuePlayback = false
    }

    func refreshPodcastQueueState() async {
        guard let store else { return }
        podcastQueueRefreshGeneration &+= 1
        let generation = podcastQueueRefreshGeneration
        let selectionToken = playbackCommands.selectionToken
        let loadedItemID = playback?.itemID
        let loadedRevisionID = playback?.revisionID
        guard let state = try? await store.podcastQueueState() else { return }
        // The test barrier holds a real actor-read state while a later Keep
        // commits and advances the generation, proving that old queue bytes
        // cannot publish after the decision.
        await podcastQueueReadBarrierForTesting?()
        guard generation == podcastQueueRefreshGeneration, !Task.isCancelled,
              selectionToken == playbackCommands.selectionToken,
              loadedItemID == playback?.itemID, loadedRevisionID == playback?.revisionID else { return }
        podcastQueueIDs = state.episodeIDs.map(\.rawValue)
        applyLarderSortIfNeeded()
        // A playlist entry plays outside the queue: the queue's current item is not what is loaded.
        if isPodcastPlayback, !playlistSessionIsCurrent {
            let loadedEpisodeID = playback?.itemID?.rawValue
            let activeEpisodeID = loadedEpisodeID.flatMap { id in
                episodes.contains(where: { $0.id == id }) ? id : nil
            }
            currentPodcastEpisodeID = activeEpisodeID ?? state.currentEpisodeID?.rawValue
            persistPodcastPlaybackOrigin(for: state)
        }
    }

    func applyPodcastPlaybackObservation(itemID: ItemID?, fault: PlaybackControllerError?) {
        let movedToAnotherEpisode = itemID != nil && currentPodcastEpisodeID != itemID?.rawValue
        currentPodcastEpisodeID = itemID?.rawValue
        if itemID != nil {
            selectedArticleID = nil
            isPodcastPlayback = true
            isNowPlaying = true
        }
        playbackError = switch fault {
        case .podcastMediaUnavailable?: "This episode's saved audio is unavailable."
        case .podcastMediaUnreadable?: "This episode's saved audio could not be opened."
        case .some: "Podcast playback could not continue."
        case nil: nil
        }
        // The fault names the episode that actually failed to load, which on
        // the successor-load-throws path is not `itemID` (that stays the one
        // that just finished). Repairing here, ahead of the next reload,
        // closes the window between a file vanishing and the next snapshot
        // noticing -- e.g. a second `canSelectNextEpisode` check right after
        // this fault fires.
        if case let .podcastMediaUnavailable(unavailableID) = fault,
           let index = episodes.firstIndex(where: { $0.id == unavailableID.rawValue }) {
            episodes[index].isReadyMediaAvailable = false
        }
        if movedToAnotherEpisode, playbackOperationStatus == nil, let itemID {
            persistPodcastPlaybackOrigin(currentEpisodeID: itemID.rawValue, episodeIDs: podcastQueueIDs)
        }
        playbackOperationStatus = nil
        refreshPlaybackReadout()
        // Continuous playback advances the queue without going through
        // `playEpisode`, so the previous episode's transcript would otherwise
        // stay on screen against the new audio.
        if movedToAnotherEpisode, let itemID {
            currentTranscript = .unavailable
            requestPlaybackPresentation(itemID: itemID, includesCuts: true,
                                        refreshQueue: true, reloadRows: true)
        }
    }
}
#endif
