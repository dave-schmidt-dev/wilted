import Foundation

/// Why a labelled preparation stopped waiting and published the whole original.
public enum LabellerStopReason: Equatable, Sendable {
    case keyRejected
    case modelUnavailable
    case unusableAnswer
    /// The provider kept failing until the owner's wait limit ran out.
    case waitLimit
    /// The day's request cap is reached and midnight is past the wait limit.
    case dailyCap
    /// The provider has failed on enough episodes in a row that this one makes a single attempt.
    case providerPaused(since: Date)

    /// A stable short name for journals; carries no associated data.
    public var kind: String {
        switch self {
        case .keyRejected: "key-rejected"
        case .modelUnavailable: "model-unavailable"
        case .unusableAnswer: "unusable-answer"
        case .waitLimit: "wait-limit"
        case .dailyCap: "daily-cap"
        case .providerPaused: "provider-paused"
        }
    }

    /// The sentence the listener reads. `formatTime` renders the paused-since time.
    public func sentence(formatTime: (Date) -> String) -> String {
        switch self {
        case .keyRejected: "Provider key was rejected. Update it in Settings."
        case .modelUnavailable: "The labelling model is unavailable."
        case .unusableAnswer: "The labelling model's answer could not be used."
        case .waitLimit: "The provider did not answer in time."
        case .dailyCap: "The daily limit for online labelling was reached."
        case .providerPaused(let since):
            "The provider has not answered since \(formatTime(since)). Check the model name in Settings."
        }
    }
}

/// What the retry policy decided for one labelling failure.
public enum LabellerRetryDecision: Equatable, Sendable {
    /// Park the ticket until `until`, for the stated reason.
    case wait(until: Date, reason: WorkTicketDeferralReason)
    /// Publish the whole original with this reason.
    case stop(LabellerStopReason)
}

/// What stopped the labelled path and asks to be waited out or given up on.
public enum LabellerRetryTrigger: Equatable, Sendable {
    case failure(LabellerFailure)
    /// The day's request cap was reached before any request was sent.
    case dailyCap
}

/// Everything the decision depends on. All time is passed in.
public struct LabellerRetryInput: Sendable {
    public var trigger: LabellerRetryTrigger
    /// How many times this request was deferred before; zero for a first failure.
    public var deferralCount: Int
    /// When this request was first deferred; nil before the first deferral.
    public var firstDeferredAt: Date?
    public var now: Date
    /// How long a request may wait, counted from `firstDeferredAt` (or `now` for the first failure).
    public var waitLimit: TimeInterval
    /// When the provider was paused, if it is.
    public var pausedSince: Date?

    public init(
        trigger: LabellerRetryTrigger, deferralCount: Int = 0, firstDeferredAt: Date? = nil,
        now: Date, waitLimit: TimeInterval, pausedSince: Date? = nil
    ) {
        self.trigger = trigger
        self.deferralCount = deferralCount
        self.firstDeferredAt = firstDeferredAt
        self.now = now
        self.waitLimit = waitLimit
        self.pausedSince = pausedSince
    }
}

/// Pure decision: wait for the provider, or give up and keep the original.
public enum LabellerRetryPolicy {
    /// Minutes to wait after the first, second, third and fourth failure of one request.
    /// Every later failure waits `repeatingBackoffMinutes`.
    public static let backoffMinutes = [2, 5, 15, 30]
    public static let repeatingBackoffMinutes = 60

    /// Decides what a failure leads to. `calendar` finds the next local midnight for the daily cap.
    public static func decide(_ input: LabellerRetryInput, calendar: Calendar = .current) -> LabellerRetryDecision {
        let reason: WorkTicketDeferralReason
        let proposed: Date
        switch input.trigger {
        case .failure(.keyRejected): return .stop(.keyRejected)
        case .failure(.modelUnavailable): return .stop(.modelUnavailable)
        case .failure(.unusableAnswer): return .stop(.unusableAnswer)
        case .failure(.temporary):
            if let pausedSince = input.pausedSince { return .stop(.providerPaused(since: pausedSince)) }
            reason = .providerUnavailable
            proposed = backoff(input)
        case .failure(.rateLimited(let retryAfter)):
            reason = .providerRateLimited
            if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
                proposed = input.now.addingTimeInterval(retryAfter)
            } else {
                proposed = backoff(input)
            }
        case .failure(.usageLimit):
            reason = .providerUsageLimit
            proposed = backoff(input)
        case .dailyCap:
            guard let midnight = calendar.nextDate(
                after: input.now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) else { return .stop(.dailyCap) }
            guard midnight <= deadline(input) else { return .stop(.dailyCap) }
            return .wait(until: midnight, reason: .dailyRequestCap)
        }
        guard proposed <= deadline(input) else { return .stop(.waitLimit) }
        return .wait(until: proposed, reason: reason)
    }

    private static func deadline(_ input: LabellerRetryInput) -> Date {
        (input.firstDeferredAt ?? input.now).addingTimeInterval(input.waitLimit)
    }

    private static func backoff(_ input: LabellerRetryInput) -> Date {
        let steps = backoffMinutes
        let minutes = steps.indices.contains(input.deferralCount)
            ? steps[input.deferralCount] : repeatingBackoffMinutes
        return input.now.addingTimeInterval(TimeInterval(minutes) * 60)
    }
}
