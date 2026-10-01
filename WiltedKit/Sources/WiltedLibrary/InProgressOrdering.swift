import Foundation
import WiltedDomain

/// Where an in-progress episode stands, and when anyone last played it.
public struct EpisodeProgress: Sendable, Equatable {
    public let positionSeconds: Double
    /// The server date of the newest record behind `positionSeconds`, so Mac, phone and other devices
    /// compare on one clock.
    public let lastPlayedAt: Date

    public init(positionSeconds: Double, lastPlayedAt: Date) {
        self.positionSeconds = positionSeconds
        self.lastPlayedAt = lastPlayedAt
    }
}

/// The one rule for "in progress" and for listing in-progress episodes first, shared by the phone's
/// list, CarPlay and Siri so they never disagree.
///
/// An episode is in progress when any device, the Mac included, has a position past the start and the
/// episode is neither completed nor played to its end. The newest record decides how far along it is.
public enum InProgressOrdering {
    /// Seconds of slack before the end that still count as finished.
    public static let endTolerance: Double = 1

    /// Progress per in-progress entry from this device's own positions and the other devices' records.
    /// The newest record for an entry decides: if it is at the start or at the end the entry is not in
    /// progress, whatever an older record said. `completed` entries never appear; `durations` lets a
    /// position at the very end count as done. `nowPlaying` is the episode loaded in the player: the
    /// same rules apply to its position, and it counts as played at `now` only while it is playing.
    public static func progress(
        checkpoints: [ItemID: ObservedPlayback],
        ownPositions: [ItemID: ObservedPlayback],
        completed: Set<ItemID> = [],
        durations: [ItemID: Double] = [:],
        nowPlaying: (id: ItemID, position: Double, isPlaying: Bool)? = nil,
        now: Date = Date()
    ) -> [ItemID: EpisodeProgress] {
        let newest = newestRecords(checkpoints: checkpoints, ownPositions: ownPositions, completed: completed)
        var result: [ItemID: EpisodeProgress] = [:]
        for (id, observed) in newest {
            let position = observed.record.positionSeconds
            guard position > 0, !isFinished(position, duration: durations[id]) else { continue }
            result[id] = EpisodeProgress(positionSeconds: position, lastPlayedAt: observed.serverModifiedAt)
        }
        if let playing = nowPlaying, !completed.contains(playing.id), !isFinished(playing.position, duration: durations[playing.id]) {
            let existing = result[playing.id]
            if playing.isPlaying {
                result[playing.id] = EpisodeProgress(
                    positionSeconds: playing.position > 0 ? playing.position : (existing?.positionSeconds ?? 0), lastPlayedAt: now)
            } else if playing.position > 0 {
                result[playing.id] = EpisodeProgress(positionSeconds: playing.position, lastPlayedAt: existing?.lastPlayedAt ?? now)
            }
        }
        return result
    }

    /// Episodes played to their end that nobody has marked completed, with when that happened: the
    /// newest record sits at the very end, or the player is at the end of the loaded one. They count as
    /// completed for ordering and for auto-continue, so a finished episode is not picked up again from
    /// the start.
    public static func finished(
        checkpoints: [ItemID: ObservedPlayback],
        ownPositions: [ItemID: ObservedPlayback],
        completed: Set<ItemID> = [],
        durations: [ItemID: Double] = [:],
        nowPlaying: (id: ItemID, position: Double, isPlaying: Bool)? = nil,
        now: Date = Date()
    ) -> [ItemID: Date] {
        var result: [ItemID: Date] = [:]
        for (id, observed) in newestRecords(checkpoints: checkpoints, ownPositions: ownPositions, completed: completed)
        where observed.record.positionSeconds > 0 && isFinished(observed.record.positionSeconds, duration: durations[id]) {
            result[id] = observed.serverModifiedAt
        }
        if let playing = nowPlaying, !completed.contains(playing.id) {
            // What is loaded decides: at its end it is finished, anywhere else (the start included) it is
            // being played again.
            result[playing.id] = playing.position > 0 && isFinished(playing.position, duration: durations[playing.id])
                ? (result[playing.id] ?? now) : nil
        }
        return result
    }

    private static func newestRecords(
        checkpoints: [ItemID: ObservedPlayback], ownPositions: [ItemID: ObservedPlayback], completed: Set<ItemID>
    ) -> [ItemID: ObservedPlayback] {
        var newest: [ItemID: ObservedPlayback] = [:]
        for source in [checkpoints, ownPositions] {
            for (id, observed) in source where !completed.contains(id) {
                if let existing = newest[id], existing.serverModifiedAt >= observed.serverModifiedAt { continue }
                newest[id] = observed
            }
        }
        return newest
    }

    /// In-progress items first, newest play first; then every other item in its given order; then, when
    /// `completedAt` is given, the completed ones last, most recently completed first. Stable: items
    /// that tie keep the order they came in.
    public static func ordered<Element>(
        _ items: [Element], progress: [ItemID: EpisodeProgress], id: (Element) -> ItemID,
        completedAt: (Element) -> Date? = { _ in nil }
    ) -> [Element] {
        var pinned: [(offset: Int, played: Date, element: Element)] = []
        var rest: [Element] = []
        var done: [(offset: Int, at: Date, element: Element)] = []
        for (offset, element) in items.enumerated() {
            if let finishedAt = completedAt(element) {
                done.append((offset, finishedAt, element))
            } else if let entry = progress[id(element)] {
                pinned.append((offset, entry.lastPlayedAt, element))
            } else {
                rest.append(element)
            }
        }
        pinned.sort { $0.played != $1.played ? $0.played > $1.played : $0.offset < $1.offset }
        done.sort { $0.at != $1.at ? $0.at > $1.at : $0.offset < $1.offset }
        return pinned.map(\.element) + rest + done.map(\.element)
    }

    /// The one play order, for CarPlay, Siri and auto-continue: in-progress episodes first (newest play
    /// first), then the not-started ones, oldest published first (ties keep their given, Larder, order),
    /// then the completed ones last, most recently completed first.
    public static func playOrder<Element>(
        _ items: [Element], progress: [ItemID: EpisodeProgress], id: (Element) -> ItemID,
        publishedAt: (Element) -> Date, completedAt: (Element) -> Date?
    ) -> [Element] {
        let oldestFirst = items.enumerated().sorted {
            let (left, right) = (publishedAt($0.element), publishedAt($1.element))
            return left != right ? left < right : $0.offset < $1.offset
        }.map(\.element)
        return ordered(oldestFirst, progress: progress, id: id, completedAt: completedAt)
    }

    /// What auto-continue plays after `ended`: the first of the play order that is not completed and is
    /// not the episode that just ended; nil when none remain.
    public static func next<Element>(
        in playOrder: [Element], after ended: ItemID, id: (Element) -> ItemID, isCompleted: (Element) -> Bool
    ) -> Element? {
        playOrder.first { id($0) != ended && !isCompleted($0) }
    }

    /// Shows with an in-progress episode first (the newest play first), the others in their given order.
    public static func orderedShows(
        _ shows: [String], progressByShow: [String: Date]
    ) -> [String] {
        let pinned = shows.enumerated().compactMap { offset, show in progressByShow[show].map { (offset, $0, show) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
        return pinned + shows.filter { progressByShow[$0] == nil }
    }

    private static func isFinished(_ position: Double, duration: Double?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return position >= duration - endTolerance
    }
}
