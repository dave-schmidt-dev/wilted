import Foundation

/// Every steady-state interval of the library sync, in one place, so the request rate of both
/// devices is read and changed here and pinned by tests.
///
/// Each device has ONE sync tick (`SyncTick`) every `tickInterval`, and everything periodic batches
/// into it: polls, publishes, position checkpoints, the intent index, pending-decision checks.
/// Nothing runs faster. A user action (a decision, a media request, a play start) may send its own
/// write at once as a single operation, but the read that confirms it waits for the next round.
/// After a rate limit the whole tick waits out the server's Retry-After (see `TransportGate`).
/// Real use is pausing on one device, walking away, then starting on the other, so 30 s is enough.
public enum SyncCadence {
    /// The one sync round of a device: the Mac while it runs, the phone while it is in front or playing.
    public static let tickInterval: TimeInterval = 30
    /// The Mac reads intents and every device's playback records this often, playing or not.
    public static let pollInterval: TimeInterval = tickInterval
    /// A playing device republishes its position this often (one NowPlaying and one Progress write).
    public static let playingPublishInterval: TimeInterval = tickInterval
    /// The phone looks at the other devices this often while it plays.
    public static let phoneObserveInterval: TimeInterval = tickInterval
    /// The Mac rereads its stored positions for publishing this often while nothing plays.
    public static let storedPositionRefreshInterval: TimeInterval = 60
    /// The phone fetches the library state (the Mac's published Larder) every this many rounds while
    /// idle in front (every 5 min); a silent push, a pull, a foreground and a pending decision fetch it
    /// at once. The playback records and the Mac's media offers ride every round's one batched read.
    public static let phoneStateEveryRounds = 10
    /// The Mac's whole-zone peer scan runs every this many polls (every `pollInterval` times this)
    /// while it knows no other device. The scan is the costliest read there is.
    public static let rediscoverEveryCycles = 4
    /// The same once another device is known: a second phone is rare, so the scan is rare (every 20 min).
    public static let rediscoverEveryCyclesWithPeers = 40
    /// A playing record older than this is presumed dead (three publish cadences).
    public static let staleAfter: TimeInterval = playingPublishInterval * 3
    /// A device reading a playing record advances its position by the record's age at most this
    /// far: a live device republishes within `playingPublishInterval`, so more is a dead one.
    public static let maxPlayingAdvance: TimeInterval = playingPublishInterval * 1.5
    /// The pause before the one confirming fetch after a takeover.
    public static let takeoverSettleDelay: TimeInterval = 1
    /// The longest a Mac Play press waits for the fresh read of the phone's position.
    public static let playPressFetchTimeout: TimeInterval = 2
    /// The Mac handoff tick. It performs no request by itself; publishes are paced by
    /// `playingPublishInterval` and reads by the poller.
    public static let macTickInterval: TimeInterval = 2
    /// First wait after a rate limit or service-unavailable reply, doubling per consecutive one.
    public static let backoffBase: TimeInterval = 5
    /// The longest a shared gate stays closed.
    public static let backoffCap: TimeInterval = 300
}
