import Foundation

struct WiltedMacFeedRenameInteraction {
    private(set) var drafts: [String: WiltedMacFeedRenameDraft] = [:]

    mutating func begin(_ subscription: WiltedMacSubscription) {
        var draft = WiltedMacFeedRenameDraft()
        draft.begin(subscription)
        drafts[subscription.id] = draft
    }

    mutating func update(_ feedID: String, text: String) {
        guard var draft = drafts[feedID] else { return }
        draft.text = text
        drafts[feedID] = draft
    }

    mutating func cancel(_ feedID: String) {
        guard var draft = drafts[feedID] else { return }
        draft.cancel()
        drafts.removeValue(forKey: feedID)
    }

    /// Removes the editor synchronously; the caller starts async persistence after this returns.
    mutating func submit(_ feedID: String) -> String? {
        guard var draft = drafts[feedID], draft.beginSaving() else { return nil }
        drafts.removeValue(forKey: feedID)
        return draft.text
    }

    mutating func restoreFailure(_ subscription: WiltedMacSubscription, text: String, error: String) {
        var draft = WiltedMacFeedRenameDraft()
        draft.begin(subscription)
        draft.text = text
        draft.finish(error: error)
        drafts[subscription.id] = draft
    }
}
