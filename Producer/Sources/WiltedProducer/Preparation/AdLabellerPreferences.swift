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

    static let enabledKey = keyPrefix + "enabled"
    static let confirmedKey = keyPrefix + "confirmedFeedIDs"
    static let shadowKey = keyPrefix + "shadow"
    static let localOnlyKey = keyPrefix + "localOnlyFeedIDs"
    static let modelKey = keyPrefix + "modelID"
    static let levelKey = keyPrefix + "level"
    static let capKey = keyPrefix + "dailyCap"
    static let waitLimitKey = keyPrefix + "waitLimitSeconds"
    static let useOpenCodeCLIKey = keyPrefix + "useOpenCodeCLI"

    public let preferences: UserDefaults

    public init(preferences: UserDefaults) {
        self.preferences = preferences
    }

    /// The global switch. Off by default; while off every feed is labelled locally.
    public var isEnabled: Bool {
        get { preferences.bool(forKey: Self.enabledKey) }
        nonmutating set { preferences.set(newValue, forKey: Self.enabledKey) }
    }

    /// Shadow mode: labels are requested and compared but never applied. On until it is
    /// switched off explicitly, so turning the global switch on can never change audio by itself.
    public var isShadow: Bool {
        get { preferences.object(forKey: Self.shadowKey) == nil || preferences.bool(forKey: Self.shadowKey) }
        nonmutating set { preferences.set(newValue, forKey: Self.shadowKey) }
    }

    /// Feed IDs the owner has confirmed for online labelling, sorted. Empty by default.
    public var confirmedFeedIDs: [String] { Self.read(Self.confirmedKey, from: preferences) }

    /// Feed IDs the owner keeps local regardless of the switch, sorted.
    public var localOnlyFeedIDs: [String] { Self.read(Self.localOnlyKey, from: preferences) }

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

    /// Reserved for the apply phase and read by nothing in the shadow trial: how long an
    /// episode would wait for the provider, in seconds, before its original audio is published
    /// with the reason. The shadow request uses `LabellerClient`'s own fixed time limit.
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
