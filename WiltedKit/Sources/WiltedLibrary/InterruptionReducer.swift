import Foundation
import WiltedDomain

/// Where program audio stood when a bulletin started speaking. Restore and resume apply only
/// while the entry, revision and command generation still match it.
public struct SpeechCheckpoint: Equatable, Sendable {
    public let entryID: ItemID
    public let revisionID: RevisionID
    public let positionSeconds: Double
    /// The player's counter of user and system commands (seek, item change, pause, play).
    public let commandGeneration: UInt64

    public init(entryID: ItemID, revisionID: RevisionID, positionSeconds: Double, commandGeneration: UInt64) {
        self.entryID = entryID
        self.revisionID = revisionID
        self.positionSeconds = positionSeconds
        self.commandGeneration = commandGeneration
    }
}

/// What the player reports with an event: the item, where it is, whether program audio is
/// playing, and the receiving device's clock.
public struct PlaybackSnapshot: Equatable, Sendable {
    public let entryID: ItemID
    public let revisionID: RevisionID
    public let positionSeconds: Double
    public let commandGeneration: UInt64
    public let isPlaying: Bool
    public let now: Date

    public init(entryID: ItemID, revisionID: RevisionID, positionSeconds: Double, commandGeneration: UInt64,
                isPlaying: Bool, now: Date) {
        self.entryID = entryID
        self.revisionID = revisionID
        self.positionSeconds = positionSeconds
        self.commandGeneration = commandGeneration
        self.isPlaying = isPlaying
        self.now = now
    }

    public var checkpoint: SpeechCheckpoint {
        SpeechCheckpoint(entryID: entryID, revisionID: revisionID, positionSeconds: positionSeconds,
                         commandGeneration: commandGeneration)
    }

    fileprivate func sameItem(as checkpoint: SpeechCheckpoint) -> Bool {
        entryID == checkpoint.entryID && revisionID == checkpoint.revisionID
    }

    fileprivate func current(for checkpoint: SpeechCheckpoint) -> Bool {
        sameItem(as: checkpoint) && commandGeneration == checkpoint.commandGeneration
    }
}

public enum InterruptionState: Equatable, Sendable {
    case idle
    case speaking(Bulletin, SpeechCheckpoint)
}

public enum InterruptionEvent: Equatable, Sendable {
    case bulletinArrived(Bulletin, PlaybackSnapshot)
    /// Maintenance tick; it never starts speech.
    case tick(PlaybackSnapshot)
    /// A prepared podcast ad was removed at this exact playback seam.
    case adBreakReached(PlaybackSnapshot)
    case speechFinished(PlaybackSnapshot)
    /// The speaker refused the captured bulletin before it could start.
    case speechStartFailed(PlaybackSnapshot)
    case skip(PlaybackSnapshot)
    /// Mac seek cancellation restores the hold without resuming; iOS seeking is unchanged.
    case seekStarted(PlaybackSnapshot)
    case userPaused(PlaybackSnapshot)
    case playbackStopped(PlaybackSnapshot)
    case routeLost(PlaybackSnapshot)
    case systemInterruption(shouldResume: Bool, PlaybackSnapshot)
    case itemChanged
    /// The fetched bulletin list changed. Canceled alerts are dropped, while valid headlines
    /// already queued remain until the next ad break.
    case channelReplaced([Bulletin], PlaybackSnapshot)
}

public enum InterruptionEffect: Equatable, Sendable {
    /// Hold program audio, then speak.
    case speak(Bulletin, SpeechCheckpoint)
    case stopSpeech
    case restore(SpeechCheckpoint)
    case resume
}

/// Pure decision logic for spoken interruptions, shared by the Mac and iPhone players.
///
/// It speaks only at a removed-ad seam while program audio is playing. Each seam snapshots the
/// currently pending bulletins into one batch. Later arrivals wait for a later seam. Expired
/// bulletins are discarded, and restore/resume require the original checkpoint to remain current.
public struct InterruptionReducer: Sendable {
    public private(set) var state: InterruptionState = .idle
    /// Not yet spoken, ordered by severity (highest first) then issue time.
    public private(set) var pending: [Bulletin] = []
    /// Bulletins already captured by the current break, excluding the one being spoken.
    public var remainingInBatch: [Bulletin] { batch }
    /// Spoken or speaking ids with their expiry, so a bulletin is spoken once and the memory is bounded.
    private var spoken: [String: Date] = [:]
    /// Remaining bulletins captured at the current ad seam.
    private var batch: [Bulletin] = []

    /// Creates a reducer with ids already spoken on this device and their retention deadlines.
    /// Values whose deadline has passed are removed on the first event.
    public init(alreadySpoken: [String: Date] = [:]) {
        self.spoken = alreadySpoken
    }

    /// Removes queued bulletins that became ineligible while another headline started speaking.
    public mutating func removePendingBulletins(withIDs ids: Set<String>) {
        pending.removeAll { ids.contains($0.id) }
        batch.removeAll { ids.contains($0.id) }
    }

    public mutating func handle(_ event: InterruptionEvent) -> [InterruptionEffect] {
        switch event {
        case let .bulletinArrived(bulletin, snapshot): return arrive(bulletin, snapshot)
        case let .tick(snapshot):
            prune(snapshot.now)
            return []
        case let .adBreakReached(snapshot): return beginBatch(snapshot)
        case let .speechFinished(snapshot): return finish(snapshot, stopSpeech: false)
        case let .speechStartFailed(snapshot): return failedStart(snapshot)
        case let .skip(snapshot): return finish(snapshot, stopSpeech: true)
        case let .seekStarted(snapshot), let .userPaused(snapshot), let .playbackStopped(snapshot), let .routeLost(snapshot):
            return halt(snapshot, resume: false)
        case let .systemInterruption(shouldResume, snapshot): return halt(snapshot, resume: shouldResume)
        case .itemChanged: return changeItem()
        case let .channelReplaced(list, snapshot): return replaceChannel(list, snapshot)
        }
    }

    // MARK: Events

    private mutating func arrive(_ bulletin: Bulletin, _ snapshot: PlaybackSnapshot) -> [InterruptionEffect] {
        prune(snapshot.now)
        let supersededByKnown = knownBulletins.contains { $0.supersedes == bulletin.id }
        guard !bulletin.isExpired(at: snapshot.now), !isKnown(bulletin.id), !supersededByKnown else { return [] }
        if let replaced = bulletin.supersedes {
            pending.removeAll { $0.id == replaced }
            batch.removeAll { $0.id == replaced }
        }
        enqueue(bulletin)
        return []
    }

    private mutating func beginBatch(_ snapshot: PlaybackSnapshot) -> [InterruptionEffect] {
        prune(snapshot.now)
        guard snapshot.isPlaying, case .idle = state, !pending.isEmpty else { return [] }
        batch = pending
        pending.removeAll(keepingCapacity: true)
        return speak(batch.removeFirst(), snapshot)
    }

    private mutating func finish(_ snapshot: PlaybackSnapshot, stopSpeech: Bool) -> [InterruptionEffect] {
        guard case let .speaking(_, checkpoint) = state else { return [] }
        state = .idle
        prune(snapshot.now)
        guard snapshot.current(for: checkpoint) else {
            returnBatchToPending()
            return stopSpeech ? [.stopSpeech] : []
        }
        if !stopSpeech, !batch.isEmpty {
            let next = batch.removeFirst()
            return speak(next, checkpoint: checkpoint, now: snapshot.now)
        }
        if stopSpeech { returnBatchToPending() }
        else { batch.removeAll(keepingCapacity: true) }
        return (stopSpeech ? [.stopSpeech] : []) + [.restore(checkpoint), .resume]
    }

    private mutating func failedStart(_ snapshot: PlaybackSnapshot) -> [InterruptionEffect] {
        guard case let .speaking(bulletin, checkpoint) = state else { return [] }
        state = .idle
        spoken.removeValue(forKey: bulletin.id)
        prune(snapshot.now)
        if !bulletin.isExpired(at: snapshot.now) { enqueue(bulletin) }
        returnBatchToPending()
        guard snapshot.current(for: checkpoint) else { return [.stopSpeech] }
        return [.stopSpeech, .restore(checkpoint), .resume]
    }

    private mutating func halt(_ snapshot: PlaybackSnapshot, resume: Bool) -> [InterruptionEffect] {
        guard case let .speaking(_, checkpoint) = state else { return [] }
        state = .idle
        returnBatchToPending()
        // The pause or interruption is itself the newest command, so only the item must match.
        guard snapshot.sameItem(as: checkpoint) else { return [.stopSpeech] }
        return [.stopSpeech, .restore(checkpoint)] + (resume ? [.resume] : [])
    }

    private mutating func replaceChannel(_ list: [Bulletin], _ snapshot: PlaybackSnapshot) -> [InterruptionEffect] {
        let activeAlerts = Set(list.filter { $0.kind == .alert }.map(\.id))
        pending.removeAll { $0.kind == .alert && !activeAlerts.contains($0.id) }
        batch.removeAll { $0.kind == .alert && !activeAlerts.contains($0.id) }
        prune(snapshot.now)
        for bulletin in list { _ = arrive(bulletin, snapshot) }
        return []
    }

    private mutating func changeItem() -> [InterruptionEffect] {
        guard case .speaking = state else { return [] }
        state = .idle
        returnBatchToPending()
        return [.stopSpeech]
    }

    private mutating func speak(_ bulletin: Bulletin, _ snapshot: PlaybackSnapshot) -> [InterruptionEffect] {
        speak(bulletin, checkpoint: snapshot.checkpoint, now: snapshot.now)
    }

    private mutating func speak(_ bulletin: Bulletin, checkpoint: SpeechCheckpoint, now: Date) -> [InterruptionEffect] {
        guard !bulletin.isExpired(at: now) else {
            state = .idle
            return []
        }
        spoken[bulletin.id] = bulletin.expiresAt
        state = .speaking(bulletin, checkpoint)
        return [.speak(bulletin, checkpoint)]
    }

    // MARK: Bookkeeping

    private var knownBulletins: [Bulletin] {
        var all = pending + batch
        switch state {
        case let .speaking(bulletin, _): all.append(bulletin)
        case .idle: break
        }
        return all
    }

    private func isKnown(_ id: String) -> Bool {
        spoken[id] != nil || knownBulletins.contains { $0.id == id }
    }

    private mutating func enqueue(_ bulletin: Bulletin) {
        pending.append(bulletin)
        pending.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.issuedAt != $1.issuedAt { return $0.issuedAt < $1.issuedAt }
            return $0.id < $1.id
        }
    }

    private mutating func returnBatchToPending() {
        let remaining = batch
        batch.removeAll(keepingCapacity: true)
        for bulletin in remaining { enqueue(bulletin) }
    }

    private mutating func prune(_ now: Date) {
        pending.removeAll { $0.isExpired(at: now) }
        batch.removeAll { $0.isExpired(at: now) }
        spoken = spoken.filter { $0.value > now }
    }
}
