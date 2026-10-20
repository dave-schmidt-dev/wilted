import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

/// Clicking Download on several Larder episodes in a row put some of them back
/// to Download a moment later, and a second click did nothing. The click paints
/// the row Queued at once but writes the durable download record several store
/// hops later; any reload in between repainted the row from the store, while
/// the live task made the second click a no-op. Meanwhile every network chunk
/// queued a main-actor update that re-sorted the whole Larder, which is the
/// stall that came with it.
@MainActor
final class WiltedMacDownloadReloadTests: XCTestCase {
    // MARK: - Surviving a library reload

    func testAQueuedRowSurvivesAReloadThatHasNoDownloadRecordYet() {
        let applied = WiltedMacModel.applyingInFlightDownloads(
            to: [episode("clicked", download: .notDownloaded)],
            from: [episode("clicked", download: .queued)], inFlight: ["clicked"]
        )

        XCTAssertEqual(applied.first?.downloadState, .queued)
    }

    /// A retry's row still carries the settled record it is replacing until the
    /// claim is written, so that record must not repaint it either.
    func testAQueuedRetrySurvivesTheFailedOrCancelledRecordItReplaces() {
        for settled in [WiltedMacEpisodeDownloadState.failed, .cancelled] {
            let applied = WiltedMacModel.applyingInFlightDownloads(
                to: [episode("retry", download: settled)],
                from: [episode("retry", download: .queued)], inFlight: ["retry"]
            )

            XCTAssertEqual(applied.first?.downloadState, .queued, "loaded \(settled)")
        }
        let transferring = WiltedMacModel.applyingInFlightDownloads(
            to: [episode("retry", download: .failed)],
            from: [episode("retry", download: .downloading(received: 5, expected: 10))], inFlight: ["retry"]
        )
        XCTAssertEqual(transferring.first?.downloadState, .downloading(received: 5, expected: 10))
    }

    /// The task's own reload is how a finished download reaches the row, and a
    /// durable in-flight record is the store's newer word on the transfer.
    func testALoadedCompletedOrInFlightRecordWins() {
        for loaded in [WiltedMacEpisodeDownloadState.completed, .queued,
                       .downloading(received: 7, expected: 10)] {
            let applied = WiltedMacModel.applyingInFlightDownloads(
                to: [episode("landing", download: loaded)],
                from: [episode("landing", download: .downloading(received: 3, expected: 10))],
                inFlight: ["landing"]
            )

            XCTAssertEqual(applied.first?.downloadState, loaded)
        }
    }

    /// Only a task this process is running is carried over, and a row its task
    /// already settled is handed back: a real failure is never hidden.
    func testARowWithNoLiveTaskOrASettledRowTakesTheLoadedState() {
        let noTask = WiltedMacModel.applyingInFlightDownloads(
            to: [episode("stale", download: .failed)],
            from: [episode("stale", download: .queued)], inFlight: []
        )
        XCTAssertEqual(noTask.first?.downloadState, .failed)

        let settled = WiltedMacModel.applyingInFlightDownloads(
            to: [episode("settled", download: .notDownloaded)],
            from: [episode("settled", download: .failed)], inFlight: ["settled"]
        )
        XCTAssertEqual(settled.first?.downloadState, .notDownloaded)
    }

    func testEverythingButTheInFlightDownloadComesFromTheReload() {
        let before = [
            episode("clicked", download: .queued, preparation: .notPrepared),
            episode("other", download: .queued)
        ]
        let loaded = [
            episode("clicked", download: .notDownloaded, preparation: .prepared(summary: "Ready")),
            episode("other", download: .notDownloaded),
            episode("new", download: .completed)
        ]

        let applied = WiltedMacModel.applyingInFlightDownloads(to: loaded, from: before, inFlight: ["clicked"])

        XCTAssertEqual(applied.map(\.id), ["clicked", "other", "new"])
        XCTAssertEqual(applied.map(\.downloadState), [.queued, .notDownloaded, .completed])
        XCTAssertEqual(applied.first?.preparationState, .prepared(summary: "Ready"))
    }

    // MARK: - The real click

    /// The race itself: a reload lands after the click and before the task has
    /// written its claim. The row stays Queued, and the transfer still settles.
    func testAReloadBeforeTheClaimIsWrittenKeepsTheRowQueuedUntilItLands() async throws {
        let body = Data("stub-audio-bytes".utf8)
        let rig = try makeRig("reload-before-claim") { enclosureURL in
            StubPodcastDownloadTransport(events: [
                .response(.init(url: enclosureURL, statusCode: 200, mediaType: "audio/mpeg",
                                 expectedByteCount: Int64(body.count))),
                .data(body)
            ])
        }
        let model = rig.model

        try await clickAndReloadBeforeTheClaim(model, rig.episodeID)
        await model.waitForPodcastOperations()

        XCTAssertEqual(row(model, rig.episodeID)?.downloadState, .completed)
        await model.close()
    }

    /// The carry-over must not outlive the task: a transfer that fails shows
    /// the failure, and the next reload keeps showing it.
    func testAFailedTransferAfterTheReloadStillShowsItsFailure() async throws {
        let rig = try makeRig("reload-then-fail") { enclosureURL in
            FailingPodcastDownloadTransport(enclosureURL: enclosureURL, statusCode: 503)
        }
        let model = rig.model

        try await clickAndReloadBeforeTheClaim(model, rig.episodeID)
        await model.waitForPodcastOperations()

        XCTAssertEqual(row(model, rig.episodeID)?.downloadState, .failed)
        XCTAssertNil(model.podcastDownloadTasks[rig.episodeID.rawValue])
        model.applyEpisodes(model.episodes)
        XCTAssertEqual(row(model, rig.episodeID)?.downloadState, .failed)
        await model.close()
    }

    // MARK: - Larder sort keys

    /// The sort now builds each id's key once. It must give exactly the order
    /// the per-comparison scan gave, including the first row winning for a
    /// duplicated id and an id with no row sorting on an empty key.
    func testTheLarderSortKeepsTheOrderThePerComparisonScanGave() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        model.episodes = [
            episode("a", title: "Charlie", released: base, duration: 300),
            episode("a", title: "Alpha", released: base.addingTimeInterval(500), duration: 100),
            episode("b", title: "Bravo", released: base.addingTimeInterval(100), duration: 900),
            episode("c", title: "Delta", released: base.addingTimeInterval(200), duration: 600)
        ]
        let ids = ["c", "missing", "a", "b"]
        model.larderSortDirection = .ascending

        XCTAssertEqual(model.sortedLarderEpisodeIDs(ids, by: .alphabetical), ["missing", "b", "a", "c"],
                       "the first row for a duplicated id supplies its key")
        for direction in [WiltedMacLarderSortDirection.ascending, .descending] {
            model.larderSortDirection = direction
            for current in [nil, "b", "a"] as [String?] {
                model.currentPodcastEpisodeID = current
                for sort in WiltedMacLarderSort.allCases {
                    XCTAssertEqual(model.sortedLarderEpisodeIDs(ids, by: sort), scannedOrder(model, ids, by: sort),
                                   "\(sort) \(direction) current=\(current ?? "none")")
                }
            }
        }
        model.currentPodcastEpisodeID = "b"
        model.larderSortDirection = .ascending
        XCTAssertEqual(model.sortedLarderEpisodeIDs(ids, by: .alphabetical), ["missing", "a", "c", "b"],
                       "the current item keeps its queue index")
    }

    // MARK: - Progress throttle

    /// A second of chunks, one every 5 ms, reaches the row about four times,
    /// and the last report it sees is the newest one.
    func testTheThrottleSendsAFewReportsASecondEndingOnTheNewest() {
        let reports = (0..<200).map { step in
            (progress(.transferring, Int64(step + 1) * 400, 80_000), Double(step) * 0.005)
        }

        let sent = delivered(reports, through: WiltedMacDownloadProgressThrottle())

        XCTAssertTrue((4...6).contains(sent.count), "about four a second, sent \(sent.count)")
        XCTAssertEqual(sent.last, reports.last?.0, "the bytes the transfer reached are shown")
    }

    /// The quit tests caught this: a transfer that sends one chunk and then
    /// waits must still show that chunk, though it came inside the interval.
    func testAReportHeldInsideTheIntervalStillReachesTheRow() {
        let sent = delivered([
            (progress(.queued, 0, 8_192), 0),
            (progress(.transferring, 0, 8_192), 0.001),
            (progress(.transferring, 0, 8_192), 0.002),
            (progress(.transferring, 4_096, 8_192), 0.003)
        ], through: WiltedMacDownloadProgressThrottle())

        XCTAssertEqual(sent.map(\.stage), [.queued, .transferring, .transferring])
        XCTAssertEqual(sent.map(\.bytesReceived), [0, 0, 4_096])
    }

    /// A new stage and completion go out at once, and a held report a newer
    /// one has already overtaken is never sent after it.
    func testANewStageAndCompletionGoOutAtOnceAndOvertakeAHeldReport() {
        let throttle = WiltedMacDownloadProgressThrottle()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(throttle.admit(progress(.transferring, 10, nil), at: start), .now)
        guard case .later = throttle.admit(progress(.transferring, 20, nil), at: start.addingTimeInterval(0.01)) else {
            return XCTFail("a report inside the interval is held")
        }
        XCTAssertEqual(throttle.admit(progress(.transferring, 30, nil), at: start.addingTimeInterval(0.02)), .coalesced)
        XCTAssertEqual(throttle.admit(progress(.validating, 30, nil), at: start.addingTimeInterval(0.03)), .now)
        XCTAssertNil(throttle.takeHeld(at: start.addingTimeInterval(0.26)), "the held report was overtaken")
        XCTAssertEqual(throttle.admit(progress(.completed, 30, nil), at: start.addingTimeInterval(0.27)), .now)
        XCTAssertEqual(throttle.admit(progress(.completed, 30, nil), at: start.addingTimeInterval(0.28)), .now)
    }

    /// A feed's declared size can undercount the file. Bytes past it must not
    /// read as the end of the transfer and reopen the flood.
    func testAnUndercountedTransferIsHeldToTheSameRate() {
        let reports = (0..<200).map { step in
            (progress(.transferring, Int64(step + 1) * 400, 1), Double(step) * 0.005)
        }

        let sent = delivered(reports, through: WiltedMacDownloadProgressThrottle())

        XCTAssertTrue((4...6).contains(sent.count), "sent \(sent.count)")
    }

    // MARK: - Fixtures

    private struct Rig {
        let model: WiltedMacModel
        let episodeID: ItemID
    }

    /// One subscribed episode in a real store, downloaded through the real
    /// coordinator over the given transport.
    private func makeRig(
        _ name: String,
        transport: @escaping @Sendable (URL) -> any PodcastDownloadTransporting
    ) throws -> Rig {
        let directory = wiltedTemporaryDirectory(name)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/\(name).xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/\(name).mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "\(name)-1", enclosureURL: enclosureURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Feed \(name)", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "\(name)-1",
                    title: "Episode \(name)", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                return store
            },
            podcastDownloadTransportFactory: { transport(enclosureURL) },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        return Rig(model: model, episodeID: episodeID)
    }

    /// Clicks Download and, with no suspension in between, applies the reload
    /// another episode's landing would: one with no record for this episode.
    private func clickAndReloadBeforeTheClaim(_ model: WiltedMacModel, _ episodeID: ItemID) async throws {
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)
        let episode = try XCTUnwrap(row(model, episodeID))
        XCTAssertEqual(episode.downloadState, .notDownloaded)

        model.downloadEpisode(episode)
        XCTAssertEqual(row(model, episodeID)?.downloadState, .queued)
        let reload = model.episodes.map { row -> WiltedMacEpisode in
            var value = row
            if value.id == episodeID.rawValue { value.downloadState = .notDownloaded }
            return value
        }
        model.applyEpisodes(reload)

        XCTAssertEqual(row(model, episodeID)?.downloadState, .queued, "the reload must not put Download back")
        XCTAssertNotNil(model.podcastDownloadTasks[episodeID.rawValue])
    }

    private func row(_ model: WiltedMacModel, _ episodeID: ItemID) -> WiltedMacEpisode? {
        model.episodes.first { $0.id == episodeID.rawValue }
    }

    /// The comparator the sort used before: a scan of `episodes` per side.
    private func scannedOrder(_ model: WiltedMacModel, _ ids: [String], by sort: WiltedMacLarderSort) -> [String] {
        guard sort != .custom else { return ids }
        func precedes(_ lhsID: String, _ rhsID: String) -> Bool {
            let lhs = model.episodes.first(where: { $0.id == lhsID }).map(WiltedMacEpisodeListOrder.key(for:))
                ?? LibraryEpisodeOrdering.Key(id: lhsID, title: "", durationSeconds: nil, publishedAt: nil)
            let rhs = model.episodes.first(where: { $0.id == rhsID }).map(WiltedMacEpisodeListOrder.key(for:))
                ?? LibraryEpisodeOrdering.Key(id: rhsID, title: "", durationSeconds: nil, publishedAt: nil)
            return LibraryEpisodeOrdering.precedes(
                lhs, rhs, sort: WiltedMacEpisodeListOrder.librarySort(sort),
                direction: WiltedMacEpisodeListOrder.libraryDirection(sort.legacyDirection ?? model.larderSortDirection)
            )
        }
        guard let currentID = model.currentPodcastEpisodeID, let index = ids.firstIndex(of: currentID) else {
            return ids.sorted(by: precedes)
        }
        var rest = ids
        rest.remove(at: index)
        var result = rest.sorted(by: precedes)
        result.insert(currentID, at: min(index, result.count))
        return result
    }

    /// Feeds reports through the throttle as the coordinator would, running
    /// each held delivery when its time comes, and returns what was sent on.
    private func delivered(
        _ reports: [(PodcastDownloadProgress, TimeInterval)], through throttle: WiltedMacDownloadProgressThrottle
    ) -> [PodcastDownloadProgress] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var sent: [PodcastDownloadProgress] = []
        var due: [TimeInterval] = []
        func runDeliveries(upTo time: TimeInterval) {
            while let next = due.first, next <= time {
                due.removeFirst()
                if let held = throttle.takeHeld(at: start.addingTimeInterval(next)) { sent.append(held) }
            }
        }
        for (report, offset) in reports {
            runDeliveries(upTo: offset)
            switch throttle.admit(report, at: start.addingTimeInterval(offset)) {
            case .now: sent.append(report)
            case .later(let delay): due.append(offset + delay)
            case .coalesced: break
            }
        }
        runDeliveries(upTo: .infinity)
        return sent
    }

    private func progress(_ stage: PodcastDownloadStage, _ received: Int64, _ expected: Int64?) -> PodcastDownloadProgress {
        PodcastDownloadProgress(stage: stage, bytesReceived: received, expectedByteCount: expected)
    }

    private func episode(
        _ id: String,
        download: WiltedMacEpisodeDownloadState,
        preparation: WiltedMacEpisodePreparationState = .notPrepared
    ) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: "\(id) title", feedTitle: "Show", summary: "Summary",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0,
            downloadState: download, preparationState: preparation
        )
    }

    /// A row whose title, publication date and length all differ, so every
    /// sort mode can tell a duplicated id's two rows apart.
    private func episode(_ id: String, title: String, released: Date, duration: Double) -> WiltedMacEpisode {
        var value = WiltedMacEpisode(
            id: id, title: title, feedTitle: "Show", summary: "Summary",
            artworkURL: nil, releasedAt: released, durationSeconds: duration, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Ready")
        )
        value.publishedAt = released
        value.sourceDurationSeconds = duration
        return value
    }
}
