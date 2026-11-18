import SwiftUI
import WiltedDomain

/// What a Larder row offers when swiped, by whether its audio is on the phone.
///
/// - Not downloaded: swipe right for Remove from Larder, swipe left for Download.
/// - Downloaded: swipe right for Mark completed, swipe left for Play (Pause while it plays).
///
/// Removing and completing always ask first, even on a full swipe, so a swipe never deletes or
/// completes by itself. Download and Play act at once. VoiceOver gets the same actions by name.
enum LibrarySwipe: Equatable {
    case removeFromLarder, markCompleted, download, play, pause

    /// A choice waiting for a yes.
    enum Confirmation: Equatable, Identifiable {
        case removeFromLarder(ItemID)
        case markCompleted(ItemID)

        var id: String {
            switch self {
            case let .removeFromLarder(id): "remove-\(id.rawValue)"
            case let .markCompleted(id): "complete-\(id.rawValue)"
            }
        }

        var title: String {
            switch self {
            case .removeFromLarder: "Remove from the Larder?"
            case .markCompleted: "Mark completed?"
            }
        }

        var message: String {
            switch self {
            case .removeFromLarder: "It is marked completed and leaves the Larder and active Feeds. Downloaded audio is kept for Restore."
            case .markCompleted: "It is marked completed and leaves the Larder and active Feeds. Downloaded audio is kept for Restore."
            }
        }

        var confirmLabel: String {
            switch self {
            case .removeFromLarder: "Remove from Larder"
            case .markCompleted: "Mark completed"
            }
        }

        var isDestructive: Bool { if case .removeFromLarder = self { true } else { false } }

        /// Sends the decision down the same path as the Larder's other controls, so the Mac applies it.
        @MainActor func confirmed(on model: LibraryAppModel) {
            switch self {
            case let .removeFromLarder(id): model.performDecision(.removeFromLarder, entryID: id)
            case let .markCompleted(id): model.performDecision(.markDone, entryID: id)
            }
        }
    }

    var title: String {
        switch self {
        case .removeFromLarder: LibraryDecisionAction.removeFromLarder.title
        case .markCompleted: LibraryDecisionAction.markDone.title
        case .download: "Download"
        case .play: "Play"
        case .pause: "Pause"
        }
    }

    var symbol: String {
        switch self {
        case .removeFromLarder: LibraryDecisionAction.removeFromLarder.systemImage
        case .markCompleted: LibraryDecisionAction.markDone.systemImage
        case .download: "arrow.down.circle"
        case .play: "play.fill"
        case .pause: "pause.fill"
        }
    }

    var identifierWord: String {
        switch self {
        case .removeFromLarder: "remove-from-larder"
        case .markCompleted: "mark-completed"
        case .download: "download"
        case .play: "play"
        case .pause: "pause"
        }
    }

    /// Swipe right. Downloaded: Mark completed (when the row offers it). Otherwise: Remove from Larder.
    static func leading(media: LibraryMediaState, canMarkCompleted: Bool) -> [LibrarySwipe] {
        media == .onPhone ? (canMarkCompleted ? [.markCompleted] : []) : [.removeFromLarder]
    }

    /// Swipe left. Downloaded: Play or Pause. Otherwise: Download, unless a transfer is already running
    /// (the row's own ring cancels it), the Mac has nothing to send, or the Mac has not linked this
    /// device yet (`canRequest` false), when no request can be answered.
    static func trailing(media: LibraryMediaState, isPlaying: Bool, canRequest: Bool = true) -> [LibrarySwipe] {
        switch media {
        case .onPhone: [isPlaying ? .pause : .play]
        case .available, .failed, .notPrepared: canRequest ? [.download] : []
        case .requested, .downloading, .downloadingFromMac, .verifying: []
        }
    }
}

/// The one-line hint under the Larder list: what a right and a left swipe do for the rows shown.
enum LibrarySwipeHint {
    /// nil when no listed row has any swipe action. Each side is one line and lists its distinct actions
    /// in first-seen order, joined with " or ": "Swipe right: Mark completed or Remove from Larder" above
    /// "Swipe left: Play or Download". A side with no action is left out.
    static func text(leading: [[LibrarySwipe]], trailing: [[LibrarySwipe]]) -> String? {
        let right = describe(side: "Swipe right", actions: leading)
        let left = describe(side: "Swipe left", actions: trailing)
        let parts = [right, left].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func describe(side: String, actions: [[LibrarySwipe]]) -> String? {
        var distinctTitles: [String] = []
        for action in actions.flatMap({ $0 }) {
            let normalized: LibrarySwipe = (action == .pause) ? .play : action
            let title = normalized.title
            if !distinctTitles.contains(title) {
                distinctTitles.append(title)
            }
        }
        guard !distinctTitles.isEmpty else { return nil }
        return "\(side): \(distinctTitles.joined(separator: " or "))"
    }
}
