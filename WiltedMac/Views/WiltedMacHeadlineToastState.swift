import Foundation
import WiltedLibrary

struct WiltedMacHeadlineToastState {
    static let historyLimit = 128
    private(set) var seenEventIDs: Set<String> = []
    private var eventOrder: [String] = []
    private(set) var story: LibraryHeadlineStory?
    private(set) var presentationID: UUID?

    mutating func present(_ story: LibraryHeadlineStory, eventID: String) -> Bool {
        guard seenEventIDs.insert(eventID).inserted else { return false }
        eventOrder.append(eventID)
        if eventOrder.count > Self.historyLimit {
            seenEventIDs.remove(eventOrder.removeFirst())
        }
        self.story = story
        presentationID = UUID()
        return true
    }

    mutating func dismiss() {
        story = nil
        presentationID = nil
    }

    mutating func reset() {
        seenEventIDs.removeAll()
        eventOrder.removeAll()
        dismiss()
    }

    func currentStory(in projection: LibraryHeadlineProjection?) -> LibraryHeadlineStory? {
        guard let story else { return nil }
        return projection?.saved.first(where: { $0.id == story.id })
            ?? projection?.recent.first(where: { $0.id == story.id })
            ?? story
    }
}
