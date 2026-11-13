import Foundation
import Testing
@testable import WiltedProducer

@Suite("Labeller retry policy")
struct LabellerRetryPolicyTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let longLimit: TimeInterval = 100 * 3_600

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func decide(
        _ trigger: LabellerRetryTrigger, count: Int = 0, firstDeferredAt: Date? = nil,
        waitLimit: TimeInterval = longLimit, pausedSince: Date? = nil, now: Date = now
    ) -> LabellerRetryDecision {
        LabellerRetryPolicy.decide(
            LabellerRetryInput(
                trigger: trigger, deferralCount: count, firstDeferredAt: firstDeferredAt, now: now,
                waitLimit: waitLimit, pausedSince: pausedSince),
            calendar: Self.utc)
    }

    @Test func retryAfterIsHonouredWhenGiven() {
        #expect(decide(.failure(.rateLimited(retryAfter: 90)), count: 3)
            == .wait(until: Self.now.addingTimeInterval(90), reason: .providerRateLimited))
    }

    @Test func rateLimitedWithoutAUsableRetryAfterBacksOff() {
        for retryAfter in [nil, 0, -5, Double.infinity] as [TimeInterval?] {
            #expect(decide(.failure(.rateLimited(retryAfter: retryAfter)), count: 1)
                == .wait(until: Self.now.addingTimeInterval(5 * 60), reason: .providerRateLimited))
        }
    }

    @Test(arguments: [
        (LabellerFailure.temporary, WorkTicketDeferralReason.providerUnavailable),
        (LabellerFailure.usageLimit, WorkTicketDeferralReason.providerUsageLimit),
        (LabellerFailure.rateLimited(retryAfter: nil), WorkTicketDeferralReason.providerRateLimited),
    ])
    func backOffStepsByEarlierDeferrals(failure: LabellerFailure, reason: WorkTicketDeferralReason) {
        let minutes = [2, 5, 15, 30, 60, 60, 60]
        for (count, expected) in minutes.enumerated() {
            #expect(decide(.failure(failure), count: count)
                == .wait(until: Self.now.addingTimeInterval(TimeInterval(expected) * 60), reason: reason),
                "deferral \(count)")
        }
    }

    @Test func waitLimitIsMeasuredFromTheFirstDeferral() {
        let first = Self.now.addingTimeInterval(-100 * 60)
        let limit: TimeInterval = 2 * 3_600
        // 100 minutes in: 15 more is inside two hours, 30 more is not.
        #expect(decide(.failure(.temporary), count: 2, firstDeferredAt: first, waitLimit: limit)
            == .wait(until: Self.now.addingTimeInterval(15 * 60), reason: .providerUnavailable))
        #expect(decide(.failure(.temporary), count: 3, firstDeferredAt: first, waitLimit: limit)
            == .stop(.waitLimit))
        #expect(decide(.failure(.rateLimited(retryAfter: 3_600)), count: 1, firstDeferredAt: first, waitLimit: limit)
            == .stop(.waitLimit))
        #expect(decide(.failure(.usageLimit), count: 5, firstDeferredAt: first, waitLimit: limit)
            == .stop(.waitLimit))
    }

    @Test func aFirstFailureMeasuresFromNow() {
        #expect(decide(.failure(.temporary), waitLimit: 120)
            == .wait(until: Self.now.addingTimeInterval(120), reason: .providerUnavailable))
        #expect(decide(.failure(.temporary), waitLimit: 119) == .stop(.waitLimit))
    }

    @Test func failuresThatCannotImproveStopAtOnce() {
        #expect(decide(.failure(.keyRejected)) == .stop(.keyRejected))
        #expect(decide(.failure(.modelUnavailable), count: 2) == .stop(.modelUnavailable))
        #expect(decide(.failure(.unusableAnswer)) == .stop(.unusableAnswer))
    }

    @Test func dailyCapWaitsForTheNextLocalMidnightWhenInsideTheWaitLimit() throws {
        let evening = try #require(Self.utc.date(from: DateComponents(
            year: 2023, month: 11, day: 14, hour: 22, minute: 0)))
        let midnight = try #require(Self.utc.date(from: DateComponents(year: 2023, month: 11, day: 15)))
        #expect(decide(.dailyCap, waitLimit: 3 * 3_600, now: evening)
            == .wait(until: midnight, reason: .dailyRequestCap))
        #expect(decide(.dailyCap, waitLimit: 2 * 3_600, now: evening)
            == .wait(until: midnight, reason: .dailyRequestCap), "exactly at the limit still waits")
        #expect(decide(.dailyCap, waitLimit: 3_600, now: evening) == .stop(.dailyCap))
        // Counted from the first deferral, not from this attempt.
        #expect(decide(.dailyCap, count: 1, firstDeferredAt: evening.addingTimeInterval(-3_600),
                       waitLimit: 3 * 3_600, now: evening) == .wait(until: midnight, reason: .dailyRequestCap))
        #expect(decide(.dailyCap, count: 1, firstDeferredAt: evening.addingTimeInterval(-3_600),
                       waitLimit: 2 * 3_600, now: evening) == .stop(.dailyCap))
    }

    @Test func aPausedProviderStopsATemporaryFailureWithoutWaiting() {
        let since = Self.now.addingTimeInterval(-3_600)
        #expect(decide(.failure(.temporary), pausedSince: since) == .stop(.providerPaused(since: since)))
        // Pausing concerns an unanswered provider, not one that answered "slow down".
        #expect(decide(.failure(.rateLimited(retryAfter: 30)), pausedSince: since)
            == .wait(until: Self.now.addingTimeInterval(30), reason: .providerRateLimited))
    }

    @Test func stopReasonsHaveStableKindsAndPlainSentences() {
        let since = Self.now
        let sentence = { (reason: LabellerStopReason) in reason.sentence(formatTime: { _ in "9:41 AM" }) }
        #expect(LabellerStopReason.keyRejected.kind == "key-rejected")
        #expect(sentence(.keyRejected) == "Provider key was rejected. Update it in Settings.")
        #expect(LabellerStopReason.modelUnavailable.kind == "model-unavailable")
        #expect(sentence(.modelUnavailable) == "The labelling model is unavailable.")
        #expect(LabellerStopReason.unusableAnswer.kind == "unusable-answer")
        #expect(!sentence(.unusableAnswer).isEmpty)
        #expect(LabellerStopReason.waitLimit.kind == "wait-limit")
        #expect(sentence(.waitLimit) == "The provider did not answer in time.")
        #expect(LabellerStopReason.dailyCap.kind == "daily-cap")
        #expect(!sentence(.dailyCap).isEmpty)
        #expect(LabellerStopReason.providerPaused(since: since).kind == "provider-paused")
        #expect(sentence(.providerPaused(since: since))
            == "The provider has not answered since 9:41 AM. Check the model name in Settings.")
    }

    @Test func providerPauseStartsAtTheThirdWaitLimitStopAndClearsTogether() {
        let name = "LabellerRetryPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AdLabellerPreferences(preferences: defaults)
        #expect(preferences.providerPauseCount == 0)
        #expect(preferences.providerPausedSince == nil)
        preferences.recordProviderWaitLimitStop(at: Self.now)
        preferences.recordProviderWaitLimitStop(at: Self.now)
        #expect(preferences.providerPauseCount == 2)
        #expect(preferences.providerPausedSince == nil)
        preferences.recordProviderWaitLimitStop(at: Self.now)
        #expect(preferences.providerPausedSince == Self.now)
        preferences.recordProviderWaitLimitStop(at: Self.now.addingTimeInterval(60))
        #expect(preferences.providerPausedSince == Self.now, "the paused-since time is the first one")
        preferences.clearProviderPause()
        #expect(preferences.providerPauseCount == 0)
        #expect(preferences.providerPausedSince == nil)
    }
}
