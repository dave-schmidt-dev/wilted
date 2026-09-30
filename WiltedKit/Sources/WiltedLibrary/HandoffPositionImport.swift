import Foundation
import WiltedDomain

/// A position another device reported for an entry, in the form the library writer (the Mac)
/// would adopt as its own stored position.
public struct ImportablePosition: Sendable, Equatable {
    public let entryID: ItemID
    public let revision: RevisionID
    /// The position the record holds.
    public let positionSeconds: Double
    /// Media seconds the other device has played since it saved the record, when the record says
    /// it was playing and is fresh; zero otherwise (see `SyncCadence.maxPlayingAdvance`).
    public let advanceSeconds: Double
    /// The moment `resumeSeconds` is valid for, on the importing device's clock (server date
    /// minus the importer's clock offset, plus the advance), so it compares with the importer's
    /// own save times.
    public let observedAt: Date
    public let sourceDeviceID: String
    public let epoch: Int
    /// Whether the record said the other device was playing.
    public let isPlaying: Bool

    /// Where to resume: the recorded position plus what was played since.
    public var resumeSeconds: Double { positionSeconds + advanceSeconds }

    public init(
        entryID: ItemID, revision: RevisionID, positionSeconds: Double, advanceSeconds: Double = 0,
        observedAt: Date, sourceDeviceID: String, epoch: Int, isPlaying: Bool = false
    ) {
        self.entryID = entryID
        self.revision = revision
        self.positionSeconds = positionSeconds
        self.advanceSeconds = advanceSeconds
        self.observedAt = observedAt
        self.sourceDeviceID = sourceDeviceID
        self.epoch = epoch
        self.isPlaying = isPlaying
    }
}

/// Which of the other devices' playback records the library writer should adopt as positions.
///
/// Pure. It decides only which record speaks for an entry; whether that record is newer than
/// what the writer has stored, whether the revision is the one the writer offers, and whether
/// the episode is finished or playing are the writer's checks, made against its own state.
public enum HandoffPositionImport {
    /// One candidate per entry: the record of another device that wins by `HandoffResolver`
    /// order (epoch, then server date, then device ID), unless a record for the same entry from
    /// any device holds a higher epoch. A lower epoch is stale whatever its server date, for
    /// example a phone's pause published while it gave up playback to a Mac that started later.
    /// A record that says its device is playing and is fresh (within `SyncCadence.staleAfter` of
    /// `now`) resumes ahead of its recorded position by the time since it was saved, at its rate.
    ///
    /// Both channels are read: a device's NowPlaying record is its latest position for one
    /// entry, its Progress records its position for each entry. A record at position zero is
    /// not a position. Sorted by entry ID.
    public static func candidates(
        records: LibraryDeviceRecords, localDeviceID: String, now: Date = Date()
    ) -> [ImportablePosition] {
        let all = records.nowPlaying + records.progress
        let offset = clockOffset(of: all.filter { $0.record.deviceID == localDeviceID })
        var result: [ImportablePosition] = []
        for (entryID, entryRecords) in Dictionary(grouping: all, by: \.record.entryID) {
            let others = entryRecords.filter { $0.record.deviceID != localDeviceID }
            guard let winner = HandoffResolver.winner(among: others),
                  !HandoffResolver.isStale(winner.record, seen: entryRecords.map(\.record)),
                  winner.record.positionSeconds > 0 else { continue }
            let savedAt = winner.serverModifiedAt.addingTimeInterval(-offset)
            let playing = HandoffResolver.effective(winner, now: now, clockOffset: offset).record.isPlaying
            let elapsed = playing ? min(max(0, now.timeIntervalSince(savedAt)), SyncCadence.maxPlayingAdvance) : 0
            result.append(ImportablePosition(
                entryID: entryID, revision: winner.record.revision, positionSeconds: winner.record.positionSeconds,
                advanceSeconds: elapsed * winner.record.rate, observedAt: savedAt.addingTimeInterval(elapsed),
                sourceDeviceID: winner.record.deviceID, epoch: winner.record.epoch, isPlaying: playing))
        }
        return result.sorted { $0.entryID.rawValue < $1.entryID.rawValue }
    }

    /// Server clock minus this device's clock, from its newest record that carries a publish
    /// time; zero when it has none.
    public static func clockOffset(of own: [ObservedPlayback]) -> TimeInterval {
        own.filter { $0.record.publishedAt != nil }
            .max { $0.serverModifiedAt < $1.serverModifiedAt }
            .flatMap(HandoffResolver.clockOffset(of:)) ?? 0
    }
}
