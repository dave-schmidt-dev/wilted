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
    case waiting(Bulletin, deadline: Date)
    case speaking(Bulletin, SpeechCheckpoint)
}

public enum InterruptionEvent: Equatable, Sendable {
    case bulletinArrived(Bulletin, PlaybackSnapshot)
    /// Time passing; promotes pending bulletins and fires a waiting one whose deadline came.
    case tick(PlaybackSnapshot)
    case pausePointReached(PlaybackSnapshot)
    case speechFinished(PlaybackSnapshot)
    case skip(PlaybackSnapshot)
    /// Mac seek cancellation restores the hold without resuming; iOS seeking is unchanged.
    case seekStarted(PlaybackSnapshot)
    case userPaused(PlaybackSnapshot)
    case playbackStopped(PlaybackSnapshot)
    case routeLost(PlaybackSnapshot)
    case systemInterruption(shouldResume: Bool, PlaybackSnapshot)
    case itemChanged
    /// The fetched bulletin list changed (the caller sends the headlines plus its own active
    /// alerts). Anything pending or waiting that is no longer listed is dropped.
    case channelReplaced([Bulletin], PlaybackSnapshot)
}

public enum InterruptionEffect: Equatable, Sendable {
    /// Find the next pause point and send `pausePointReached`; `tick` covers the deadline.
    case awaitPausePoint(Bulletin, deadline: Date)
    /// Hold program audio, then speak.
    case speak(Bulletin, SpeechCheckpoint)
    case stopSpeech
    case restore(SpeechCheckpoint)
    case resume
}

/// Pure decision logic for spoken interruptions, shared by the Mac and iPhone players.
///
/// It never speaks while program audio is not playing, speaks each bulletin id once, and drops a
/// bulletin whose `expiresAt` has passed on this device's clock before waiting and before
/// speaking. Restore and resume are emitted together, and only while the checkpoint is still
/// current, so a newer command always wins over a late speech completion.
public struct InterruptionReducer: Sendable {
    public private(set) var state: InterruptionState = .idle
    /// Not yet waiting, ordered by severity (highest first) then issue time.
    public private(set) var pending: [Bulletin] = []
    public let waitLimit: TimeInterval
    /// Spoken or speaking ids with their expiry, so a bulletin is spoken once and the memory is bounded.
    private var spoken: [String: Date] = [:]

    public init(waitLimit: TimeInterval = 60) { self.waitLimit = max(0, waitLimit) }

    public mutating func handle(_ event: InterruptionEvent) -> [InterruptionEffect] {
        switch event {
        case let .bulletinArrived(bulletin, snapshot): return arrive(bulletin, snapshot)
        case let .tick(snapshot): return advance(snapshot)
        case let .pausePointReached(snapshot): return reachPausePoint(snapshot)
        case let .speechFinished(snapshot): return finish(snapshot, stopSpeech: false)
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
        guard !bulletin.isExpired(at: snapshot.now), !isKnown(bulletin.id), !supersededByKnown else {
            return advance(snapshot)
        }
        if let replaced = bulletin.supersedes {
            pending.removeAll { $0.id == replaced }
            if case let .waiting(waiting, _) = state, waiting.id == replaced { state = .idle }
        }
        enqueue(bulletin)
        return advance(snapshot)
    }

    private mutating func reachPausePoint(_ snapshot: PlaybackSnapshot) -> [InterruptionEffect] {
        var effects = advance(snapshot)
        if snapshot.isPlaying, case let .waiting(bulletin, _) = state {
            state = .idle
            effects += speak(bulletin, snapshot)
        }
        return effects
    }

    private mutating func finish(_ snapshot: PlaybackSnapshot, stopSpeech: Bool) -> [InterruptionEffect] {
        guard case let .speaking(_, checkpoint) = state else { return [] }
        state = .idle
        prune(snapshot.now)
        guard snapshot.current(for: checkpoint) else { return stopSpeech ? [.stopSpeech] : [] }
        if !stopSpeech, let next = pending.first, next.severity == .extreme {
            // An Extreme alert queued behind the one that just finished is spoken next, from the
            // same checkpoint, so program audio is restored once at the very end.
            pending.removeFirst()
            return speak(next, checkpoint: checkpoint, now: snapshot.now)
        }
        return (stopSpeech ? [.stopSpeech] : []) + [.restore(checkpoint), .resume]
    }

    private mutating func halt(_ snapshot: PlaybackSnapshot, resume: Bool) -> [InterruptionEffect] {
        demoteWaiting()
        guard case let .speaking(_, checkpoint) = state else { return [] }
        state = .idle
        // The pause or interruption is itself the newest command, so only the item must match.
        guard snapshot.sameItem(as: checkpoint) else { return [.stopSpeech] }
        return [.stopSpeech, .restore(checkpoint)] + (resume ? [.resume] : [])
    }

    private mutating func changeItem() -> [InterruptionEffect] {
        guard case .speaking = state else { return [] }
        state = .idle
        return [.stopSpeech]
    }

    private mutating func replaceChannel(_ list: [Bulletin], _ snapshot: PlaybackSnapshot) -> [InterruptionEffect] {
        let listed = Set(list.map(\.id))
        pending.removeAll { !listed.contains($0.id) }
        if case let .waiting(waiting, _) = state, !listed.contains(waiting.id) { state = .idle }
        return advance(snapshot)
    }

    // MARK: Promotion

    private mutating func advance(_ snapshot: PlaybackSnapshot) -> [InterruptionEffect] {
        prune(snapshot.now)
        guard snapshot.isPlaying else {
            demoteWaiting()
            return []
        }
        var effects: [InterruptionEffect] = []
        switch state {
        case .speaking:
            return []
        case let .waiting(bulletin, deadline):
            if bulletin.severity != .extreme, pending.first?.severity == .extreme {
                demoteWaiting()
            } else if snapshot.now >= deadline {
                state = .idle
                effects += speak(bulletin, snapshot)
            } else {
                return []
            }
        case .idle:
            break
        }
        while case .idle = state, !pending.isEmpty {
            let next = pending.removeFirst()
            if next.severity == .extreme {
                effects += speak(next, snapshot)
            } else {
                let deadline = snapshot.now.addingTimeInterval(waitLimit)
                state = .waiting(next, deadline: deadline)
                effects.append(.awaitPausePoint(next, deadline: deadline))
            }
        }
        return effects
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
        var all = pending
        switch state {
        case let .waiting(bulletin, _), let .speaking(bulletin, _): all.append(bulletin)
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

    private mutating func demoteWaiting() {
        guard case let .waiting(bulletin, _) = state else { return }
        state = .idle
        enqueue(bulletin)
    }

    private mutating func prune(_ now: Date) {
        pending.removeAll { $0.isExpired(at: now) }
        spoken = spoken.filter { $0.value > now }
        if case let .waiting(bulletin, _) = state, bulletin.isExpired(at: now) { state = .idle }
    }
}
