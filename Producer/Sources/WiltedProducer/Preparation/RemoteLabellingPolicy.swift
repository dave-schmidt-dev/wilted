import Foundation

/// Why a feed's episode is not sent to the online provider.
public enum RemoteLabellingNotSentReason: String, Sendable, Equatable, CaseIterable {
    case switchOff
    case noKey
    case notConfirmed
    case adRemovalOff
    case dailyCapReached
}

/// Why an episode with ad removal on is not sent for ad finding. Its original audio is
/// kept whole, and the warning, the journal and the app all say why in one fixed sentence.
public enum RemoteLabellingNotSent: String, Sendable, Equatable, CaseIterable {
    case switchOff = "switch-off"
    case noKey = "no-key"
    case notConfirmed = "not-confirmed"

    /// The warning reason for a not-sent route. Nil for ad removal off and the daily cap.
    public init?(_ reason: RemoteLabellingNotSentReason) {
        switch reason {
        case .switchOff: self = .switchOff
        case .noKey: self = .noKey
        case .notConfirmed: self = .notConfirmed
        case .adRemovalOff, .dailyCapReached: return nil
        }
    }

    /// The journal evidence kind, for example `not-sent-switch-off`.
    public var kind: String { "not-sent-\(rawValue)" }

    /// Why the episode keeps its ads.
    public var sentence: String {
        switch self {
        case .switchOff: "Online ad finding is off."
        case .noKey: "The chosen provider is not ready: it needs a saved key or a model."
        case .notConfirmed: "This show is not sent for ad finding. Turn it on in the show's settings."
        }
    }

    /// The durable warning a not-sent episode carries.
    public var warning: String { "original audio includes ads: \(sentence)" }
}

/// Where an episode's transcript is labelled.
public enum RemoteLabellingRoute: Sendable, Equatable {
    case remote
    case notSent(RemoteLabellingNotSentReason)
}

/// The values the routing policy needs for one episode.
public struct RemoteLabellingInput: Sendable, Equatable {
    public var feedID: String
    /// Whether this episode was admitted with ad removal on. Off means nothing is sent.
    public var removeAds: Bool

    public init(feedID: String, removeAds: Bool = true) {
        self.feedID = feedID
        self.removeAds = removeAds
    }
}

/// The owner's state the policy decides against.
public struct RemoteLabellingContext: Sendable, Equatable {
    public var switchOn: Bool
    public var hasKey: Bool
    public var confirmedFeedIDs: Set<String>
    public var adFreeFeedIDs: Set<String>
    public var dailyCapReached: Bool

    public init(
        switchOn: Bool, hasKey: Bool, confirmedFeedIDs: Set<String>,
        adFreeFeedIDs: Set<String> = [], dailyCapReached: Bool
    ) {
        self.switchOn = switchOn
        self.hasKey = hasKey
        self.confirmedFeedIDs = confirmedFeedIDs
        self.adFreeFeedIDs = adFreeFeedIDs
        self.dailyCapReached = dailyCapReached
    }

    /// Builds the context from saved preferences and the day's counter.
    public init(preferences: AdLabellerPreferences, hasKey: Bool, counter: LabellerRequestCounter) {
        self.init(
            switchOn: preferences.isEnabled, hasKey: hasKey,
            confirmedFeedIDs: Set(preferences.confirmedFeedIDs),
            adFreeFeedIDs: Set(preferences.adFreeFeedIDs),
            dailyCapReached: counter.hasReachedCap
        )
    }
}

/// Pure decision of which route an episode takes.
///
/// Rules are checked in this order and the first that holds decides the reason:
/// adRemovalOff (ad removal off or an ad-free feed), switchOff, noKey,
/// notConfirmed, dailyCapReached. Otherwise the route is remote.
public enum RemoteLabellingPolicy {
    public static func route(for input: RemoteLabellingInput, context: RemoteLabellingContext) -> RemoteLabellingRoute {
        if !input.removeAds || context.adFreeFeedIDs.contains(input.feedID) { return .notSent(.adRemovalOff) }
        if !context.switchOn { return .notSent(.switchOff) }
        if !context.hasKey { return .notSent(.noKey) }
        if !context.confirmedFeedIDs.contains(input.feedID) { return .notSent(.notConfirmed) }
        if context.dailyCapReached { return .notSent(.dailyCapReached) }
        return .remote
    }
}

/// Counts HTTP requests sent to the provider per local day, held in `UserDefaults`.
/// The count resets when the local day changes; the day is stored beside the count.
// `UserDefaults` is documented as thread-safe but is not annotated `Sendable`.
public struct LabellerRequestCounter: @unchecked Sendable {
    static let countKey = AdLabellerPreferences.keyPrefix + "requestCount"
    static let dayKey = AdLabellerPreferences.keyPrefix + "requestDay"

    public let preferences: UserDefaults
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(preferences: UserDefaults, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current) {
        self.preferences = preferences
        self.now = now
        self.calendar = calendar
    }

    /// Requests recorded today; zero if the stored day is not today.
    public var count: Int {
        guard preferences.string(forKey: Self.dayKey) == todayKey else { return 0 }
        return max(0, preferences.integer(forKey: Self.countKey))
    }

    /// The daily cap from `AdLabellerPreferences` (default 60).
    public var cap: Int { AdLabellerPreferences(preferences: preferences).dailyCap }

    public var hasReachedCap: Bool { count >= cap }

    /// Adds one request for the current local day.
    public func record() {
        let current = count
        preferences.set(todayKey, forKey: Self.dayKey)
        preferences.set(current + 1, forKey: Self.countKey)
    }

    private var todayKey: String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
