import Foundation

/// Why a feed's episode is labelled locally instead of by the online provider.
public enum RemoteLabellingLocalReason: String, Sendable, Equatable, CaseIterable {
    case switchOff
    case noKey
    case notConfirmed
    case ownerLocalOnly
    case unknownFeedURL
    case credentialedURL
    case tokenLikeFeedURL
    case privateTitle
    case dailyCapReached
}

/// Where an episode's transcript is labelled.
public enum RemoteLabellingRoute: Sendable, Equatable {
    case remote
    case local(RemoteLabellingLocalReason)
}

/// What the policy knows about one episode. Plain values; nothing is read from the library.
public struct RemoteLabellingInput: Sendable, Equatable {
    public var feedID: String
    public var feedURL: URL?
    public var feedTitle: String
    public var audioURL: URL?

    public init(feedID: String, feedURL: URL?, feedTitle: String, audioURL: URL?) {
        self.feedID = feedID
        self.feedURL = feedURL
        self.feedTitle = feedTitle
        self.audioURL = audioURL
    }
}

/// The owner's state the policy decides against.
public struct RemoteLabellingContext: Sendable, Equatable {
    public var switchOn: Bool
    public var hasKey: Bool
    public var confirmedFeedIDs: Set<String>
    public var localOnlyFeedIDs: Set<String>
    public var dailyCapReached: Bool

    public init(
        switchOn: Bool, hasKey: Bool, confirmedFeedIDs: Set<String>,
        localOnlyFeedIDs: Set<String>, dailyCapReached: Bool
    ) {
        self.switchOn = switchOn
        self.hasKey = hasKey
        self.confirmedFeedIDs = confirmedFeedIDs
        self.localOnlyFeedIDs = localOnlyFeedIDs
        self.dailyCapReached = dailyCapReached
    }

    /// Builds the context from saved preferences and the day's counter.
    public init(preferences: AdLabellerPreferences, hasKey: Bool, counter: LabellerRequestCounter) {
        self.init(
            switchOn: preferences.isEnabled, hasKey: hasKey,
            confirmedFeedIDs: Set(preferences.confirmedFeedIDs),
            localOnlyFeedIDs: Set(preferences.localOnlyFeedIDs),
            dailyCapReached: counter.hasReachedCap
        )
    }
}

/// Pure decision of which route an episode takes. Private or subscriber shows never go remote.
///
/// Rules are checked in this order and the first that holds decides the reason:
/// switchOff, noKey, notConfirmed, ownerLocalOnly, unknownFeedURL, credentialedURL,
/// tokenLikeFeedURL, privateTitle, dailyCapReached. Otherwise the route is remote.
public enum RemoteLabellingPolicy {
    static let credentialQueryKeys: Set<String> = ["token", "auth", "key", "sig", "signature"]
    static let tokenMinimumLength = 24
    static let privateTitlePattern = #"\b(premium|private|subscribers?|patrons?|members?)\b"#

    public static func route(for input: RemoteLabellingInput, context: RemoteLabellingContext) -> RemoteLabellingRoute {
        if !context.switchOn { return .local(.switchOff) }
        if !context.hasKey { return .local(.noKey) }
        if !context.confirmedFeedIDs.contains(input.feedID) { return .local(.notConfirmed) }
        if context.localOnlyFeedIDs.contains(input.feedID) { return .local(.ownerLocalOnly) }
        if let forced = forcedLocalReason(for: input) { return .local(forced) }
        if context.dailyCapReached { return .local(.dailyCapReached) }
        return .remote
    }

    /// The reason this show can never go remote, whatever the owner's switches say:
    /// an unknown, credentialed or token-like address, or a private-sounding title. Nil for a
    /// show the owner may choose to send. Settings and the feed view use it to show
    /// such a show as local before anything is switched on.
    public static func forcedLocalReason(for input: RemoteLabellingInput) -> RemoteLabellingLocalReason? {
        // A feed whose address is unknown cannot be checked, so it stays local.
        guard let feedURL = input.feedURL else { return .unknownFeedURL }
        if isCredentialed(feedURL) { return .credentialedURL }
        if let audioURL = input.audioURL, isCredentialed(audioURL) { return .credentialedURL }
        if hasTokenLikePart(feedURL) { return .tokenLikeFeedURL }
        if hasPrivateWord(input.feedTitle) { return .privateTitle }
        return nil
    }

    /// User info, or a query key named token, auth, key, sig or signature.
    static func isCredentialed(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        if parts.user != nil || parts.password != nil { return true }
        return (parts.queryItems ?? []).contains { credentialQueryKeys.contains($0.name.lowercased()) }
    }

    /// A path segment or query value of 24+ characters, free of hyphen, underscore
    /// and dot, that mixes letters and digits. Slugs and short publisher IDs pass.
    static func hasTokenLikePart(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        var candidates = parts.path.split(separator: "/").map(String.init)
        candidates += (parts.queryItems ?? []).flatMap { [$0.name, $0.value ?? ""] }
        return candidates.contains(where: looksLikeToken)
    }

    private static func looksLikeToken(_ part: String) -> Bool {
        guard part.count >= tokenMinimumLength else { return false }
        if part.contains(where: { $0 == "-" || $0 == "_" || $0 == "." }) { return false }
        return part.contains(where: \.isLetter) && part.contains(where: \.isNumber)
    }

    /// Whole-word, case-insensitive match (singular or plural), so "Remember This" is not a
    /// match for "member" while "Members Only" is.
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
