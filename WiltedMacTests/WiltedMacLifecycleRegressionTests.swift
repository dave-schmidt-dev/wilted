import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Causal cases for the Mac's forward queue that the continuation suites do
/// not reach: the controller's own queue advance (EOF on the loaded backend
/// generation), not the Larder-wide scan or manual Next those suites drive.
///
/// Every rig seeds episodes 18 to 21, queues 19, 20 and 21 (18 is ready but
/// never queued, so a wrap would have somewhere to go), swaps in the scripted
/// backend so EOF fires only when a test says so, and records every
/// observation the controller hands the model.
@MainActor
final class WiltedMacLifecycleRegressionTests: XCTestCase {
    enum Middle: CaseIterable { case ready, unprepared, missing, retired }

    /// What the controller told the model, in order.
    @MainActor final class Recorder {
        var observed: [String] = []
        var completed: [String] = []
        var finishes = 0
    }

    @MainActor struct Rig {
        let model: WiltedMacModel
        let store: LocalLibraryStore
        let ids: [Int: ItemID]
        let recorder: Recorder
        let backend: WiltedFixturePlaybackBackend
        func id(_ number: Int) -> String { ids[number]!.rawValue }
        func label(_ raw: String?) -> String {
            guard let raw else { return "nil" }
            return ids.first { $0.value.rawValue == raw }.map { "\($0.key)" } ?? raw
        }
        func episode(_ number: Int) throws -> WiltedMacEpisode {
            try XCTUnwrap(model.episodes.first { $0.id == id(number) })
        }
    }

    // MARK: - Ineligible middle, end of queue

    /// 19 finishes with an unprepared, missing-media or retired 20 still in the
    /// queue: the advance lands on 21, never touches 20, and after 21 the run
    /// stops without wrapping back to 18 or 19.
    func testQueueAdvanceSkipsEachIneligibleMiddleAndStopsAtTheEnd() async throws {
        for middle in [Middle.unprepared, .missing, .retired] {
            let rig = try await makeRig("forward-middle-\(middle)", middle: middle)
            let skipped = try rig.episode(20)
            XCTAssertTrue(rig.model.podcastQueueIDs.contains(rig.id(20)), "\(middle): 20 is still queued")
            XCTAssertFalse(rig.model.canPlayEpisode(skipped), "\(middle): 20 must be ineligible for the case to mean anything")
            switch middle {
            case .unprepared: XCTAssertFalse(skipped.preparationState.isPrepared)
            case .missing: XCTAssertFalse(skipped.isReadyMediaAvailable)
            case .retired: XCTAssertNotNil(skipped.retiredAt)
            case .ready: break
            }
            try await startQueue(rig, at: 19)

            try await finish(rig)
            XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(21), "\(middle): 19 advances past 20 to 21")
            XCTAssertTrue(rig.backend.isPlaying, "\(middle): 21 is playing")
            try await finish(rig)

            XCTAssertEqual(rig.recorder.observed.first, rig.id(21), "\(middle): the first advance names 21")
            XCTAssertFalse(rig.recorder.observed.contains(rig.id(20)), "\(middle): 20 is never loaded")
            XCTAssertEqual(rig.recorder.completed, [rig.id(19), rig.id(21)], "\(middle): one completion each")
            XCTAssertFalse(rig.backend.isPlaying, "\(middle): nothing plays after the queue's last entry")
            XCTAssertFalse([rig.id(18), rig.id(19)].contains(rig.model.currentPodcastEpisodeID ?? ""),
                           "\(middle): no wrap to an earlier episode")
            let untouched = middle == .retired ? [18] : [18, 20]
            for number in untouched {
                let kind = try await rig.store.removalKind(for: try XCTUnwrap(rig.ids[number]))
                XCTAssertNil(kind, "\(middle): \(number) is neither played through nor retired")
            }
            await rig.model.close()
        }
    }

    // MARK: - Idempotent completion

    /// The backend reports EOF twice for each generation (an end notification
    /// delivered twice). Each episode completes and advances exactly once.
    func testDuplicateEndOfFileCompletesAndAdvancesOncePerEpisode() async throws {
        let rig = try await makeRig("forward-duplicate-eof", middle: .ready)
        try await startQueue(rig, at: 19)

        try await finish(rig, times: 2)
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(20), "a repeated EOF must not advance twice")
        XCTAssertEqual(rig.recorder.completed, [rig.id(19)])
        try await finish(rig, times: 2)
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(21))
        XCTAssertEqual(rig.recorder.completed, [rig.id(19), rig.id(20)])
        try await finish(rig, times: 2)

        XCTAssertEqual(rig.recorder.observed.filter { $0 == rig.id(20) }.count, 1, "one advance into 20")
        XCTAssertEqual(rig.recorder.observed.first, rig.id(20))
        XCTAssertEqual(rig.recorder.completed, [rig.id(19), rig.id(20), rig.id(21)], "no duplicate completion")
        XCTAssertEqual(rig.recorder.finishes, 1, "one stop notice at the end of the queue")
        XCTAssertFalse(rig.backend.isPlaying)
        for number in [19, 20, 21] {
            let kind = try await rig.store.removalKind(for: try XCTUnwrap(rig.ids[number]))
            XCTAssertEqual(kind, .retired, "\(number) is durably finished")
        }
        let untouched = try await rig.store.removalKind(for: try XCTUnwrap(rig.ids[18]))
        XCTAssertNil(untouched, "18 was never part of the run")
        await rig.model.close()
    }

    // MARK: - Queue change during the lookup

    /// 20 is dismissed elsewhere after the controller's lookup chose it but
    /// before it loads (the eligibility re-check is the seam: the wrapped
    /// predicate dismisses 20 the first time it is asked, then answers as
    /// production would). The run skips to 21 rather than stopping or
    /// playing a removed entry.
    func testAQueueEntryRemovedDuringTheLookupIsSkippedForTheNextOne() async throws {
        let rig = try await makeRig("forward-lookup-change", middle: .ready)
        try await startQueue(rig, at: 19)
        let playback = try XCTUnwrap(rig.model.playback)
        let eligible = try XCTUnwrap(playback.episodeEligibilityPredicate)
        let store = rig.store
        let target = try XCTUnwrap(rig.ids[20])
        let probe = Recorder()
        playback.episodeEligibilityPredicate = { episodeID in
            let answer = await eligible(episodeID)
            if episodeID == target, probe.finishes == 0 {
                probe.finishes += 1
                _ = try? await store.dismissPodcastEpisode(target)
            }
            return answer
        }

        try await finish(rig)
        XCTAssertEqual(probe.finishes, 1, "the lookup asked about 20 and 20 was dismissed")
        try await assertNeverAdvancedInto(20, rig, completed: [19])
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(21), "the run continues with 21")
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertEqual(rig.recorder.finishes, 0, "skipping 20 is not a stop")
        await rig.model.close()
    }

    // MARK: - Newer commands cancel a delayed advance

    /// A manual selection made right after EOF, before the controller's
    /// advance has looked anything up, wins: 18 plays and stays current.
    func testANewerSelectionDuringTheQueueAdvanceWins() async throws {
        let rig = try await makeRig("forward-newer-select", middle: .ready)
        try await startQueue(rig, at: 19)

        let selected = try rig.episode(18)
        try await finish(rig) { rig.model.playEpisode(selected) }

        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(18), "the newer selection is what plays")
        XCTAssertTrue(rig.backend.isPlaying)
        try await assertNeverAdvancedInto(20, rig, completed: [19])
        let selectedKind = try await rig.store.removalKind(for: try XCTUnwrap(rig.ids[18]))
        XCTAssertNil(selectedKind, "the selection is not retired by the old run's completion")
        await rig.model.close()
    }

    /// A Pause pressed right after EOF, before the advance loads 20, drops
    /// the advance: 19 stays loaded, paused and current, and 20 never loads.
    func testAPauseAfterTheEndCancelsTheQueueAdvance() async throws {
        let rig = try await makeRig("forward-pause", middle: .ready)
        try await startQueue(rig, at: 19)

        var pauseIssued = false
        try await finish(rig) {
            rig.model.pausePlayback()
            pauseIssued = rig.model.playbackCommands.pending?.command.kind == .pause
        }

        XCTAssertTrue(pauseIssued, "the Pause reached the command owner")
        try await assertNeverAdvancedInto(20, rig, completed: [19])
        XCTAssertFalse(rig.backend.isPlaying, "a Pause after the end must leave nothing playing")
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(19), "the finished episode stays current")
        XCTAssertEqual(rig.recorder.finishes, 0, "a held advance is not announced as the end of the queue")
        await rig.model.close()
    }

    /// The Larder-wide continuation (nothing queued behind a generic Play)
    /// must also yield to a newer selection made while it reloads rows.
    /// Expected to fail on lanes without 38dfe1a (3.1 hardening: the
    /// continuation runs under the playback owner's fence).
    func testANewerSelectionDuringTheLarderContinuationWins() async throws {
        let rig = try await makeRig("larder-newer-select", middle: .ready, queued: [])
        rig.model.libraryOrder = .oldest
        rig.model.playEpisode(try rig.episode(19))
        await rig.model.waitForPlaybackOperationForTesting()
        try await settle()
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(19))

        await rig.model.simulatePodcastPlaybackReachedEndForTesting()
        rig.model.simulatePodcastPlaybackFinishedForTesting()
        rig.model.playEpisode(try rig.episode(18))
        await rig.model.waitForPlaybackOperationForTesting()
        try await settle()

        XCTAssertLessThanOrEqual(rig.recorder.completed.filter { $0 == rig.id(19) }.count, 1)
        let finishedKind = try await rig.store.removalKind(for: try XCTUnwrap(rig.ids[19]))
        XCTAssertEqual(finishedKind, .retired, "19 is finished once, whichever command wins")
        let selectedKind = try await rig.store.removalKind(for: try XCTUnwrap(rig.ids[18]))
        XCTAssertNil(selectedKind, "the selection is not retired by the old run")
        let seen = "current=\(rig.label(rig.model.currentPodcastEpisodeID))"
        XCTExpectFailure("3.1 concern: the LibraryLoading continuation calls playEpisode after its own awaits, " +
            "outside the playback owner's fence; passes once merged with 38dfe1a [\(seen)]", options: Self.nonStrict)
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(18), "the newer selection is what plays")
        await rig.model.close()
    }

    // MARK: - Rig

    private static var nonStrict: XCTExpectedFailure.Options {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        return options
    }

    private func makeRig(_ name: String, middle: Middle, queued: [Int] = [19, 20, 21]) async throws -> Rig {
        let directory = wiltedTemporaryDirectory(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/\(name).xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        var ids: [Int: ItemID] = [:]
        var enclosures: [Int: URL] = [:]
        for number in 18...21 {
            let enclosure = try XCTUnwrap(URL(string: "https://media.example.test/\(name)-\(number).mp3"))
            enclosures[number] = enclosure
            ids[number] = try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "\(name)-\(number)", enclosureURL: enclosure)
        }
        let queue = try queued.map { try XCTUnwrap(ids[$0]) }
        let seededIDs = ids, seededEnclosures = enclosures
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, storeBootstrap: { url in
            let store = try LocalLibraryStore(url: url)
            try await store.save(feed: try PodcastFeed(
                itemID: feedID, canonicalURL: feedURL, title: "Forward", createdAt: created))
            try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
            for number in 18...21 {
                let id = seededIDs[number]!, guid = "\(name)-\(number)", enclosure = seededEnclosures[number]!
                let published = created.date.addingTimeInterval(Double(number) * 60)
                if number == 20, middle == .unprepared {
                    try await WiltedMacModelTests.addDownloadedUnpreparedEpisode(
                        id, guid: guid, feedID: feedID, feedURL: feedURL, enclosureURL: enclosure,
                        publishedAt: published, directory: directory, store: store, created: created)
                    continue
                }
                try await WiltedMacModelTests.addReadyEpisode(
                    id, guid: guid, feedID: feedID, feedURL: feedURL, enclosureURL: enclosure,
                    publishedAt: published, directory: directory, store: store, created: created)
                if number == 20, middle == .missing {
                    try FileManager.default.removeItem(at: directory.appendingPathComponent("\(guid).m4a"))
                }
                if number == 20, middle == .retired { _ = try await store.retireEpisode(id) }
            }
            try await store.replacePodcastQueue(PodcastQueueState(episodeIDs: queue, currentEpisodeID: queue.first))
            return store
        }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        try await settle()
        let backend = WiltedFixturePlaybackBackend()
        model.installPlaybackBackendForTesting(backend)
        let playback = try XCTUnwrap(model.playback)
        let recorder = Recorder()
        let observe = playback.podcastStateHandler
        playback.podcastStateHandler = { itemID, fault in
            recorder.observed.append(itemID?.rawValue ?? "nil")
            observe?(itemID, fault)
        }
        let complete = playback.podcastCompletionHandler
        playback.podcastCompletionHandler = { itemID in
            recorder.completed.append(itemID.rawValue)
            complete?(itemID)
        }
        let finished = playback.playbackDidFinishHandler
        playback.playbackDidFinishHandler = {
            recorder.finishes += 1
            finished?()
        }
        return Rig(model: model, store: try XCTUnwrap(model.store), ids: ids, recorder: recorder, backend: backend)
    }

    /// The safety half of a cancelled or refused advance, asserted outside
    /// any expected failure: `number` was never announced, loaded or made the
    /// durable current entry, and only `completed` finished.
    private func assertNeverAdvancedInto(
        _ number: Int, _ rig: Rig, completed: [Int], file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let id = try XCTUnwrap(rig.ids[number])
        XCTAssertFalse(rig.recorder.observed.contains(id.rawValue), "\(number) was announced", file: file, line: line)
        XCTAssertNotEqual(rig.model.playback?.itemID, id, "\(number) was loaded", file: file, line: line)
        let durable = try await rig.store.podcastQueueState().currentEpisodeID
        XCTAssertNotEqual(durable, id, "\(number) became the durable current entry", file: file, line: line)
        XCTAssertEqual(rig.recorder.completed, completed.map { rig.id($0) }, "completions", file: file, line: line)
    }

    /// A Larder-origin start of `number`, so the run follows the queue.
    private func startQueue(_ rig: Rig, at number: Int) async throws {
        rig.model.playLarderEpisode(try rig.episode(number))
        await rig.model.waitForPlaybackOperationForTesting()
        try await settle()
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.id(number))
        XCTAssertTrue(rig.backend.isPlaying)
        rig.recorder.observed.removeAll()
    }

    /// EOF on the loaded generation, `times` times in one turn, then `after`
    /// in the same turn: before the controller's completion work has run.
    private func finish(
        _ rig: Rig, times: Int = 1, after: () -> Void = {}
    ) async throws {
        let completion = try XCTUnwrap(rig.backend.completionHandler)
        let generation = rig.backend.loadedGeneration
        rig.backend.pause()
        for _ in 0..<times { completion(generation, true) }
        after()
        await rig.model.waitForPlaybackOperationForTesting()
        try await settle()
    }

    private func settle(iterations: Int = 60) async throws {
        for _ in 0..<iterations {
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
