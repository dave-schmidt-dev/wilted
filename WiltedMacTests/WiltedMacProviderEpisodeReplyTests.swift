import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

final class WiltedMacProviderEpisodeReplyTests: XCTestCase {
    func testLatestActualReplyIsSeparatedByProviderAndIncludesCounts() throws {
        let first = try run(
            id: "first", provider: .openAIKey, model: "gpt-4o",
            at: Date(timeIntervalSince1970: 1_700_000_000), result: (2, 0)
        )
        let otherProvider = try run(
            id: "other", provider: .anthropicKey, model: "claude-sonnet-5-5",
            at: Date(timeIntervalSince1970: 1_700_000_030), result: (0, 0)
        )
        let latest = try run(
            id: "latest", provider: .openAIKey, model: "gpt-4o",
            at: Date(timeIntervalSince1970: 1_700_000_060), result: (3, 1)
        )

        let replies = WiltedMacProviderEpisodeReply.latestByProvider(in: [first, otherProvider, latest])

        XCTAssertEqual(replies[.openAIKey]?.outcome, .reply(breakCount: 3, rejectedCount: 1))
        XCTAssertTrue(try XCTUnwrap(replies[.openAIKey]).detail.contains("Found 3 ad breaks. 1 label could not be used."))
        XCTAssertEqual(replies[.anthropicKey]?.outcome, .reply(breakCount: 0, rejectedCount: 0))
        XCTAssertNil(replies[.openRouterKey])
    }

    func testLatestRecordedEpisodeFailureSupersedesAnOlderReply() throws {
        let success = try run(
            id: "success", provider: .opencodeGoKey, model: "deepseek-v4.1-flash",
            at: Date(timeIntervalSince1970: 1_700_000_000), result: (1, 0)
        )
        let failure = try run(
            id: "failure", provider: .opencodeGoKey, model: "deepseek-v4.1-flash",
            at: Date(timeIntervalSince1970: 1_700_000_060), failureKind: "rate-limited"
        )

        let result = try XCTUnwrap(WiltedMacProviderEpisodeReply.latestByProvider(in: [success, failure])[.opencodeGoKey])

        XCTAssertEqual(result.outcome, .failure("Too many requests"))
        XCTAssertTrue(result.detail.contains("Too many requests"))
    }

    func testZeroValidatedBreaksWithRejectedLabelsDoesNotClaimNoAds() throws {
        let result = try run(
            id: "rejected", provider: .openAIKey, model: "gpt-4o",
            at: Date(timeIntervalSince1970: 1_700_000_000), result: (0, 1)
        )

        let detail = try XCTUnwrap(WiltedMacProviderEpisodeReply.latestByProvider(in: [result])[.openAIKey]).detail

        XCTAssertTrue(detail.contains("No usable ad breaks. 1 label could not be used."), detail)
        XCTAssertFalse(detail.contains("No ad breaks found"), detail)
    }

    private func run(
        id: String,
        provider: AdLabellerProvider,
        model: String,
        at date: Date,
        result: (breaks: Int, rejected: Int)? = nil,
        failureKind: String? = nil
    ) throws -> PreparationRunSummary {
        let itemID = try ItemID(rawValue: "item-\(id)")
        let startedAt = Timestamp(date.addingTimeInterval(-1))
        let request = try entry(
            id: "\(id)-request", itemID: itemID, at: startedAt.date,
            kind: "labeller-request",
            fields: ["provider": provider.rawValue, "modelID": model],
            step: "ads.label.request"
        )
        let resultEntry: PreparationJournalEntry
        if let result {
            resultEntry = try entry(
                id: "\(id)-result", itemID: itemID, at: date,
                kind: "labeller-result",
                fields: ["breaks": String(result.breaks), "rejected": String(result.rejected)],
                step: "ads.label.complete"
            )
        } else {
            resultEntry = try entry(
                id: "\(id)-wait", itemID: itemID, at: date,
                kind: "labeller-wait", fields: ["failureKind": try XCTUnwrap(failureKind)],
                step: "ads.label.wait"
            )
        }
        return PreparationRunSummary(
            requestID: "podcast-\(id)", itemID: itemID, startedAt: startedAt,
            updatedAt: Timestamp(date), stage: .preparing, detail: "Checking ads",
            fraction: nil, isTerminal: false, outcome: nil, failure: nil,
            entries: [request, resultEntry]
        )
    }

    private func entry(
        id: String,
        itemID: ItemID,
        at date: Date,
        kind: String,
        fields: [String: String],
        step: String
    ) throws -> PreparationJournalEntry {
        let status = try PreparationStatus(
            stage: .preparing, detail: "Checking ads", cancellable: true,
            emittedAt: Timestamp(date), evidence: PreparationEvidence(kind: kind, fields: fields),
            step: step
        )
        return PreparationJournalEntry(id: id, itemID: itemID, requestID: "podcast-\(id)", status: status)
    }
}
