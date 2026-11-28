import AppKit
import Foundation
import Observation
import WiltedLibrary

private nonisolated(unsafe) var headlineCatalogStateKey: UInt8 = 0

@MainActor
@Observable
final class WiltedMacHeadlineCatalogState {
    @ObservationIgnored private let store: WiltedMacHeadlineCatalogStore
    @ObservationIgnored private weak var model: WiltedMacModel?
    @ObservationIgnored private var appliedTopics: HeadlineTopicFilter?
    private(set) var projection: LibraryHeadlineProjection?
    private(set) var projectionMessage: String?
    private(set) var actionMessage: String?
    private(set) var isActionInProgress = false

    init(model: WiltedMacModel) {
        self.model = model
        store = model.headlineCatalogStore
        do {
            let filter = Self.topicFilter(model)
            projection = try store.pruneRecent(
                matching: { filter.skips(title: $0.title, link: $0.link) },
                skipKnownSports: filter.skipSports, at: Date())
            appliedTopics = filter
        }
        catch { projectionMessage = "Recent stories could not be loaded." }
    }

    private static func topicFilter(_ model: WiltedMacModel) -> HeadlineTopicFilter {
        HeadlineTopicFilter(
            skipSports: model.automationSettings.skipSportsHeadlines,
            words: model.automationSettings.skippedHeadlineWords)
    }

    func reconcileFilteredStories(
        at date: Date = Date(),
        excludedPublisherIDs: Set<String> = [],
        classifiedSportsStoryIDs: Set<String> = []
    ) -> Bool {
        guard let model else { return false }
        let filter = Self.topicFilter(model)
        do {
            let previousRevision = projection?.revision
            projection = try store.pruneRecent(matching: { story in
                filter.skips(title: story.title, link: story.link)
            }, classifiedSportsStoryIDs: classifiedSportsStoryIDs,
               excludedPublisherIDs: excludedPublisherIDs,
               skipKnownSports: filter.skipSports, at: date)
            projectionMessage = nil
            appliedTopics = filter
            if previousRevision != projection?.revision {
                model.librarySyncController?.requestPublish()
            }
            return true
        } catch {
            projectionMessage = "Recent stories could not be updated. Try again later."
            return false
        }
    }

    func refresh(at date: Date = Date()) {
        do {
            let previousRevision = projection?.revision
            let filter = model.map(Self.topicFilter)
            projection = try store.pruneRecent(matching: { story in
                filter?.skips(title: story.title, link: story.link) ?? false
            }, skipKnownSports: filter?.skipSports ?? false, at: date)
            projectionMessage = nil
            appliedTopics = filter
            if previousRevision != projection?.revision {
                model?.librarySyncController?.requestPublish()
            }
        } catch {
            projectionMessage = "Recent stories could not be loaded. Try again later."
        }
    }

    /// Reads current local state for sync, then reuses the same topic-filtered projection as Reports.
    func projectionForPublication(at date: Date) -> LibraryHeadlineProjection? {
        guard let model else { return projection }
        let filter = Self.topicFilter(model)
        do {
            let latest = try store.projection(at: date)
            guard latest.revision != projection?.revision || appliedTopics != filter else { return projection }
            let previousRevision = projection?.revision
            projection = try store.pruneRecent(matching: { story in
                filter.skips(title: story.title, link: story.link)
            }, skipKnownSports: filter.skipSports, at: date)
            projectionMessage = nil
            appliedTopics = filter
            if previousRevision != projection?.revision {
                model.librarySyncController?.requestPublish()
            }
            return projection
        } catch {
            projectionMessage = "Recent stories could not be loaded. Try again later."
            return nil
        }
    }

    func mergeCandidates(
        _ candidates: [NewsHeadlineCandidate],
        excludedPublisherIDs: Set<String> = [],
        at date: Date
    ) throws {
        let filter = model.map(Self.topicFilter) ?? HeadlineTopicFilter()
        let sportsOnlyFilter = HeadlineTopicFilter(skipSports: true)
        let classifiedSportsIDs = Set(candidates.filter {
            sportsOnlyFilter.skips(title: $0.title, link: $0.link, categories: $0.categories)
        }.map(\.id))
        let filteredCandidates = candidates.filter { candidate in
            !filter.skips(title: candidate.title, link: candidate.link, categories: candidate.categories)
        }
        let previousRevision = projection?.revision
        do {
            projection = try store.pruneRecent(matching: { story in
                filter.skips(title: story.title, link: story.link)
            }, classifiedSportsStoryIDs: classifiedSportsIDs,
               excludedPublisherIDs: excludedPublisherIDs,
               skipKnownSports: filter.skipSports, at: date)
        } catch {
            projectionMessage = "Recent stories could not be updated. Try again later."
            throw error
        }

        let stories = filteredCandidates.compactMap { candidate -> LibraryHeadlineStory? in
            let title = String(candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(LibraryHeadlineStory.maximumTitleLength))
            let publisherName = String(candidate.feedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(LibraryHeadlineStory.maximumPublisherNameLength))
            guard !title.isEmpty, !publisherName.isEmpty, let publisherID = candidate.feedID else { return nil }
            return try? LibraryHeadlineStory(
                id: candidate.id, title: title, publisherID: publisherID, publisherName: publisherName,
                link: candidate.link, publishedAt: candidate.publishedAt, firstSeenAt: date, lastSeenAt: date)
        }
        do {
            projection = try store.mergeRecent(
                stories, classifiedSportsStoryIDs: classifiedSportsIDs, at: date)
            projectionMessage = nil
            appliedTopics = filter
            if previousRevision != projection?.revision {
                model?.librarySyncController?.requestPublish()
            }
        } catch {
            if previousRevision != projection?.revision {
                model?.librarySyncController?.requestPublish()
            }
            projectionMessage = "Recent stories could not be updated. Try again later."
            throw error
        }
    }

    func setSaved(_ story: LibraryHeadlineStory, isSaved: Bool) {
        runAction(starting: isSaved ? "Saving story…" : "Removing saved story…") {
            let result = try self.store.setSaved(
                story: story, isSaved: isSaved, basedOnRevision: story.savedRevision,
                commandID: UUID().uuidString, at: Date())
            switch result {
            case .applied:
                self.model?.librarySyncController?.requestPublish()
                return isSaved ? "Saved to Notebook." : "Removed from Notebook."
            case .staleRevision:
                return "The story changed on another device. The list is current. Try again."
            case .rejected:
                return "Couldn’t update the story. Try again."
            }
        }
    }

    func setMuted(_ story: LibraryHeadlineStory, isMuted: Bool) {
        let revision = projection?.publishers.first(where: { $0.id == story.publisherID })?.revision ?? 0
        runAction(starting: isMuted ? "Muting source…" : "Unmuting source…") {
            let result = try self.store.setPublisherMuted(
                id: story.publisherID, name: story.publisherName, isMuted: isMuted,
                basedOnRevision: revision, commandID: UUID().uuidString, at: Date())
            switch result {
            case .applied:
                self.model?.bulletinHub.publisherMuteChanged(story.publisherID)
                self.model?.librarySyncController?.requestPublish()
                return isMuted ? "Source muted." : "Source unmuted."
            case .staleRevision:
                return "The source changed on another device. The list is current. Try again."
            case .rejected:
                return "Couldn’t update the source. Try again."
            }
        }
    }

    private func runAction(starting message: String, operation: @escaping () throws -> String) {
        guard !isActionInProgress else { return }
        isActionInProgress = true
        actionMessage = message
        Task { @MainActor in
            await Task.yield()
            defer { isActionInProgress = false }
            do {
                actionMessage = try operation()
                refresh()
            } catch {
                actionMessage = "Couldn’t update the story list. Try again."
                refresh()
            }
        }
    }
}

extension WiltedMacModel {
    /// One observable projection shared by Reports, the player, and local story actions.
    var headlineCatalogState: WiltedMacHeadlineCatalogState {
        if let state = objc_getAssociatedObject(self, &headlineCatalogStateKey) as? WiltedMacHeadlineCatalogState {
            return state
        }
        let state = WiltedMacHeadlineCatalogState(model: self)
        objc_setAssociatedObject(self, &headlineCatalogStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }
}
