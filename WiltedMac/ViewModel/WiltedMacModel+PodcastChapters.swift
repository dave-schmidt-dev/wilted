import WiltedDomain
import WiltedLibrary

extension WiltedMacModel {
    // MARK: - Audiobook and podcast chapters

    /// The audiobook details of what the player holds, when it holds a book volume with chapter marks.
    private var currentChapterDetails: WiltedMacAudiobookDetails? {
        guard isPodcastPlayback, let details = currentEpisode?.audiobook, !details.chapters.isEmpty else { return nil }
        return details
    }

    private var currentPodcastChapterNavigator: PodcastChapterNavigator? {
        guard isPodcastPlayback, let episode = currentEpisode, episode.audiobook == nil,
              !episode.podcastChapters.isEmpty else { return nil }
        return PodcastChapterNavigator(chapters: episode.podcastChapters.map {
            PodcastChapterMark(title: $0.title, startSeconds: $0.startSeconds)
        })
    }

    private var currentPodcastChapterIndex: Int? {
        currentPodcastChapterNavigator?.index(
            at: playbackPositionSeconds, selectedIndex: currentEpisode?.selectedPodcastChapterIndex)
    }

    var canShowPodcastChapterList: Bool { currentPodcastChapterNavigator != nil }

    /// The title of the chapter under the playhead, whether it belongs to a book or podcast.
    var currentChapterTitle: String? {
        if let details = currentChapterDetails,
           let index = details.chapterIndex(at: playbackPositionSeconds) { return details.chapters[index].title }
        guard let index = currentPodcastChapterIndex, let episode = currentEpisode else { return nil }
        return episode.podcastChapters[index].title
    }

    /// `Chapter 3 of 12`, for the player's chapter line.
    var currentChapterPositionLabel: String? {
        if let details = currentChapterDetails,
           let index = details.chapterIndex(at: playbackPositionSeconds) {
            return "Chapter \(index + 1) of \(details.chapters.count)"
        }
        guard let index = currentPodcastChapterIndex, let episode = currentEpisode else { return nil }
        return "Chapter \(index + 1) of \(episode.podcastChapters.count)"
    }

    var canSelectPreviousChapter: Bool {
        if let navigator = currentPodcastChapterNavigator {
            return navigator.previousIndex(at: playbackPositionSeconds,
                                          selectedIndex: currentEpisode?.selectedPodcastChapterIndex) != nil
        }
        return currentChapterDetails?.previousChapterStart(from: playbackPositionSeconds) != nil
    }

    var canSelectNextChapter: Bool {
        if let navigator = currentPodcastChapterNavigator {
            return navigator.nextIndex(at: playbackPositionSeconds,
                                       selectedIndex: currentEpisode?.selectedPodcastChapterIndex) != nil
        }
        return currentChapterDetails?.nextChapterStart(from: playbackPositionSeconds) != nil
    }

    /// Restarts the current chapter, or goes to the one before it from its first seconds.
    func selectPreviousChapter() {
        if let navigator = currentPodcastChapterNavigator,
           let index = navigator.previousIndex(at: playbackPositionSeconds,
                                               selectedIndex: currentEpisode?.selectedPodcastChapterIndex) {
            selectPodcastChapter(at: index)
            return
        }
        guard let start = currentChapterDetails?.previousChapterStart(from: playbackPositionSeconds) else { return }
        scrub(to: start)
    }

    func selectNextChapter() {
        if let navigator = currentPodcastChapterNavigator,
           let index = navigator.nextIndex(at: playbackPositionSeconds,
                                           selectedIndex: currentEpisode?.selectedPodcastChapterIndex) {
            selectPodcastChapter(at: index)
            return
        }
        guard let start = currentChapterDetails?.nextChapterStart(from: playbackPositionSeconds) else { return }
        scrub(to: start)
    }

    func selectPodcastChapter(at index: Int) {
        guard let episode = currentEpisode, episode.audiobook == nil,
              episode.podcastChapters.indices.contains(index) else { return }
        let chapter = episode.podcastChapters[index]
        scrub(to: chapter.startSeconds)
        guard let row = episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        episodes[row].selectedPodcastChapterIndex = index
    }
}
