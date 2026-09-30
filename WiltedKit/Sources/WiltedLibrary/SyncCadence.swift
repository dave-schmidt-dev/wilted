import Foundation

/// Every steady-state interval of the library sync, in one place, so the request rate of both
/// devices is read and changed here and pinned by tests.
///
/// Nothing in the background needs to move faster than `pollInterval`: real use is pausing on one
/// device, walking away, then starting on the other. Edge events (play, pause, seek, background,
/// foreground, a Mac Play press) are not periodic: they publish or fetch at once, on their own.
public enum SyncCadence {
    /// The Mac reads intents and every device's playback records this often, playing or not.
    public static let pollInterval: TimeInterval = 30
    /// A playing device republishes its position this often (one NowPlaying and one Progress write).
    public static let playingPublishInterval: TimeInterval = 30
    /// The phone looks at the other devices this often while it plays.
    public static let phoneObserveInterval: TimeInterval = 30
    /// The Mac rereads its stored positions for publishing this often while nothing plays.
    public static let storedPositionRefreshInterval: TimeInterval = 60
    /// The Mac's whole-zone peer scan runs every this many polls (every `pollInterval` times this).
    public static let rediscoverEveryCycles = 4
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
