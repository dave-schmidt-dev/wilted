import Foundation

/// Why a feed's episode is not sent to the online provider. ``RemoteLabellingNotSent``
/// says what each reason means for an episode with ad removal on.
public enum RemoteLabellingNotSentReason: String, Sendable, Equatable, CaseIterable {
    case switchOff
    case noKey
    case notConfirmed
    case adRemovalOff
    case unknownFeedURL
    case credentialedURL
    case tokenLikeFeedURL
    case privateTitle
    case dailyCapReached
}

/// Why an episode with ad removal on is not sent for ad finding. Its original audio is
/// kept whole, and the warning, the journal and the app all say why in one fixed sentence.
public enum RemoteLabellingNotSent: String, Sendable, Equatable, CaseIterable {
    case unknownAddress = "unknown-address"
    case signInDetails = "sign-in-details"
    case privateToken = "private-token"
    case privateTitle = "private-title"
    case switchOff = "switch-off"
    case noKey = "no-key"
    case notConfirmed = "not-confirmed"

    /// The not-sent reason for a not-sent route. Nil for ad removal off, which has nothing to
    /// find, and for the daily cap, which stays on the labelled path.
    public init?(_ reason: RemoteLabellingNotSentReason) {
        switch reason {
        case .unknownFeedURL: self = .unknownAddress
        case .credentialedURL: self = .signInDetails
        case .tokenLikeFeedURL: self = .privateToken
        case .privateTitle: self = .privateTitle
        case .switchOff: self = .switchOff
        case .noKey: self = .noKey
        case .notConfirmed: self = .notConfirmed
        case .adRemovalOff, .dailyCapReached: return nil
        }
    }

    /// The journal evidence kind, for example `not-sent-switch-off`.
    public var kind: String { "not-sent-\(rawValue)" }

    /// Why the episode keeps its ads. Fixed text: it names no address, title or transcript.
    public var sentence: String {
        switch self {
        case .unknownAddress: "This show's address is not known, so it is never sent for ad finding."
        case .signInDetails: "This show's address carries sign-in details, so it is never sent for ad finding."
        case .privateToken: "This show's address carries a private token, so it is never sent for ad finding."
        case .privateTitle: "This show's title sounds private, so it is never sent for ad finding."
        case .switchOff: "Online ad finding is off."
        case .noKey: "The chosen provider has no key saved."
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

/// What the policy knows about one episode. Plain values; nothing is read from the library.
public struct RemoteLabellingInput: Sendable, Equatable {
    public var feedID: String
    public var feedURL: URL?
    /// The publisher's title.
    public var feedTitle: String
    /// The owner's own name for the show, when they renamed it. Checked like the title;
    /// never sent anywhere.
    public var customTitle: String?
    public var audioURL: URL?
    /// Whether this episode was admitted with ad removal on. Off means nothing is sent.
    public var removeAds: Bool

    public init(
        feedID: String, feedURL: URL?, feedTitle: String, customTitle: String? = nil,
        audioURL: URL?, removeAds: Bool = true
    ) {
        self.feedID = feedID
        self.feedURL = feedURL
        self.feedTitle = feedTitle
        self.customTitle = customTitle
        self.audioURL = audioURL
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

/// Pure decision of which route an episode takes. Private or subscriber shows never go remote.
///
/// Rules are checked in this order and the first that holds decides the reason:
/// adRemovalOff (ad removal off or an ad-free feed), unknownFeedURL, credentialedURL,
/// tokenLikeFeedURL, privateTitle, switchOff, noKey, notConfirmed,
/// dailyCapReached. Otherwise the route is remote, so remote still needs every check to pass.
/// A private show names its private reason whatever the owner's switches say.
public enum RemoteLabellingPolicy {
    static let credentialQueryKeys: Set<String> = ["token", "auth", "key", "sig", "signature"]
    static let tokenMinimumLength = 24
    /// A path segment or query value this long is treated as a token whatever it contains.
    static let longPartLength = 64
    static let privateTitlePattern = #"\b(premium|private|subscribers?|patrons?|members?|plus|ad[- ]free)\b"#

    public static func route(for input: RemoteLabellingInput, context: RemoteLabellingContext) -> RemoteLabellingRoute {
        if !input.removeAds || context.adFreeFeedIDs.contains(input.feedID) { return .notSent(.adRemovalOff) }
        if let forced = forcedNotSentReason(for: input) { return .notSent(forced) }
        if !context.switchOn { return .notSent(.switchOff) }
        if !context.hasKey { return .notSent(.noKey) }
        if !context.confirmedFeedIDs.contains(input.feedID) { return .notSent(.notConfirmed) }
        if context.dailyCapReached { return .notSent(.dailyCapReached) }
        return .remote
    }

    /// The reason this show can never go remote, whatever the owner's switches say:
    /// an unknown, credentialed or token-like address, or a private-sounding title. Nil for a
    /// show the owner may choose to send. Settings and the feed view use it to show
    /// such a show as not sent before anything is switched on.
    public static func forcedNotSentReason(for input: RemoteLabellingInput) -> RemoteLabellingNotSentReason? {
        // A feed whose address is unknown cannot be checked, so it stays not sent.
        guard let feedURL = input.feedURL else { return .unknownFeedURL }
        if isCredentialed(feedURL) { return .credentialedURL }
        if let audioURL = input.audioURL, isCredentialed(audioURL) { return .credentialedURL }
        if hasTokenLikePart(feedURL) { return .tokenLikeFeedURL }
        // Either name can mark a paid feed: a rename must neither hide the publisher's
        // word nor be ignored when the owner adds one.
        if hasPrivateWord(input.feedTitle) || hasPrivateWord(input.customTitle ?? "") { return .privateTitle }
        return nil
    }

    /// User info, or a query key named token, auth, key, sig or signature.
    static func isCredentialed(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        if parts.user != nil || parts.password != nil { return true }
        return (parts.queryItems ?? []).contains { credentialQueryKeys.contains($0.name.lowercased()) }
    }

    /// A path segment or query value that is 64+ characters long, or that has a run of 24+
    /// characters between hyphens, underscores and dots mixing letters and digits. Separators
    /// do not hide a token: subscriber feed tokens are often base64url or dotted. Slugs made
    /// of short words and short publisher IDs pass.
    static func hasTokenLikePart(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        var candidates = parts.path.split(separator: "/").map(String.init)
        candidates += (parts.queryItems ?? []).flatMap { [$0.name, $0.value ?? ""] }
        return candidates.contains(where: looksLikeToken)
    }

    private static func looksLikeToken(_ part: String) -> Bool {
        if part.count >= longPartLength { return true }
        return part.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).contains { run in
            run.count >= tokenMinimumLength && run.contains(where: \.isLetter) && run.contains(where: \.isNumber)
        }
    }

    /// Whole-word, case-insensitive match (singular or plural), so "Remember This" is not a
    /// match for "member" while "Members Only" is. "Plus" and "ad-free" name paid feeds.
    static func hasPrivateWord(_ title: String) -> Bool {
        title.range(of: privateTitlePattern, options: [.regularExpression, .caseInsensitive]) != nil
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
