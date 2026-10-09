import Foundation
import WiltedDomain
import WiltedLibrary

/// What "Continue from Mac" would do, decided from the device records and what the phone caches.
enum LibraryContinuation: Equatable, Sendable {
    /// The same revision is on the phone: play it at `positionSeconds`.
    case ready(entryID: ItemID, positionSeconds: Double, rate: Double, wasPlaying: Bool, sourceDeviceID: String, source: ObservedPlayback)
    /// Nothing is cached for the entry: request the audio first, then continue.
    case needsAudio(entryID: ItemID, revision: RevisionID, source: ObservedPlayback)
    /// The phone holds a different revision than the other device plays; continuing would resume the wrong audio.
    case refused(entryID: ItemID, reason: String, source: ObservedPlayback)

    var entryID: ItemID {
        switch self {
        case let .ready(entryID, _, _, _, _, _), let .needsAudio(entryID, _, _), let .refused(entryID, _, _): entryID
        }
    }
    /// The original winning server record, before stale-playing normalization.
    var source: ObservedPlayback {
        switch self {
        case let .ready(_, _, _, _, _, source), let .needsAudio(_, _, source), let .refused(_, _, source): source
        }
    }
}

/// Pure decision for the Continue banner. No I/O, so it is testable without a player.
enum LibraryContinuationPlanner {
    static let mismatchReason = "This phone has a different version of the episode than the Mac is playing. "
        + "Remove it from the phone, then get the Mac's version."

    /// Nil when no other device has playback, or this device's own record already outranks it
    /// (the phone was the last to play, so the Mac's older checkpoint is not something to continue).
    static func plan(
        records: LibraryDeviceRecords, deviceID: String, cachedRevisions: [ItemID: RevisionID],
        durations: [ItemID: Double], now: Date, clockOffset: TimeInterval
    ) -> LibraryContinuation? {
        let own = records.nowPlaying.first { $0.record.deviceID == deviceID }
        let others = records.nowPlaying.filter { $0.record.deviceID != deviceID }
        guard let winner = HandoffResolver.winner(among: others) else { return nil }
        if let own, !HandoffResolver.supersedes(winner, over: own) { return nil }
        let target = HandoffResolver.resumeTarget(
            observed: records.nowPlaying, localDeviceID: deviceID, localRevision: { cachedRevisions[$0] },
            now: now, clockOffset: clockOffset, durationSeconds: { durations[$0] })
        switch target {
        case .nothing:
            return nil
        case let .resume(resume):
            return .ready(
                entryID: resume.entryID, positionSeconds: resume.positionSeconds, rate: resume.rate,
                wasPlaying: resume.wasPlaying, sourceDeviceID: resume.sourceDeviceID, source: winner)
        case let .needsMedia(entryID, revision):
            return cachedRevisions[entryID] == nil
                ? .needsAudio(entryID: entryID, revision: revision, source: winner)
                : .refused(entryID: entryID, reason: mismatchReason, source: winner)
        }
    }
}

/// Factual age of the Mac playback checkpoint in the server clock domain.
struct LibraryContinuationAge: Equatable {
    let seconds: TimeInterval?
    let isStale: Bool

    init(source: ObservedPlayback, now: Date, clockOffset: TimeInterval) {
        let age = now.addingTimeInterval(clockOffset).timeIntervalSince(source.serverModifiedAt)
        seconds = age.isFinite && age >= 0 ? age : nil
        isStale = seconds.map { source.record.isPlaying && $0 > SyncCadence.staleAfter } ?? false
    }

    var text: String {
        guard let seconds else { return "Mac playback position age uncertain." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        let relative = formatter.localizedString(fromTimeInterval: -seconds)
        return "Mac playback position: \(relative)."
    }

    static let staleText = "Mac playback may be out of date."
}
