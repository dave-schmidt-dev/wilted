import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// How a media request waits for the Mac: by the stage the Mac last reported for it, not one flat limit.
/// The limits are shrunk to milliseconds; each test keeps the limit it is not about far away.
@MainActor
final class LibraryRequestProgressTests: XCTestCase {
    private var rigs: [HandshakeRig] = []
    private let entry = "a"
    private var macNotAnswering: String { LibraryAppModel.text(for: MediaFetchFailure.macNotAnswering) }

    override func tearDown() async throws {
        for rig in rigs {
            await rig.model.sceneBecameBackground()
            rig.tearDown()
        }
        rigs = []
    }

    private func timing(
        silence: Duration = .seconds(30), queued: Duration = .seconds(30), sending: Duration = .seconds(30),
        answered: Duration = .seconds(30)
    ) -> LibraryMediaTiming {
        LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: silence, queuedTimeout: queued,
                           sendingTimeout: sending, answeredTimeout: answered, watchdog: .seconds(30))
    }

    private func makeRig(_ timing: LibraryMediaTiming, realClock: Bool = false) async throws -> HandshakeRig {
        let rig = try HandshakeRig(timing: timing, realClock: realClock)
        rigs.append(rig)
        try await rig.queue(entry)
        return rig
    }

    private func request(_ rig: HandshakeRig) async throws -> String {
        rig.model.performMediaAction(.request, entryID: rig.id(entry))
        return try await rig.requestIntentID(entry)
    }

    private func stage(_ rig: HandshakeRig) -> LibraryMediaRequestStage? {
        if case let .requested(_, _, stage) = rig.model.mediaState(for: rig.id(entry)) { return stage }
        return nil
    }

    // MARK: each stage's limit

    func testNoStatusFailsAsMacNotAnsweringAfterTheSilenceLimit() async throws {
        let rig = try await makeRig(timing(silence: .milliseconds(150)))
        let started = ContinuousClock.now
        rig.model.performMediaAction(.request, entryID: rig.id(entry))
        await rig.model.waitForMedia(entryID: rig.id(entry))

        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .failed(macNotAnswering))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(150))
    }

    func testAReceivedRequestKeepsWaitingPastTheSilenceLimit() async throws {
        let rig = try await makeRig(timing(silence: .milliseconds(300)))
        let intent = try await request(rig)
        try await rig.macReports(.received, intentID: intent, entry: entry)
        try await rig.eventually("the row says queued") { self.stage(rig) == .queued }

        try await Task.sleep(for: .milliseconds(900)) // three times the silence limit
        XCTAssertEqual(stage(rig), .queued, "in line on the Mac is not silence")
        XCTAssertTrue(rig.model.mediaState(for: rig.id(entry)).isInFlight)

        try await rig.macPublishesAudio(entry)
        await rig.model.waitForMedia(entryID: rig.id(entry))
        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .onPhone, "and the offer still completes it")
    }

    func testAReceivedRequestFailsOnlyAfterTheQueuedLimitWithNoStageChange() async throws {
        let rig = try await makeRig(timing(queued: .milliseconds(300)))
        let intent = try await request(rig)
        let started = ContinuousClock.now
        try await rig.macReports(.received, intentID: intent, entry: entry)
        await rig.model.waitForMedia(entryID: rig.id(entry))

        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .failed(macNotAnswering))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(300))
    }

    func testASendingRequestShowsItAndKeepsWaitingPastTheSilenceLimit() async throws {
        let rig = try await makeRig(timing(silence: .milliseconds(300)))
        let intent = try await request(rig)
        try await rig.macReports(.sending, intentID: intent, entry: entry)
        try await rig.eventually("the row says the Mac is sending") { self.stage(rig) == .sending }

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(stage(rig), .sending)

        try await rig.macPublishesAudio(entry)
        await rig.model.waitForMedia(entryID: rig.id(entry))
        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .onPhone)
    }

    func testASendingRequestFailsAfterTheSendingLimit() async throws {
        let rig = try await makeRig(timing(sending: .milliseconds(300)))
        let intent = try await request(rig)
        let started = ContinuousClock.now
        try await rig.macReports(.sending, intentID: intent, entry: entry)
        await rig.model.waitForMedia(entryID: rig.id(entry))

        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .failed(macNotAnswering))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(300))
    }

    func testAFailedStageEndsAtOnceWithTheMacsOwnWords() async throws {
        let rig = try await makeRig(timing())
        let intent = try await request(rig)
        try await rig.macReports(.failed, intentID: intent, entry: entry, detail: "The audio is no longer on this Mac.")
        await rig.model.waitForMedia(entryID: rig.id(entry))

        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .failed("The audio is no longer on this Mac."))
    }

    func testAFailedStageWithoutWordsUsesTheGenericSentence() async throws {
        for detail in [nil, "  \n "] as [String?] {
            let rig = try await makeRig(timing())
            let intent = try await request(rig)
            try await rig.macReports(.failed, intentID: intent, entry: entry, detail: detail)
            await rig.model.waitForMedia(entryID: rig.id(entry))
            XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .failed(LibraryAppModel.text(for: MediaFetchFailure.other)))
        }
    }

    func testAnAnsweredRequestWaitsForTheOfferThenFailsAfterTheAnsweredLimit() async throws {
        let rig = try await makeRig(timing(answered: .milliseconds(300)))
        let intent = try await request(rig)
        let started = ContinuousClock.now
        try await rig.macReports(.answered, intentID: intent, entry: entry)
        await rig.model.waitForMedia(entryID: rig.id(entry))

        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .failed(macNotAnswering))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(300))
    }

    func testAnAnsweredRequestProceedsOnceTheOfferIsSeen() async throws {
        let rig = try await makeRig(timing(answered: .seconds(30)))
        let intent = try await request(rig)
        try await rig.macReports(.answered, intentID: intent, entry: entry)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(rig.model.mediaState(for: rig.id(entry)).isInFlight)
        try await rig.macPublishesAudio(entry)
        await rig.model.waitForMedia(entryID: rig.id(entry))
        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .onPhone)
    }

    func testAStatusForAnotherRequestIsIgnored() async throws {
        let rig = try await makeRig(timing(silence: .milliseconds(200)))
        let intent = try await request(rig)
        try await rig.macReports(.received, intentID: intent + "-other", entry: entry)
        await rig.model.waitForMedia(entryID: rig.id(entry))
        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .failed(macNotAnswering), "no status for this request: silence")
    }

    func testALaterStageIsNeverReplacedByAnEarlierOne() async throws {
        let rig = try await makeRig(timing(silence: .milliseconds(300)))
        let intent = try await request(rig)
        try await rig.macReports(.sending, intentID: intent, entry: entry)
        try await rig.eventually("the row says the Mac is sending") { self.stage(rig) == .sending }
        // A stale copy of the record that says an earlier stage: the phone never steps back.
        try await rig.macReports(.received, intentID: intent, entry: entry)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(stage(rig), .sending)
    }

    // MARK: while the sync tick runs

    func testRoundsFeedTheWaitAndTheRequestMakesNoReadsOfItsOwnBeforeHalfway() async throws {
        let rig = try await makeRig(timing(silence: .seconds(30)), realClock: true)
        await rig.model.sceneBecameActive()
        await rig.model.start()
        let offerReads = rig.probe.directOfferReads, linkReads = rig.probe.directLinkReads

        let intent = try await request(rig)
        try await rig.macReports(.received, intentID: intent, entry: entry)
        await rig.model.refresh() // what the tick's next round does
        try await rig.eventually("the round's link read reaches the row") { self.stage(rig) == .queued }

        try await rig.macPublishesAudio(entry)
        await rig.model.refresh()
        await rig.model.waitForMedia(entryID: rig.id(entry))
        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .onPhone)
        XCTAssertEqual(rig.probe.directOfferReads, offerReads, "the rounds read the offers; the request read none itself")
        XCTAssertEqual(rig.probe.directLinkReads, linkReads, "nor the link")
    }

    func testOneDirectReadOfTheOffersAndTheLinkAtHalfwayThroughTheSilenceLimit() async throws {
        let rig = try await makeRig(timing(silence: .milliseconds(800)), realClock: true)
        await rig.model.sceneBecameActive()
        await rig.model.start()
        let offerReads = rig.probe.directOfferReads, linkReads = rig.probe.directLinkReads

        let intent = try await request(rig)
        try await rig.macReports(.received, intentID: intent, entry: entry) // no round runs: only the recheck can see it
        try await rig.eventually("the halfway recheck finds the stage", timeout: .seconds(3)) { self.stage(rig) == .queued }
        try await Task.sleep(for: .milliseconds(600)) // now past the 800 ms silence limit
        XCTAssertEqual(rig.probe.directOfferReads - offerReads, 1, "one recheck of the offers")
        XCTAssertEqual(rig.probe.directLinkReads - linkReads, 1, "and of the link")
        XCTAssertEqual(stage(rig), .queued, "received outlasts the 800 ms silence limit")
    }

    func testAnAnsweredRequestGetsOneDirectReadOfTheOffersWhenTheRoundsMissIt() async throws {
        let rig = try await makeRig(timing(silence: .seconds(1), answered: .milliseconds(600)), realClock: true)
        await rig.model.sceneBecameActive()
        await rig.model.start()

        let intent = try await request(rig)
        try await rig.macReports(.answered, intentID: intent, entry: entry)
        // The halfway recheck (0.5 s) learns the stage; the offer shows up only after it, and no round runs.
        try await Task.sleep(for: .milliseconds(700))
        try await rig.macPublishesAudio(entry)
        await rig.model.waitForMedia(entryID: rig.id(entry))
        XCTAssertEqual(rig.model.mediaState(for: rig.id(entry)), .onPhone, "the read when the answered limit ends finds it")
    }

    // MARK: wording

    func testEachStageHasItsOwnStatusText() {
        let since = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(LibraryMediaState.requested(since: since).statusText(elapsed: 5), "Sent to Mac · 00:05")
        XCTAssertEqual(LibraryMediaState.requested(since: since, stage: .queued).statusText(elapsed: 65), "Queued on Mac · 01:05")
        XCTAssertEqual(LibraryMediaState.requested(since: since, stage: .sending).statusText(elapsed: 125), "Mac is sending · 02:05")
        XCTAssertEqual(
            LibraryMediaState.requested(since: since, retry: LibraryMediaRetry(attempt: 2, attempts: 3), stage: .sending).statusText(elapsed: 9),
            "Retrying (2 of 3)", "a retry keeps its own wording")
    }

    func testEveryStageKeepsTheRequestInFlightAndCancellable() {
        let since = Date(timeIntervalSince1970: 1_000)
        for stage in [LibraryMediaRequestStage.sent, .queued, .sending] {
            XCTAssertTrue(LibraryMediaState.requested(since: since, stage: stage).isInFlight)
            XCTAssertEqual(LibraryMediaState.requested(since: since, stage: stage).startedAt, since)
        }
    }

    func testTheDefaultLimitsAreTheAgreedOnes() {
        let timing = LibraryMediaTiming()
        XCTAssertEqual(timing.offerTimeout, .seconds(120), "silence")
        XCTAssertEqual(timing.queuedTimeout, .seconds(30 * 60))
        XCTAssertEqual(timing.sendingTimeout, .seconds(15 * 60))
        XCTAssertEqual(timing.answeredTimeout, .seconds(120))
    }
}
