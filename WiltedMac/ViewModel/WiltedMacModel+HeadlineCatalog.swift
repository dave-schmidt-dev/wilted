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
    private(set) var projection: LibraryHeadlineProjection?
    private(set) var projectionMessage: String?
    private(set) var actionMessage: String?
    private(set) var isActionInProgress = false

    init(model: WiltedMacModel) {
        self.model = model
        store = model.headlineCatalogStore
        do { projection = try store.projection(at: Date()) }
        catch { projectionMessage = "Recent stories could not be loaded." }
    }

    func refresh(at date: Date = Date()) {
        do {
            let previousRevision = projection?.revision
            projection = try store.projection(at: date)
            projectionMessage = nil
            if previousRevision != projection?.revision {
                model?.librarySyncController?.requestPublish()
            }
        } catch {
            projectionMessage = "Recent stories could not be loaded. Try again later."
        }
    }

    func mergeCandidates(_ candidates: [NewsHeadlineCandidate], at date: Date) throws {
        let stories = candidates.compactMap { candidate -> LibraryHeadlineStory? in
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
            let previousRevision = projection?.revision
            projection = try store.mergeRecent(stories, at: date)
            projectionMessage = nil
            if previousRevision != projection?.revision {
                model?.librarySyncController?.requestPublish()
            }
        } catch {
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
