import AppKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The normal-quit path: `applicationShouldTerminate` → `terminateLater`,
/// a bounded local drain, then exactly one reply.
@MainActor
final class WiltedMacTerminationTests: XCTestCase {
    // MARK: Coordinator, with a scripted owner

    func testDelayedSaveRepliesOnceAfterDrainAndRepeatQuitJoinsIt() async throws {
        let owner = ScriptedTerminationOwner()
        owner.holdsLocal = true
        let (coordinator, replies) = makeCoordinator(owner)

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        await owner.waitUntilLocalStarted()
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater, "a repeat quit joins the running drain")
        XCTAssertEqual(owner.localRuns, 1)
        XCTAssertTrue(replies.values.isEmpty, "no reply while the save is still running")

        owner.releaseLocal()
        try await waitFor { !replies.values.isEmpty }
        XCTAssertEqual(replies.values, [true])
        XCTAssertEqual(owner.events, ["local", "network"], "local work drains before the network step")
        XCTAssertEqual(coordinator.state, .approved)
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateNow)
        XCTAssertEqual(replies.values, [true], "still exactly one reply")
    }

    func testFailedSaveCancelsQuitVisiblyAndRetryExitsAfterSaving() async throws {
        let owner = ScriptedTerminationOwner()
        owner.localFailures = 1
        var presented: [WiltedMacTerminationFailure] = []
        let (coordinator, replies) = makeCoordinator(owner) { presented.append($0) }

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        try await waitFor { !replies.values.isEmpty }
        XCTAssertEqual(replies.values, [false], "a failed save keeps the app open")
        guard case .failed(.saveFailed) = coordinator.state else {
            return XCTFail("expected a visible save failure, got \(coordinator.state)")
        }
        XCTAssertEqual(presented.count, 1, "the retry state is shown")
        XCTAssertEqual(owner.resumes, 1, "admission and stopped work come back")
        XCTAssertFalse(owner.events.contains("network"), "nothing is closed for a quit that did not happen")

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater, "retry quits again")
        try await waitFor { replies.values.count == 2 }
        XCTAssertEqual(replies.values, [false, true])
        XCTAssertEqual(owner.savedRuns, 1, "the retry exits only after saving")
    }

    func testTimedOutSaveCancelsQuitAndItsLateCompletionCannotReply() async throws {
        let owner = ScriptedTerminationOwner()
        owner.holdsLocal = true
        let (coordinator, replies) = makeCoordinator(owner, budget: .milliseconds(80))

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        try await waitFor { !replies.values.isEmpty }
        XCTAssertEqual(replies.values, [false])
        XCTAssertEqual(coordinator.state, .failed(.timedOut))
        try await waitFor { owner.localWasCancelled }

        owner.releaseLocal()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(replies.values, [false], "a late completion cannot answer a cancelled quit")
        XCTAssertEqual(coordinator.state, .failed(.timedOut))
    }

    func testSlowNetworkJoinNeverCancelsAQuitWhoseLocalWorkSaved() async throws {
        let owner = ScriptedTerminationOwner()
        owner.holdsNetwork = true
        let (coordinator, replies) = makeCoordinator(owner, budget: .milliseconds(120))

        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        try await waitFor { !replies.values.isEmpty }
        XCTAssertEqual(replies.values, [true], "cloud work is never waited on for success")
        XCTAssertEqual(owner.resumes, 0)
        owner.releaseNetwork()
    }

    // MARK: The model's local drain

    func testQuitDrainPausesNowWritesPlayheadAndTotalsAndStopsAdmission() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        let playback = try XCTUnwrap(model.playback)
        XCTAssertTrue(playback.liveIsPlaying)
        try await playback.seek(to: 42)
        // A start issued just before Quit is fenced by the drain's Stop.
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        gate.arm()
        model.togglePlayback()
        await gate.waitUntilHeld()

        try await model.drainLocalWorkForTermination()
        gate.release()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertFalse(backend.isPlaying, "the pending start never ran")
        XCTAssertFalse(model.isPlaying)
        let store = try XCTUnwrap(model.store)
        let itemID = try XCTUnwrap(playback.itemID)
        let revisionID = try XCTUnwrap(playback.revisionID)
        let saved = try await store.playbackState(for: itemID, revisionID: revisionID)
        XCTAssertEqual(try XCTUnwrap(saved?.positionSeconds), playback.livePositionSeconds, accuracy: 0.001)

        let generation = model.playbackCommands.generation
        model.startPlayback()
        model.playEpisode(episode)
        XCTAssertEqual(model.playbackCommands.generation, generation, "no start is admitted while quitting")
        XCTAssertTrue(model.isClosingTemporaryState)

        model.resumeAfterCancelledTermination()
        XCTAssertFalse(model.isClosingTemporaryState, "a cancelled quit admits work again")
        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(backend.isPlaying)
    }

    /// Step 4: an in-flight download is cancelled and joined before the
    /// drain returns, and its received bytes reach the store on that exit.
    func testQuitDrainCancelsAndJoinsInFlightDownloadAndKeepsItsBytes() async throws {
        let transport = HeldPodcastDownloadTransport(chunk: 4_096)
        let (model, episode) = try await makeDownloadModel(transport: transport)
        model.downloadEpisode(episode, alreadyClaimed: true)
        try await waitFor {
            if case let .downloading(received, _) = model.episodes.first(where: { $0.id == episode.id })?.downloadState {
                return received > 0
            }
            return false
        }

        try await model.drainLocalWorkForTermination()

        XCTAssertTrue(model.podcastDownloadTasks.isEmpty, "the drain joined the download before returning")
        let store = try XCTUnwrap(model.store)
        let summary = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(summary.measured.receivedBytes, 4_096, "the cancelled transfer's bytes were kept")
    }

    // MARK: An isolated fixture process, quit for real

    /// A directed quit event to a fixture process this test launched enters
    /// `applicationShouldTerminate`, replies once after the drain and exits,
    /// and the reopened store holds exactly the drained playhead and totals.
    func testFixtureQuitEntersDelegateRepliesOnceExitsAndReopensDrainedState() async throws {
        let fixture = try TerminationFixtureProcess.launch(in: wiltedTemporaryDirectory("termination-quit"))
        addTeardownBlock { fixture.forceStopIfRunning() }
        try await fixture.waitForEvent("ready")

        // Two back-to-back quit events still produce exactly one reply.
        try fixture.sendQuit()
        try fixture.sendQuit()
        try await fixture.waitForExit()

        let events = try fixture.events()
        XCTAssertGreaterThanOrEqual(events.filter { $0["event"] == "should-terminate" }.count, 1,
                                    "the quit entered the delegate")
        XCTAssertEqual(events.filter { $0["event"] == "reply" }.map { $0["detail"] }, ["terminate"])
        let playhead = try XCTUnwrap(events.last { $0["event"] == "playhead" })
        try await fixture.assertReopenedStoreMatches(playhead)
    }

    /// A failed drain keeps the fixture alive with its retry state, and the
    /// retried quit exits after saving.
    func testFixtureFailedDrainStaysOpenAndRetriedQuitExitsAfterSaving() async throws {
        let fixture = try TerminationFixtureProcess.launch(
            in: wiltedTemporaryDirectory("termination-retry"), failingFirstDrain: true
        )
        addTeardownBlock { fixture.forceStopIfRunning() }
        try await fixture.waitForEvent("ready")

        try fixture.sendQuit()
        try await fixture.waitForEvent("failed")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(fixture.isRunning, "a cancelled quit leaves the app open")

        try fixture.sendQuit()
        try await fixture.waitForExit()
        let events = try fixture.events()
        XCTAssertEqual(events.filter { $0["event"] == "reply" }.map { $0["detail"] }, ["cancel", "terminate"])
        let playhead = try XCTUnwrap(events.last { $0["event"] == "playhead" })
        try await fixture.assertReopenedStoreMatches(playhead)
    }

    // MARK: Helpers

    private func makeDownloadModel(
        transport: HeldPodcastDownloadTransport
    ) async throws -> (WiltedMacModel, WiltedMacEpisode) {
        let directory = wiltedTemporaryDirectory("termination-download")
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/termination.xml"))
        let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/termination.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let itemID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "quit", enclosureURL: enclosure)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Quit feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: "quit",
                    title: "Quit episode", publishedTime: created, enclosureURL: enclosure,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                return store
            },
            podcastDownloadTransportFactory: { transport },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episode = try XCTUnwrap(model.episodes.first { $0.id == itemID.rawValue })
        return (model, episode)
    }

    private func makeCoordinator(
        _ owner: ScriptedTerminationOwner,
        budget: Duration = .seconds(5),
        present: @escaping @MainActor (WiltedMacTerminationFailure) -> Void = { _ in }
    ) -> (WiltedMacTerminationCoordinator, TerminationReplies) {
        let replies = TerminationReplies()
        let coordinator = WiltedMacTerminationCoordinator(
            owner: owner, budget: budget,
            reply: { replies.values.append($0) }, presentFailure: present
        )
        return (coordinator, replies)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}

@MainActor
final class TerminationReplies {
    var values: [Bool] = []
}

/// A termination owner whose local save and network join finish, fail or
/// hang when the test says so.
@MainActor
final class ScriptedTerminationOwner: WiltedMacTerminationDraining {
    var holdsLocal = false
    var holdsNetwork = false
    var localFailures = 0
    private(set) var localRuns = 0
    private(set) var savedRuns = 0
    private(set) var resumes = 0
    private(set) var events: [String] = []
    private(set) var localWasCancelled = false
    private var localRelease: CheckedContinuation<Void, Never>?
    private var networkRelease: CheckedContinuation<Void, Never>?
    private var localStarted: CheckedContinuation<Void, Never>?

    func drainLocalWorkForTermination() async throws {
        localRuns += 1
        localStarted?.resume()
        localStarted = nil
        if localFailures > 0 {
            localFailures -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        if holdsLocal {
            await withTaskCancellationHandler {
                await withCheckedContinuation { localRelease = $0 }
            } onCancel: {
                Task { @MainActor in self.localWasCancelled = true }
            }
            if Task.isCancelled { throw CancellationError() }
        }
        savedRuns += 1
        events.append("local")
    }

    func closeNetworkWorkForTermination() async {
        if holdsNetwork { await withCheckedContinuation { networkRelease = $0 } }
        events.append("network")
    }

    func resumeAfterCancelledTermination() { resumes += 1 }

    func waitUntilLocalStarted() async {
        guard localRuns == 0 else { return }
        await withCheckedContinuation { localStarted = $0 }
    }

    func releaseLocal() {
        localRelease?.resume()
        localRelease = nil
    }

    func releaseNetwork() {
        networkRelease?.resume()
        networkRelease = nil
    }
}

/// Delivers a response and one chunk, then holds the transfer open until the
/// consuming task is cancelled.
final class HeldPodcastDownloadTransport: PodcastDownloadTransporting, @unchecked Sendable {
    let chunk: Int
    init(chunk: Int) { self.chunk = chunk }

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(url: url, statusCode: 200, mediaType: "audio/mpeg",
                                               expectedByteCount: Int64(chunk * 4))))
            continuation.yield(.data(Data(repeating: 0x5A, count: chunk)))
        }
    }
}

/// One fixture copy of this app, launched as a child process with an
/// isolated state directory and a clean environment. Every quit or kill is
/// addressed to the child's own PID after checking it is this test's child
/// running this build's bundle, never the installed owner app.
@MainActor
final class TerminationFixtureProcess {
    let process: Process
    let stateDirectory: URL
    let journalURL: URL
    private let bundleURL: URL

    private init(process: Process, stateDirectory: URL, journalURL: URL, bundleURL: URL) {
        self.process = process
        self.stateDirectory = stateDirectory
        self.journalURL = journalURL
        self.bundleURL = bundleURL
    }

    static func launch(in root: URL, failingFirstDrain: Bool = false) throws -> TerminationFixtureProcess {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        XCTAssertFalse(bundleURL.path.hasPrefix("/Applications/"), "never launch the installed app")
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("termination.jsonl")
        let process = Process()
        process.executableURL = executable
        var arguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--wilted-ui-fixture-playing",
            "--wilted-ui-fixture-state-directory", state.path,
            WiltedMacTerminationJournal.argument, journal.path,
        ]
        if failingFirstDrain { arguments.append(WiltedMacTerminationJournal.failFirstDrainArgument) }
        process.arguments = arguments
        // A clean environment: an inherited XCTest configuration or injected
        // library would make the child think it hosts tests.
        process.environment = [
            "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return TerminationFixtureProcess(process: process, stateDirectory: state, journalURL: journal, bundleURL: bundleURL)
    }

    var isRunning: Bool { process.isRunning }

    /// Sends the AppKit quit event to the verified child only.
    func sendQuit() throws {
        let app = try verifiedChild()
        XCTAssertTrue(app.terminate(), "the quit event was delivered")
    }

    func forceStopIfRunning() {
        guard process.isRunning, (try? verifiedChild()) != nil else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    private func verifiedChild() throws -> NSRunningApplication {
        let pid = process.processIdentifier
        guard process.isRunning, pid > 0, pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleURL?.standardizedFileURL == bundleURL,
              app.bundleURL?.path.hasPrefix("/Applications/") == false else {
            throw XCTSkip("the fixture child could not be verified; refusing to signal it")
        }
        return app
    }

    func events() throws -> [[String: String]] {
        guard let text = try? String(contentsOf: journalURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        }
    }

    func waitForEvent(_ name: String, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try events().contains(where: { $0["event"] == name }) { return }
            guard process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("fixture never recorded \(name); events: \(try events())")
        throw CancellationError()
    }

    func waitForExit(timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(process.isRunning, "the fixture exited after its reply")
    }

    /// Reopens the fixture's store after exit and compares what it committed
    /// with what the drain journaled.
    func assertReopenedStoreMatches(_ playhead: [String: String]) async throws {
        let store = try LocalLibraryStore(url: stateDirectory.appendingPathComponent("library.sqlite"))
        let itemID = try ItemID(rawValue: try XCTUnwrap(playhead["item"]))
        let revisionID = try RevisionID(rawValue: try XCTUnwrap(playhead["revision"]))
        let saved = try await store.playbackState(for: itemID, revisionID: revisionID)
        let position = try XCTUnwrap(Double(try XCTUnwrap(playhead["position"])))
        XCTAssertEqual(position, 37, accuracy: 0.001, "the fixture's seek is the drained playhead")

        XCTAssertEqual(try XCTUnwrap(saved?.positionSeconds), position, accuracy: 0.001)
        let summary = try await store.lifetimeStatisticsSummary()
        XCTAssertEqual(summary.state.rawValue, playhead["summaryState"])
        XCTAssertEqual(String(summary.measured.playedMilliseconds), playhead["playedMilliseconds"],
                       "the reopened totals are the drained totals")
        // The fixture plays for 1.5 s after its seek before reporting ready;
        // only the quit drain's pause checkpoint can have committed that time.
        XCTAssertGreaterThanOrEqual(summary.measured.playedMilliseconds, 1_400)
    }
}
