import Foundation
import WiltedDomain
import WiltedLibrary

@MainActor
extension LibraryPlayer {
    var currentPodcastChapterIndex: Int? {
        guard let item, !item.podcastChapters.isEmpty else { return nil }
        return PodcastChapterNavigator(chapters: item.podcastChapters).index(
            at: position, selectedIndex: selectedPodcastChapterIndex)
    }

    var currentPodcastChapterTitle: String? {
        currentPodcastChapterIndex.flatMap { item?.podcastChapters[$0].title }
    }

    var canSelectNextPodcastChapter: Bool {
        guard let item else { return false }
        return PodcastChapterNavigator(chapters: item.podcastChapters).nextIndex(
            at: position, selectedIndex: selectedPodcastChapterIndex) != nil
    }

    var canSelectPreviousPodcastChapter: Bool {
        guard let item else { return false }
        return PodcastChapterNavigator(chapters: item.podcastChapters).previousIndex(
            at: position, selectedIndex: selectedPodcastChapterIndex) != nil
    }

    func selectPodcastChapter(at index: Int) {
        guard let item, item.podcastChapters.indices.contains(index) else { return }
        seek(to: item.podcastChapters[index].startSeconds)
        setSelectedPodcastChapterIndex(index)
    }

    func selectNextPodcastChapter() {
        guard let item,
              let index = PodcastChapterNavigator(chapters: item.podcastChapters).nextIndex(
                at: position, selectedIndex: selectedPodcastChapterIndex) else { return }
        selectPodcastChapter(at: index)
    }

    func selectPreviousPodcastChapter() {
        guard let item,
              let index = PodcastChapterNavigator(chapters: item.podcastChapters).previousIndex(
                at: position, selectedIndex: selectedPodcastChapterIndex) else { return }
        selectPodcastChapter(at: index)
    }
}
