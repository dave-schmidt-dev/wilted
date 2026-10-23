import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The full player's ad feedback: what it offers, the press saved in the outbox before anything
/// else, Undo inside the hold, and the send once the hold has passed and the Mac files feedback.
@MainActor
final class LibraryAdFeedbackTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_700_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
    private let clock = Clock()
    private var scratch: URL!
    private var outboxURL: URL { scratch.appendingPathComponent("pending-intents.json") }
    private let suite = "library-ad-feedback-tests"

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-ad-feedback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }
    private func revision(_ raw: String) -> RevisionID { try! RevisionID(rawValue: raw) }

    private func launch(_ script: OutboxSendScript = OutboxSendScript(.deliver)) -> LibraryAppModel {
        let clock = clock
        return LibraryAppModel(
            transport: OutboxScriptedTransport(
                base: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
                script: script),
            store: FileLibraryStore(url: scratch.appendingPathComponent("library-state.json")), deviceID: "phone",
            preferences: UserDefaults(suiteName: suite)!, outboxURL: outboxURL, now: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!)
    }

    private func item(revision raw: String? = "rev-1") -> LibraryPlayer.Item {
        LibraryPlayer.Item(entryID: id("item-a"), title: "Episode", showTitle: "Show",
                           fileURL: scratch.appendingPathComponent("a.m4a"), feedbackRevisionID: raw.map(revision))
    }

    private func savedFeedback() -> [LibraryIntent] {
        guard case let .saved(saved) = LibraryIntentOutbox(url: outboxURL).load() else { return [] }
        return saved.adFeedback
    }

    private func macTakesFeedback(_ takes: Bool = true) async throws {
        try await mac.publishStats(LibraryStats(
            supportedIntentActions: ["subscribe", "addArticle"] + (takes ? [LibraryAppModel.adFeedbackAction] : [])))
    }

    // MARK: What is offered

    func testOnlyAPreparedPodcastEpisodeOffersFeedback() {
        let model = launch()
        XCTAssertEqual(model.adFeedbackKinds(for: nil, at: 10), [])
        XCTAssertEqual(model.adFeedbackKinds(for: item(revision: nil), at: 10), [], "an audiobook or article")
        XCTAssertEqual(model.adFeedbackKinds(for: item(), at: 10), AdFeedbackKind.allCases,
                       "without the Mac's cuts every verdict is offered")
    }

    func testTheCutVerdictsAppearOnlyJustAfterACut() throws {
        let model = launch()
        let cut = AdCut(preparedSeconds: 100, originalStartSeconds: 100, originalEndSeconds: 160, label: "ad_break")
        model.transcripts[id("item-a")] = try LibraryTranscript(
            entryID: id("item-a"), revisionID: revision("rev-1"), plainText: "words", cuts: [cut])
        XCTAssertEqual(model.adFeedbackKinds(for: item(), at: 50), [.adHere])
        XCTAssertEqual(model.adFeedbackKinds(for: item(), at: 110), AdFeedbackKind.allCases)
        XCTAssertEqual(model.adFeedbackKinds(for: item(revision: "rev-2"), at: 50), AdFeedbackKind.allCases,
                       "a transcript for another revision says nothing about this audio")
        model.transcripts[id("item-a")] = try LibraryTranscript(
            entryID: id("item-a"), revisionID: revision("rev-1"), plainText: "words", cuts: [])
        XCTAssertEqual(model.adFeedbackKinds(for: item(), at: 110), [.adHere], "nothing was cut")
    }

    // MARK: Press, Undo, send

    func testAPressIsSavedAtOnceAndUndoTakesItBackBeforeItIsSent() async throws {
        try await macTakesFeedback()
        let script = OutboxSendScript(.deliver)
        let model = launch(script)
        model.recordAdFeedback(.adHere, item: item(), playedSeconds: 100)
        XCTAssertEqual(model.adFeedbackAcknowledgement?.text, "Ad here marked at 01:40")
        XCTAssertEqual(savedFeedback().map(\.action),
                       [.adFeedback(entryID: id("item-a"), revisionID: revision("rev-1"), kind: .adHere, playedSeconds: 100)])

        model.undoAdFeedback()
        XCTAssertNil(model.adFeedbackAcknowledgement)
        XCTAssertTrue(savedFeedback().isEmpty)
        clock.advance(LibraryAppModel.adFeedbackUndoSeconds + 1)
        await model.sendDueAdFeedback()
        XCTAssertEqual(script.attempts, [])
    }

    func testAPressIsSentOnceItsUndoWindowHasPassed() async throws {
        try await macTakesFeedback()
        let script = OutboxSendScript(.deliver)
        let model = launch(script)
        model.recordAdFeedback(.notAnAd, item: item(), playedSeconds: 104)
        let pending = try XCTUnwrap(model.adFeedback.first)

        clock.advance(1)
        await model.sendDueAdFeedback()
        XCTAssertEqual(script.attempts, [], "still inside the undo window")

        clock.advance(LibraryAppModel.adFeedbackUndoSeconds)
        await model.sendDueAdFeedback()
        XCTAssertEqual(script.attempts, [pending.id])
        XCTAssertTrue(model.adFeedback.isEmpty)
        XCTAssertTrue(savedFeedback().isEmpty)
        XCTAssertNil(model.adFeedbackAcknowledgement, "nothing left to undo once it is sent")
        let onServer = try await mac.listIntents()
        XCTAssertEqual(onServer.map(\.id), [pending.id])
    }

    func testAFailedSendIsTriedAgain() async throws {
        try await macTakesFeedback()
        let script = OutboxSendScript(.fail)
        let model = launch(script)
        model.recordAdFeedback(.goodCut, item: item(), playedSeconds: 104)
        clock.advance(LibraryAppModel.adFeedbackUndoSeconds + 1)
        await model.sendDueAdFeedback()
        XCTAssertEqual(savedFeedback().count, 1)
        script.mode = .deliver
        await model.sendDueAdFeedback()
        XCTAssertEqual(script.attempts.count, 2)
        XCTAssertTrue(savedFeedback().isEmpty)
    }

    func testAnOlderMacKeepsThePressSavedUntilItTakesFeedback() async throws {
        try await macTakesFeedback(false)
        let first = launch()
        first.recordAdFeedback(.adHere, item: item(), playedSeconds: 30)
        clock.advance(LibraryAppModel.adFeedbackUndoSeconds + 1)
        await first.sendDueAdFeedback()
        XCTAssertEqual(savedFeedback().count, 1)

        try await macTakesFeedback()
        let script = OutboxSendScript(.deliver)
        let second = launch(script)
        XCTAssertEqual(second.adFeedback.count, 1, "a relaunch brings the press back")
        await second.sendDueAdFeedback()
        XCTAssertEqual(script.attempts.count, 1)
        XCTAssertTrue(savedFeedback().isEmpty)
    }

    func testAVersionOneOutboxWithoutFeedbackStillLoads() throws {
        try Data(#"{"version":1,"ownerToken":"fixture-owner","decisions":[],"adds":[],"acknowledgements":[]}"#.utf8)
            .write(to: outboxURL)
        guard case let .saved(saved) = LibraryIntentOutbox(url: outboxURL).load() else {
            return XCTFail("a version 1 file from before ad feedback must load")
        }
        XCTAssertEqual(saved.ownerToken, "fixture-owner")
        XCTAssertTrue(saved.adFeedback.isEmpty)
    }
}
