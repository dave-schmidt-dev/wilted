import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac
@testable import WiltedProducer

/// The Mac's ad feedback: the entry a press becomes, the review inbox's file, the Now Playing
/// acknowledgement and Undo, and a phone's `adFeedback` intent reaching the inbox.
@MainActor
final class WiltedMacAdFeedbackTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    /// 0..<100 kept, 100..<160 cut, 160..<300 kept (prepared 100..<240).
    private func timeline() throws -> PreparationStatus.PreparationTimeline {
        try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 100, originalEndSeconds: 160, label: "ad_break", confidence: 0.9)],
            kept: [
                try .init(originalStartSeconds: 0, originalEndSeconds: 100, outputStartSeconds: 0),
                try .init(originalStartSeconds: 160, originalEndSeconds: 300, outputStartSeconds: 100),
            ])
    }

    private func entry(
        id: String = UUID().uuidString, kind: AdFeedbackKind = .goodCut, played: Double = 104,
        timeline: PreparationStatus.PreparationTimeline?, createdAt: Date? = nil
    ) throws -> WiltedMacAdFeedbackEntry {
        WiltedMacAdFeedbackEntry.make(
            id: id, kind: kind, itemID: try ItemID(rawValue: "item-a"), revisionID: try RevisionID(rawValue: "rev-1"),
            playedSeconds: played, timeline: timeline, engineVersion: "2.3.0", pipelineFingerprint: "fp",
            createdAt: createdAt ?? clock, deviceID: "mac", source: .mac, showTitle: "Show", episodeTitle: "Episode")
    }

    // MARK: The entry

    func testAPressJustAfterACutNamesThatCutOnTheOriginalClock() throws {
        let made = try entry(played: 104, timeline: timeline())
        XCTAssertEqual(made.mapping, .mapped)
        XCTAssertEqual(made.originalSeconds, 164)
        XCTAssertEqual(made.nearestCut?.originalStartSeconds, 100)
        XCTAssertEqual(made.nearestCut?.originalEndSeconds, 160)
        XCTAssertEqual(made.nearestCut?.distanceSeconds, 4, "positive: the press came after the seam")
        XCTAssertEqual(made.review, .pending)
        XCTAssertEqual(made.effectiveLabel, .mustCut)
        XCTAssertEqual(try entry(kind: .notAnAd, timeline: timeline()).effectiveLabel, .mustKeep)
    }

    func testAPressFarFromAnyCutHasNoNearestCut() throws {
        let made = try entry(kind: .adHere, played: 200, timeline: timeline())
        XCTAssertNil(made.nearestCut)
        XCTAssertEqual(made.originalSeconds, 260)
    }

    func testAPressPastTheEndIsClampedAndOneWithoutATimelineIsUnmapped() throws {
        XCTAssertEqual(try entry(played: 500, timeline: timeline()).mapping, .clamped)
        let unmapped = try entry(timeline: nil)
        XCTAssertEqual(unmapped.mapping, .unmapped)
        XCTAssertNil(unmapped.originalSeconds)
        XCTAssertNil(unmapped.nearestCut)
    }

    // MARK: The inbox file

    func testTheInboxSurvivesReopeningAndFilesAnIDOnce() async throws {
        let url = wiltedTemporaryDirectory("inbox").appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let first = try entry(id: "one", timeline: timeline())
        let inbox = WiltedMacAdFeedbackInbox(fileURL: url)
        try await inbox.add(first)
        try await inbox.add(first)
        try await inbox.add(entry(id: "two", timeline: nil, createdAt: clock.addingTimeInterval(60)))

        let reopened = WiltedMacAdFeedbackInbox(fileURL: url)
        let ids = await reopened.all().map(\.id)
        XCTAssertEqual(ids, ["two", "one"], "newest first, each id once")
        let oldest = await reopened.all().last
        XCTAssertEqual(oldest, first)
    }

    func testReviewAndUndoAreSaved() async throws {
        let url = wiltedTemporaryDirectory("review").appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let inbox = WiltedMacAdFeedbackInbox(fileURL: url)
        try await inbox.add(entry(id: "one", timeline: timeline()))
        try await inbox.add(entry(id: "two", timeline: timeline()))
        try await inbox.review(id: "one", as: .accepted, label: .acceptableCut, at: clock)
        try await inbox.remove(id: "two")

        let saved = await WiltedMacAdFeedbackInbox(fileURL: url).all()
        XCTAssertEqual(saved.map(\.id), ["one"])
        XCTAssertEqual(saved.first?.review, .accepted)
        XCTAssertEqual(saved.first?.label, .acceptableCut)
        XCTAssertEqual(saved.first?.reviewedAt, clock)

        try await inbox.review(id: "one", as: .pending, label: .mustKeep, at: clock)
        let reopened = await inbox.all().first
        XCTAssertEqual(reopened?.review, .pending)
        XCTAssertNil(reopened?.label, "reopening forgets the old verdict")
        XCTAssertNil(reopened?.reviewedAt)
    }

    func testAnUnreadableInboxIsSetAsideNotOverwritten() async throws {
        let directory = wiltedTemporaryDirectory("corrupt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        try Data("{\"version\":2,\"entries\":[]}".utf8).write(to: url)

        let inbox = WiltedMacAdFeedbackInbox(fileURL: url)
        let afterSetAside = await inbox.all()
        XCTAssertTrue(afterSetAside.isEmpty)
        let aside = url.appendingPathExtension("unreadable")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{\"version\":2,\"entries\":[]}")
        try await inbox.add(entry(id: "fresh", timeline: nil))
        let fresh = await WiltedMacAdFeedbackInbox(fileURL: url).all().map(\.id)
        XCTAssertEqual(fresh, ["fresh"])
    }

    func testAFailedWriteKeepsTheInboxAsItWas() async throws {
        let inbox = WiltedMacAdFeedbackInbox(fileURL: wiltedTemporaryDirectory("fail").appendingPathComponent("x.json"),
                                             write: { _, _ in throw POSIXError(.ENOSPC) })
        do {
            try await inbox.add(entry(timeline: nil))
            XCTFail("the write failed")
        } catch {}
        let unchanged = await inbox.all()
        XCTAssertTrue(unchanged.isEmpty)
    }

    func testTheFileHoldsNoTranscriptText() async throws {
        let url = wiltedTemporaryDirectory("shape").appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        try await WiltedMacAdFeedbackInbox(fileURL: url).add(entry(id: "one", timeline: timeline()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let saved = try XCTUnwrap((object["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(saved.keys), [
            "id", "kind", "itemID", "revisionID", "playedSeconds", "originalSeconds", "mapping", "nearestCut",
            "engineVersion", "pipelineFingerprint", "createdAt", "deviceID", "source", "showTitle", "episodeTitle", "review",
        ])
    }

    // MARK: The press and Undo

    func testAPressIsAcknowledgedAtOnceAndUndoTakesItBack() async throws {
        let feedback = WiltedMacAdFeedbackController(inbox: WiltedMacAdFeedbackInbox(fileURL: nil))
        feedback.acknowledge(entryID: "p", kind: .adHere, playedSeconds: 754)
        XCTAssertEqual(feedback.acknowledgement?.text, "Ad here marked at 12:34")
        XCTAssertTrue(feedback.isSaving)
        await feedback.undo()
        XCTAssertNotNil(feedback.acknowledgement, "nothing to take back while it is still saving")

        await feedback.file(try entry(id: "p", kind: .adHere, timeline: nil))
        feedback.pressFinished()
        XCTAssertEqual(feedback.pending.map(\.id), ["p"])
        await feedback.undo()
        XCTAssertNil(feedback.acknowledgement)
        XCTAssertTrue(feedback.entries.isEmpty)
    }

    func testAFailedSaveSaysSoAndOffersNoUndo() async throws {
        let feedback = WiltedMacAdFeedbackController(inbox: WiltedMacAdFeedbackInbox(
            fileURL: wiltedTemporaryDirectory("press-fail").appendingPathComponent("x.json"),
            write: { _, _ in throw POSIXError(.ENOSPC) }))
        feedback.acknowledge(entryID: "p", kind: .notAnAd, playedSeconds: 10)
        let filed = await feedback.file(try entry(id: "p", kind: .notAnAd, timeline: nil))
        feedback.pressFinished()
        XCTAssertFalse(filed)
        XCTAssertEqual(feedback.acknowledgement?.text, "Not an ad was not saved")
        XCTAssertEqual(feedback.acknowledgement?.saved, false)
        XCTAssertNotNil(feedback.saveFailure)
    }

    func testTheAcknowledgementGoesAwayByItself() async throws {
        let feedback = WiltedMacAdFeedbackController(inbox: WiltedMacAdFeedbackInbox(fileURL: nil))
        feedback.acknowledgementDuration = .milliseconds(10)
        feedback.acknowledge(entryID: "p", kind: .goodCut, playedSeconds: 1)
        for _ in 0..<200 where feedback.acknowledgement != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(feedback.acknowledgement)
    }

    func testReviewMovesEntriesBetweenTheLists() async throws {
        let feedback = WiltedMacAdFeedbackController(inbox: WiltedMacAdFeedbackInbox(fileURL: nil))
        feedback.now = { [clock] in clock }
        await feedback.file(try entry(id: "a", timeline: nil))
        await feedback.file(try entry(id: "b", timeline: nil))
        await feedback.accept("a", as: .mustKeep)
        await feedback.dismiss("b")
        XCTAssertTrue(feedback.pending.isEmpty)
        XCTAssertEqual(Set(feedback.reviewed.map(\.id)), ["a", "b"])
        XCTAssertEqual(feedback.entries.first { $0.id == "a" }?.effectiveLabel, .mustKeep)
        await feedback.reopen("b")
        XCTAssertEqual(feedback.pending.map(\.id), ["b"])
    }

    // MARK: A phone's intent

    func testAPhoneFeedbackIntentIsFiledWhateverTheEntryAndAnsweredApplied() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let host = FakeDecisionHost()
        let applier = WiltedMacIntentApplier(
            host: host, ledger: WiltedMacIntentLedger(fileURL: nil, now: { [clock] in clock }),
            book: WiltedMacIntentOutcomeBook(fileURL: nil, now: { [clock] in clock }),
            transport: InMemoryLibraryTransport(deviceID: "mac", server: server), now: { [clock] in clock },
            onApplied: {})
        let old = try LibraryIntent.adFeedback(
            entryID: ItemID(rawValue: "item-unknown"), revisionID: RevisionID(rawValue: "rev-1"), kind: .adHere,
            playedSeconds: 30, deviceID: "iphone", createdAt: clock.addingTimeInterval(-30 * 24 * 3600), id: "f-1")

        try await applier.apply(old)
        host.filesFeedback = false
        try await applier.apply(LibraryIntent.adFeedback(
            entryID: ItemID(rawValue: "item-unknown"), revisionID: RevisionID(rawValue: "rev-1"), kind: .adHere,
            playedSeconds: 31, deviceID: "iphone", createdAt: clock, id: "f-2"))

        XCTAssertEqual(host.calls, ["adFeedback f-1", "adFeedback f-2"],
                       "an unknown entry and a month-old press still reach the inbox")
        let published = try await InMemoryLibraryTransport(deviceID: "iphone", server: server).intentOutcomes()
        let byID = Dictionary(uniqueKeysWithValues: published.map { ($0.intentID, $0) })
        XCTAssertEqual(byID["f-1"]?.disposition, .applied)
        XCTAssertEqual(byID["f-2"]?.reason, IntentOutcome.reasonFailed)
    }

    func testTheMacAdvertisesFeedbackToThePhone() {
        XCTAssertTrue(WiltedMacLibraryPublisher.supportedIntentActions.contains("adFeedback"))
    }
}
