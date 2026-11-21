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
    static let localOnlyKey = keyPrefix + "localOnlyFeedIDs"
    static let providerKey = keyPrefix + "provider"
    static let modelKey = keyPrefix + "modelID"
    static let levelKey = keyPrefix + "level"
    static let providerModelKeyPrefix = keyPrefix + "providerModel."
    static let providerLevelKeyPrefix = keyPrefix + "providerLevel."
    static let capKey = keyPrefix + "dailyCap"
    static let waitLimitKey = keyPrefix + "waitLimitSeconds"
    static let useOpenCodeCLIKey = keyPrefix + "useOpenCodeCLI"
    static let acknowledgedProvidersKey = keyPrefix + "acknowledgedProviders"
    static let pauseCountKey = keyPrefix + "providerPauseCount"
    static let pausedSinceKey = keyPrefix + "providerPausedSince"
    /// Consecutive wait-limit stops on temporary failures after which the provider counts as paused.
    public static let pauseThreshold = 3

    public let preferences: UserDefaults

    public init(preferences: UserDefaults) {
        self.preferences = preferences
    }

    /// The chosen provider.
    ///
    /// Migrates on read from `useOpenCodeCLI` if `provider` is not explicitly set.
    /// Defaults to OpenCode Go (`opencodeGoKey`) when no preference exists, or `openCodeCLI` if `useOpenCodeCLI` is true.
    public var provider: AdLabellerProvider {
        get {
            if let stored = preferences.string(forKey: Self.providerKey),
               let parsed = AdLabellerProvider(rawValue: stored) {
                return parsed
            }
            if preferences.object(forKey: Self.useOpenCodeCLIKey) != nil {
                return preferences.bool(forKey: Self.useOpenCodeCLIKey) ? .openCodeCLI : .opencodeGoKey
            }
            return .opencodeGoKey
        }
        nonmutating set {
            preferences.set(newValue.rawValue, forKey: Self.providerKey)
            preferences.set(newValue == .openCodeCLI, forKey: Self.useOpenCodeCLIKey)
        }
    }

    /// The global switch. Off by default; while off nothing is sent.
    public var isEnabled: Bool {
        get { preferences.bool(forKey: Self.enabledKey) }
        nonmutating set { preferences.set(newValue, forKey: Self.enabledKey) }
    }

    /// Feed IDs the owner has confirmed for online labelling, sorted. Empty by default.
    /// Excludes any feed the owner kept back.
    public var confirmedFeedIDs: [String] {
        let confirmed = Set(Self.read(Self.confirmedKey, from: preferences))
        return confirmed.subtracting(keptBackFeedIDs).sorted()
    }

    /// Feed IDs the owner turned off or left unsent in a confirm sheet, sorted. The stored
    /// key is the older "Mac only" list, so a show kept back under that switch is here too.
    /// They read as not confirmed, and no confirm sheet may offer them as sent by default;
    /// ``setConfirmed(feedID:_:)`` with true is the only thing that removes one.
    public var keptBackFeedIDs: [String] { Self.read(Self.localOnlyKey, from: preferences) }

    /// Feed IDs the owner marked as already ad-free, sorted. Read-only here; the Mac preference writes them.
    public var adFreeFeedIDs: [String] { Self.read(Self.adFreeFeedsKey, from: preferences) }

    public func isConfirmed(feedID: String) -> Bool { confirmedFeedIDs.contains(feedID) }

    public func setConfirmed(feedID: String, _ confirmed: Bool) {
        Self.update(Self.confirmedKey, feedID: feedID, present: confirmed, in: preferences)
        if confirmed {
            Self.update(Self.localOnlyKey, feedID: feedID, present: false, in: preferences)
        }
    }

    /// The owner's own "do not send" for a show: not confirmed, and remembered so a later
    /// confirm sheet neither counts it as waiting nor offers it as sent by default.
    public func keepBack(feedID: String) {
        Self.update(Self.confirmedKey, feedID: feedID, present: false, in: preferences)
        Self.update(Self.localOnlyKey, feedID: feedID, present: true, in: preferences)
    }

    /// The provider model ID for the chosen provider.
    public var modelID: String {
        get { modelID(for: provider) }
        nonmutating set { setModelID(newValue, for: provider) }
    }

    /// The labelling level for the chosen provider.
    public var level: String {
        get { level(for: provider) }
        nonmutating set { setLevel(newValue, for: provider) }
    }

    /// The model ID for a specific provider.
    public func modelID(for provider: AdLabellerProvider) -> String {
        let providerKey = Self.providerModelKeyPrefix + provider.rawValue
        if let stored = preferences.string(forKey: providerKey), !stored.isEmpty {
            return stored
        }
        if provider == .opencodeGoKey || provider == .openCodeCLI {
            if let legacy = preferences.string(forKey: Self.modelKey), !legacy.isEmpty {
                return legacy
            }
        }
        if let firstModel = AdLabellerModelCatalog.modelsByProvider[provider]?.first?.id {
            return firstModel
        }
        return ""
    }

    /// Saves the model ID for a specific provider.
    public func setModelID(_ modelID: String, for provider: AdLabellerProvider) {
        let providerKey = Self.providerModelKeyPrefix + provider.rawValue
        preferences.set(modelID, forKey: providerKey)
    }

    /// The thinking level for a specific provider.
    public func level(for provider: AdLabellerProvider) -> String {
        let providerKey = Self.providerLevelKeyPrefix + provider.rawValue
        if let stored = preferences.string(forKey: providerKey), !stored.isEmpty {
            return stored
        }
        if provider == .opencodeGoKey || provider == .openCodeCLI {
            if let legacy = preferences.string(forKey: Self.levelKey), !legacy.isEmpty {
                return legacy
            }
        }
        let model = modelID(for: provider)
        if model.isEmpty {
            return "low"
        }
        let knownModels = AdLabellerModelCatalog.modelsByProvider[provider] ?? []
        if let match = knownModels.first(where: { $0.id == model }) {
            if match.supportedLevels.contains("low") {
                return "low"
            }
            if let firstSupported = match.supportedLevels.first {
                return firstSupported
            }
        }
        return "low"
    }

    /// Saves the thinking level for a specific provider.
    public func setLevel(_ level: String, for provider: AdLabellerProvider) {
        let providerKey = Self.providerLevelKeyPrefix + provider.rawValue
        preferences.set(level, forKey: providerKey)
    }

    /// Whether the chosen provider's model and level choice is valid.
    public var hasValidChoice: Bool {
        AdLabellerModelCatalog.isValid(provider: provider, model: modelID, level: level)
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
    /// published with the reason.
    public var waitLimit: TimeInterval {
        get {
            guard preferences.object(forKey: Self.waitLimitKey) != nil else { return Self.defaultWaitLimit }
            let stored = preferences.double(forKey: Self.waitLimitKey)
            return stored > 0 ? stored : Self.defaultWaitLimit
        }
        nonmutating set { preferences.set(newValue, forKey: Self.waitLimitKey) }
    }

    /// Whether labelling runs the OpenCode command-line tool instead of calling the provider
    /// over HTTP with a key. Derived from `provider`.
    public var usesOpenCodeCLI: Bool {
        get { provider == .openCodeCLI }
        nonmutating set { provider = newValue ? .openCodeCLI : .opencodeGoKey }
    }

    /// Consecutive tickets that ended at the wait limit on temporary provider failures.
    public var providerPauseCount: Int { max(0, preferences.integer(forKey: Self.pauseCountKey)) }

    /// Whether the owner has acknowledged the privacy note for this provider.
    /// Providers that do not require acknowledgement always read as acknowledged.
    public func isAcknowledged(_ provider: AdLabellerProvider) -> Bool {
        guard provider.requiresAcknowledgement else { return true }
        let acknowledged = Set(preferences.stringArray(forKey: Self.acknowledgedProvidersKey) ?? [])
        return acknowledged.contains(provider.rawValue)
    }

    /// Records acknowledgement of the privacy note for this provider.
    public func acknowledge(_ provider: AdLabellerProvider) {
        var acknowledged = Set((preferences.stringArray(forKey: Self.acknowledgedProvidersKey) ?? []).filter { !$0.isEmpty })
        acknowledged.insert(provider.rawValue)
        preferences.set(acknowledged.sorted(), forKey: Self.acknowledgedProvidersKey)
    }

    /// Revokes acknowledgement of the privacy note for this provider.
    public func revokeAcknowledgement(_ provider: AdLabellerProvider) {
        var acknowledged = Set((preferences.stringArray(forKey: Self.acknowledgedProvidersKey) ?? []).filter { !$0.isEmpty })
        acknowledged.remove(provider.rawValue)
        if acknowledged.isEmpty {
            preferences.removeObject(forKey: Self.acknowledgedProvidersKey)
        } else {
            preferences.set(acknowledged.sorted(), forKey: Self.acknowledgedProvidersKey)
        }
    }

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
