import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

/// Pure wording for labelling waits: published detail, Mac row, and stamp lines.
final class WiltedMacLabellerWaitTests: XCTestCase {
    private let retry = Date(timeIntervalSince1970: 1_700_000_000)
    private let formatTime: (Date) -> String = { _ in "9:41 AM" }
    private let longTime: (Date) -> String = { _ in
        String(repeating: "x", count: 80) + " AM"
    }

    private let providerReasons: [WorkTicketDeferralReason] = [
        .providerRateLimited, .providerUnavailable, .providerUsageLimit
    ]

    func testProviderWaitsCarryTimeAndCountInPublishedDetailAndStamp() {
        for reason in providerReasons {
            for count in [0, 1, 4] {
                let detail = WiltedMacLabellerWait.publishedDetail(
                    reason: reason, retryAt: retry, waitCount: count, formatTime: formatTime)
                XCTAssertTrue(detail.hasPrefix("Ad removal is waiting on the provider. Retrying at 9:41 AM."),
                              "\(reason) count \(count): \(detail)")
                switch count {
                case 0: XCTAssertFalse(detail.contains("Tried"))
                case 1: XCTAssertTrue(detail.hasSuffix(" Tried once so far."))
                default: XCTAssertTrue(detail.hasSuffix(" Tried \(count) times so far."))
                }
                XCTAssertLessThanOrEqual(detail.utf8.count, LibraryPreparationStatus.maximumDetailBytes)

                let wait = LabellingWait(
                    state: .deferred, failureKind: reason.rawValue,
                    nextEligibleAt: Timestamp(retry), deferralCount: count
                )!
                let stamp = WiltedMacPreparationStamp.make(
                    outcome: nil, readyRevisionID: nil, runs: [],
                    labellingWait: wait, formatTime: formatTime
                )
                XCTAssertEqual(stamp?.labellingWait, detail)
                XCTAssertEqual(stamp?.phoneNote, WiltedMacLabellerWait.phoneNote)
                XCTAssertEqual(
                    stamp?.displayText,
                    detail + "\n" + WiltedMacLabellerWait.phoneNote
                )
            }
        }
    }

    func testDailyCapWaitOmitsCountAndUsesItsOwnSentence() {
        for count in [0, 1, 9] {
            let detail = WiltedMacLabellerWait.publishedDetail(
                reason: .dailyRequestCap, retryAt: retry, waitCount: count, formatTime: formatTime)
            XCTAssertEqual(
                detail,
                "Ad removal reached today's limit for online labelling. Retrying at 9:41 AM."
            )
            XCTAssertFalse(detail.contains("Tried"))
        }
    }

    func testPublishedDetailStaysWithinByteLimitForLongLocaleTime() {
        let detail = WiltedMacLabellerWait.publishedDetail(
            reason: .providerUnavailable, retryAt: retry, waitCount: 12, formatTime: longTime)
        XCTAssertLessThanOrEqual(detail.utf8.count, LibraryPreparationStatus.maximumDetailBytes)
        XCTAssertTrue(detail.contains("Ad removal is waiting on the provider."))
    }

    func testRowLabelsStayShortAndDistinctByReason() {
        XCTAssertEqual(
            WiltedMacLabellerWait.rowLabel(
                reason: .providerRateLimited, retryAt: retry, formatTime: formatTime),
            "Waiting on the provider · retrying 9:41 AM"
        )
        XCTAssertEqual(
            WiltedMacLabellerWait.rowLabel(
                reason: .dailyRequestCap, retryAt: retry, formatTime: formatTime),
            "Reached today's labelling limit · retrying 9:41 AM"
        )
    }

    func testPublicationMapsLabellingDeferralToWaitingAndOffPeakStaysQueued() throws {
        let now = Timestamp(retry)
        let wait = LabellingWait(
            state: .deferred, failureKind: WorkTicketDeferralReason.providerUsageLimit.rawValue,
            nextEligibleAt: now, deferralCount: 1
        )!
        let waiting = try XCTUnwrap(WiltedMacPreparationPublication.status(
            .init(requestSequence: 4, attemptCount: 2, state: .deferred, updatedAt: now,
                  labellingWait: wait),
            formatTime: formatTime
        ))
        XCTAssertEqual(waiting.state, .waiting)
        XCTAssertEqual(waiting.stage, "ads.label.wait")
        XCTAssertEqual(waiting.attemptID, "generation-4-2")
        XCTAssertEqual(
            waiting.detail,
            "Ad removal is waiting on the provider. Retrying at 9:41 AM. Tried once so far."
        )
        XCTAssertFalse(waiting.detail.contains(WiltedMacLabellerWait.phoneNote))

        let offPeak = try XCTUnwrap(WiltedMacPreparationPublication.status(
            .init(requestSequence: 4, attemptCount: 2, state: .deferred, updatedAt: now)
        ))
        XCTAssertEqual(offPeak.state, .queued)
        XCTAssertEqual(offPeak.detail, "Waiting to prepare.")
    }

    func testOffPeakDeferralShowsNoWaitingStamp() {
        let stamp = WiltedMacPreparationStamp.make(
            outcome: nil, readyRevisionID: nil, runs: [], labellingWait: nil)
        XCTAssertNil(stamp)
    }

    @MainActor
    func testStaleOrNonDeferredTicketShowsNoWaitingStampLines() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "b", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let when = Timestamp(retry)
        let staleWait = PreparationJournalEntry(
            id: requestID + "|wait", itemID: itemID, requestID: requestID,
            status: try PreparationStatus(
                stage: .assembling, detail: "old wait", cancellable: true,
                emittedAt: when, step: "ads.label.wait"))
        let run = PreparationRunSummary(
            requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when,
            stage: .assembling, detail: "old wait", fraction: nil, isTerminal: false,
            outcome: nil, failure: nil, entries: [staleWait])
        let stamp = WiltedMacPreparationStamp.make(
            outcome: nil, readyRevisionID: nil, runs: [run], labellingWait: nil)
        XCTAssertNil(stamp?.labellingWait)
        XCTAssertNil(stamp?.phoneNote)
        XCTAssertNil(stamp)
    }
}
