import Foundation

/// The owner's choices for the online ad labeller, held in `UserDefaults`.
///
/// Every key starts with `wilted.adLabeller.`. Feed ID sets are stored as sorted
/// arrays without blanks or repeats, and the key is removed once a set is empty.
// `UserDefaults` is documented as thread-safe but is not annotated `Sendable`.
public struct AdLabellerPreferences: @unchecked Sendable {
    public static let keyPrefix = "wilted.adLabeller."
    public static let defaultModelID = "deepseek-v4.1-flash"
    public static let defaultLevel = "low"
    public static let defaultDailyCap = 60
    /// Two hours.
    public static let defaultWaitLimit: TimeInterval = 2 * 60 * 60
    /// Feed IDs the owner marked as already ad-free (`WiltedMacAdFreeFeedPreference`).
    public static let adFreeFeedsKey = "wilted.feeds.adFree"

    static let enabledKey = keyPrefix + "enabled"
    static let confirmedKey = keyPrefix + "confirmedFeedIDs"
    static let shadowKey = keyPrefix + "shadow"
    static let localOnlyKey = keyPrefix + "localOnlyFeedIDs"
    static let modelKey = keyPrefix + "modelID"
    static let levelKey = keyPrefix + "level"
    static let capKey = keyPrefix + "dailyCap"
    static let waitLimitKey = keyPrefix + "waitLimitSeconds"
    static let useOpenCodeCLIKey = keyPrefix + "useOpenCodeCLI"
    static let pauseCountKey = keyPrefix + "providerPauseCount"
    static let pausedSinceKey = keyPrefix + "providerPausedSince"
    /// Consecutive wait-limit stops on temporary failures after which the provider counts as paused.
    public static let pauseThreshold = 3

    public let preferences: UserDefaults

    public init(preferences: UserDefaults) {
        self.preferences = preferences
    }

    /// The global switch. Off by default; while off every feed is labelled locally.
    public var isEnabled: Bool {
        get { preferences.bool(forKey: Self.enabledKey) }
        nonmutating set { preferences.set(newValue, forKey: Self.enabledKey) }
    }

    /// Shadow mode: labels are requested and compared but never applied. Off unless it is
    /// switched on explicitly, so labelled cuts apply once the global switch is on and the
    /// show is confirmed.
    public var isShadow: Bool {
        get { preferences.bool(forKey: Self.shadowKey) }
        nonmutating set { preferences.set(newValue, forKey: Self.shadowKey) }
    }

    /// Feed IDs the owner has confirmed for online labelling, sorted. Empty by default.
    public var confirmedFeedIDs: [String] { Self.read(Self.confirmedKey, from: preferences) }

    /// Feed IDs the owner keeps local regardless of the switch, sorted.
    public var localOnlyFeedIDs: [String] { Self.read(Self.localOnlyKey, from: preferences) }

    /// Feed IDs the owner marked as already ad-free, sorted. Read-only here; the Mac preference writes them.
    public var adFreeFeedIDs: [String] { Self.read(Self.adFreeFeedsKey, from: preferences) }

    public func isConfirmed(feedID: String) -> Bool { confirmedFeedIDs.contains(feedID) }

    public func isLocalOnly(feedID: String) -> Bool { localOnlyFeedIDs.contains(feedID) }

    public func setConfirmed(feedID: String, _ confirmed: Bool) {
        Self.update(Self.confirmedKey, feedID: feedID, present: confirmed, in: preferences)
    }

    public func setLocalOnly(feedID: String, _ localOnly: Bool) {
        Self.update(Self.localOnlyKey, feedID: feedID, present: localOnly, in: preferences)
    }

    /// The provider model ID. A blank stored value falls back to the default.
    public var modelID: String {
        get {
            let stored = preferences.string(forKey: Self.modelKey) ?? ""
            return stored.isEmpty ? Self.defaultModelID : stored
        }
        nonmutating set { preferences.set(newValue, forKey: Self.modelKey) }
    }

    /// The labelling level. A blank stored value falls back to `low`.
    public var level: String {
        get {
            let stored = preferences.string(forKey: Self.levelKey) ?? ""
            return stored.isEmpty ? Self.defaultLevel : stored
        }
        nonmutating set { preferences.set(newValue, forKey: Self.levelKey) }
    }

    /// The most HTTP requests sent per local day. A missing value reads as 60; a stored negative
    /// value reads as 0, which sends nothing.
    public var dailyCap: Int {
        get {
            guard preferences.object(forKey: Self.capKey) != nil else { return Self.defaultDailyCap }
            return max(0, preferences.integer(forKey: Self.capKey))
        }
        nonmutating set { preferences.set(max(0, newValue), forKey: Self.capKey) }
    }

    /// How long an episode waits for the provider, in seconds, before its original audio is
    /// published with the reason. The shadow request uses `LabellerClient`'s own fixed time limit.
    public var waitLimit: TimeInterval {
        get {
            guard preferences.object(forKey: Self.waitLimitKey) != nil else { return Self.defaultWaitLimit }
            let stored = preferences.double(forKey: Self.waitLimitKey)
            return stored > 0 ? stored : Self.defaultWaitLimit
        }
        nonmutating set { preferences.set(newValue, forKey: Self.waitLimitKey) }
    }

    /// Whether labelling runs the OpenCode command-line tool instead of calling the provider
    /// over HTTP with a key. Off by default.
    public var usesOpenCodeCLI: Bool {
        get { preferences.bool(forKey: Self.useOpenCodeCLIKey) }
        nonmutating set { preferences.set(newValue, forKey: Self.useOpenCodeCLIKey) }
    }

    /// Consecutive tickets that ended at the wait limit on temporary provider failures.
    public var providerPauseCount: Int { max(0, preferences.integer(forKey: Self.pauseCountKey)) }

    /// When the provider was paused: the third wait-limit stop in a row. Nil while it answers.
    public var providerPausedSince: Date? { preferences.object(forKey: Self.pausedSinceKey) as? Date }

    /// Counts one ticket that ended at the wait limit on a temporary failure; the
    /// third in a row sets the paused-since time to `now`.
    public func recordProviderWaitLimitStop(at now: Date) {
        let count = providerPauseCount + 1
        preferences.set(count, forKey: Self.pauseCountKey)
        if count >= Self.pauseThreshold, providerPausedSince == nil {
            preferences.set(now, forKey: Self.pausedSinceKey)
        }
    }

    /// Clears the count and the paused-since time; any successful labelling request does.
    public func clearProviderPause() {
        preferences.removeObject(forKey: Self.pauseCountKey)
        preferences.removeObject(forKey: Self.pausedSinceKey)
    }

    private static func read(_ key: String, from preferences: UserDefaults) -> [String] {
        let stored = preferences.stringArray(forKey: key) ?? []
        return Set(stored.filter { !$0.isEmpty }).sorted()
    }

    private static func update(_ key: String, feedID: String, present: Bool, in preferences: UserDefaults) {
        guard !feedID.isEmpty else { return }
        var ids = Set(read(key, from: preferences))
        if present { ids.insert(feedID) } else { ids.remove(feedID) }
        if ids.isEmpty {
            preferences.removeObject(forKey: key)
        } else {
            preferences.set(ids.sorted(), forKey: key)
        }
    }
}
