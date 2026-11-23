import Combine
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// Asserts CarPlay, Siri, and the Watch follow Mac order when `model.listOrder = .mac`
/// and preserve their existing behavior in `.playOrder`.
@MainActor
final class LibraryMacOrderSurfacesTests: XCTestCase {
    private let suite = "library-mac-order-surfaces-tests-\(UUID().uuidString)"
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mac-surfaces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private struct MacSurfacesRig {
        let model: LibraryAppModel
        let player: LibraryPlayer
        let voiceTarget: LibraryVoiceTarget
        let watchSource: LibraryWatchSource
    }

    /// Sets up a queue with:
    /// - Slot 0: `c0` (Show C), completed (first in queue)
    /// - Slot 1: `a1` (Show A), unstarted
    /// - Slot 2: `b1` (Show B), unstarted
    /// - Slot 3: `b2` (Show B), in-progress (not first in queue)
    /// All 4 episodes are downloaded to the phone.
    private func makeFixtureRig() async throws -> MacSurfacesRig {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let phoneTransport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        let store = FileLibraryStore(url: scratch.appendingPathComponent("mirror-\(UUID().uuidString).json"))
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache-\(UUID().uuidString)"))

        var changes: [LibraryChange] = [
            .source(LibrarySource(id: id("src-c"), kind: .podcastFeed, title: "Show C")),
            .source(LibrarySource(id: id("src-a"), kind: .podcastFeed, title: "Show A")),
            .source(LibrarySource(id: id("src-b"), kind: .podcastFeed, title: "Show B")),
        ]

        // Slot 0: c0 (Show C), completed
        changes.append(.entry(try LibraryEntry(
            id: id("c0"), kind: .podcastEpisode, sourceID: id("src-c"), title: "C0 Completed", summary: "",
            publishedAt: Date(timeIntervalSince1970: 500), durationSeconds: 600)))
        changes.append(.slot(try QueueSlot(entryID: id("c0"), sortKey: 0.0)))
        changes.append(.listening(ListeningRecord(
            itemID: id("c0"), completedAt: Date(timeIntervalSince1970: 5000),
            updatedAt: Date(timeIntervalSince1970: 5000), deviceID: "mac")))

        // Slot 1: a1 (Show A), unstarted
        changes.append(.entry(try LibraryEntry(
            id: id("a1"), kind: .podcastEpisode, sourceID: id("src-a"), title: "A1 Unstarted", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1000), durationSeconds: 600)))
        changes.append(.slot(try QueueSlot(entryID: id("a1"), sortKey: 1.0)))

        // Slot 2: b1 (Show B), unstarted
        changes.append(.entry(try LibraryEntry(
            id: id("b1"), kind: .podcastEpisode, sourceID: id("src-b"), title: "B1 Unstarted", summary: "",
            publishedAt: Date(timeIntervalSince1970: 2000), durationSeconds: 600)))
        changes.append(.slot(try QueueSlot(entryID: id("b1"), sortKey: 2.0)))

        // Slot 3: b2 (Show B), in-progress
        changes.append(.entry(try LibraryEntry(
            id: id("b2"), kind: .podcastEpisode, sourceID: id("src-b"), title: "B2 In Progress", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1500), durationSeconds: 600)))
        changes.append(.slot(try QueueSlot(entryID: id("b2"), sortKey: 3.0)))

        var localSeq: UInt64 = 0
        var versions: [LibraryRecordKey: UInt64] = [:]
        let pending = changes.map { change -> PendingLibraryChange in
            localSeq += 1
            return PendingLibraryChange(localSeq: localSeq, change: change, baseVersion: versions[change.key] ?? 0)
        }
        let pushResult = try await mac.push(changes: pending)
        XCTAssertTrue(pushResult.failures.isEmpty)

        // Downloaded through the real cache, so a refresh keeps every episode on the phone.
        try await PreparedMediaFixture.bootstrap(store, transport: phoneTransport)
        let payload = Data((0..<20_000).map { UInt8($0 % 251) })
        for raw in ["c0", "a1", "b1", "b2"] {
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try payload.write(to: file)
            let certified = try PreparedMediaFixture.certified(LibraryMediaOffer(
                entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"),
                contentHash: PreparedMediaFixture.hash(payload),
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600))
            try await mac.publishMedia(offer: certified, fileURL: file)
            _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: file, for: certified, owner: "fixture-owner")
        }

        try await mac.publish(
            try DevicePlaybackPosition(
                deviceID: "mac", entryID: id("b2"), revision: RevisionID(rawValue: "rev-1"),
                positionSeconds: 150, isPlaying: false, epoch: 1),
            as: .progress)

        let player = LibraryPlayer(
            engine: MacSurfacesFakeEngine(), session: MacSurfacesFakeSession(),
            nowPlaying: MacSurfacesFakeNowPlaying(), remoteCommands: MacSurfacesFakeRemote(),
            sessionEvents: MacSurfacesFakeEvents(), tickInterval: .seconds(3600))

        let defaults = UserDefaults(suiteName: suite)!
        let model = LibraryAppModel(
            transport: phoneTransport,
            store: store,
            deviceID: "phone",
            mediaCache: cache,
            mediaTiming: LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
            preferences: defaults,
            timeZone: TimeZone(identifier: "UTC")!)
        model.attachPlayer(player)
        await model.refresh()
        XCTAssertEqual(model.preparedIDs.onPhone, Set(["c0", "a1", "b1", "b2"].map(id)))

        let voiceTarget = LibraryVoiceTarget(model: model, player: player)
        let watchSource = LibraryWatchSource(model: model, player: player)
        return MacSurfacesRig(model: model, player: player, voiceTarget: voiceTarget, watchSource: watchSource)
    }

    private func episodeIDs(_ list: CarEpisodeList) -> [String] {
        guard case let .episodes(rows) = list.content else { return [] }
        return rows.map(\.id.rawValue)
    }

    // MARK: - Mac Order Tests (.mac)

    func testCarEpisodeListMacOrderListsOnPhoneRowsInQueueOrderWithCompletedLast() async throws {
        let rig = try await makeFixtureRig()
        rig.model.listOrder = .mac

        let list = CarEpisodeList.make(model: rig.model, playingID: nil)
        XCTAssertEqual(episodeIDs(list), ["a1", "b1", "b2", "c0"])
    }

    func testCarShowListMakeMacOrderListsShowsByFirstAppearanceWithoutPinning() async throws {
        let rig = try await makeFixtureRig()
        rig.model.listOrder = .mac

        let shows = CarShowList.make(
            rows: rig.model.queued, onPhone: rig.model.preparedIDs.onPhone,
            progress: rig.model.progress, finished: rig.model.finished,
            limit: 12, order: rig.model.listOrder)
        XCTAssertEqual(shows.map(\.title), ["Show A", "Show B", "Show C"])
    }

    func testCarShowListEpisodesMacOrderKeepsQueueOrderInsideShow() async throws {
        let rig = try await makeFixtureRig()
        rig.model.listOrder = .mac

        let list = CarShowList.episodes(
            of: .source(id("src-b")), rows: rig.model.queued, onPhone: rig.model.preparedIDs.onPhone,
            playingID: nil, progress: rig.model.progress, finished: rig.model.finished,
            limit: 12, order: rig.model.listOrder)
        XCTAssertEqual(episodeIDs(list), ["b1", "b2"])
    }

    func testSiriVoiceSnapshotMacOrderDownloadedStartsFirstNotCompletedAndKnownShowsFollowsListedOrder() async throws {
        let rig = try await makeFixtureRig()
        rig.model.listOrder = .mac

        let snapshot = await rig.voiceTarget.voiceSnapshot()
        XCTAssertEqual(snapshot.downloaded.map(\.id.rawValue), ["a1", "b1", "b2", "c0"])
        XCTAssertEqual(snapshot.downloaded.first?.id.rawValue, "a1")
        XCTAssertEqual(snapshot.knownShowTitles, ["Show A", "Show B", "Show C"])
    }

    func testWatchUpNextMacOrderFollowsSameOrder() async throws {
        let rig = try await makeFixtureRig()
        rig.model.listOrder = .mac

        let upNext = rig.watchSource.currentUpNext
        XCTAssertEqual(upNext.map(\.episodeID), ["a1", "b1", "b2", "c0"])
    }

    // MARK: - Default Order Tests (.playOrder)

    func testCarEpisodeListDefaultModeEqualsToday() async throws {
        let rig = try await makeFixtureRig()
        XCTAssertEqual(rig.model.listOrder, .playOrder)

        let list = CarEpisodeList.make(model: rig.model, playingID: nil)
        XCTAssertEqual(episodeIDs(list), ["b2", "a1", "b1", "c0"])
    }

    func testCarShowListMakeDefaultModeEqualsToday() async throws {
        let rig = try await makeFixtureRig()
        XCTAssertEqual(rig.model.listOrder, .playOrder)

        let shows = CarShowList.make(
            rows: rig.model.queued, onPhone: rig.model.preparedIDs.onPhone,
            progress: rig.model.progress, finished: rig.model.finished,
            limit: 12, order: rig.model.listOrder)
        XCTAssertEqual(shows.map(\.title), ["Show B", "Show A", "Show C"])
    }

    func testCarShowListEpisodesDefaultModeEqualsToday() async throws {
        let rig = try await makeFixtureRig()
        XCTAssertEqual(rig.model.listOrder, .playOrder)

        let list = CarShowList.episodes(
            of: .source(id("src-b")), rows: rig.model.queued, onPhone: rig.model.preparedIDs.onPhone,
            playingID: nil, progress: rig.model.progress, finished: rig.model.finished,
            limit: 12, order: rig.model.listOrder)
        XCTAssertEqual(episodeIDs(list), ["b2", "b1"])
    }

    func testSiriVoiceSnapshotDefaultModeEqualsToday() async throws {
        let rig = try await makeFixtureRig()
        XCTAssertEqual(rig.model.listOrder, .playOrder)

        let snapshot = await rig.voiceTarget.voiceSnapshot()
        XCTAssertEqual(snapshot.downloaded.map(\.id.rawValue), ["b2", "a1", "b1", "c0"])
        XCTAssertEqual(snapshot.downloaded.first?.id.rawValue, "b2")
        // The in-progress show first, then every queued show in queue order (Show C's episode is slot 0).
        XCTAssertEqual(snapshot.knownShowTitles, ["Show B", "Show C", "Show A"])
    }

    func testWatchUpNextDefaultModeEqualsToday() async throws {
        let rig = try await makeFixtureRig()
        XCTAssertEqual(rig.model.listOrder, .playOrder)

        let upNext = rig.watchSource.currentUpNext
        XCTAssertEqual(upNext.map(\.episodeID), ["b2", "a1", "b1", "c0"])
    }

    // MARK: - Change Observation & Source Assertions

    func testWatchBridgeChangesEmitsWhenModelListOrderChanges() async throws {
        let rig = try await makeFixtureRig()
        let expectation = expectation(description: "changes emits on model.listOrder change")
        var ready = false
        let cancellable = rig.watchSource.changes.sink { _ in
            if ready {
                expectation.fulfill()
            }
        }
        ready = true
        rig.model.listOrder = .mac
        await fulfillment(of: [expectation], timeout: 2.0)
        _ = cancellable
    }

    func testWatchBridgePublishesWhenModelListOrderChanges() async throws {
        let rig = try await makeFixtureRig()
        let session = MacSurfacesFakeWatchSession()
        let bridge = WatchBridge(
            session: session, target: MacSurfacesFakeWatchTarget(), source: rig.watchSource, sleepTimer: SleepTimer())
        bridge.start()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.completeActivation()
        await bridge.settlePendingPublish()

        let initialCount = session.contexts.count
        rig.model.listOrder = .mac
        await bridge.settlePendingPublish()

        XCTAssertGreaterThan(session.contexts.count, initialCount)
        let publishedUpNext = bridge.publishedSnapshot?.upNext.map(\.episodeID)
        XCTAssertEqual(publishedUpNext, ["a1", "b1", "b2", "c0"])
    }

    func testSourceAssertionsForCarPlaySceneDelegateAndOrderParameter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

        // CarPlaySceneDelegate.swift contains model.$listOrder
        let delegateURL = root.appendingPathComponent("WiltediOS/CarPlay/CarPlaySceneDelegate.swift")
        let delegateText = try String(contentsOf: delegateURL, encoding: .utf8)
        XCTAssertTrue(delegateText.contains("model.$listOrder"), "CarPlaySceneDelegate.swift must contain model.$listOrder")

        // CarEpisodeList.swift, CarShowList.swift, LibraryVoiceTarget.swift and WatchBridge.swift
        // each contain order: in their LibraryListing.rows call
        let filesToCheck = [
            "WiltediOS/CarPlay/CarEpisodeList.swift",
            "WiltediOS/CarPlay/CarShowList.swift",
            "WiltediOS/Siri/LibraryVoiceTarget.swift",
            "WiltediOS/Watch/WatchBridge.swift"
        ]

        // `[^)]*` keeps the match inside the call's own argument list, so a later, unrelated
        // `order:` cannot satisfy it; every call in the file must carry the argument.
        let regex = try NSRegularExpression(pattern: #"LibraryListing\.rows\([^)]*order:"#)
        let anyCall = try NSRegularExpression(pattern: #"LibraryListing\.rows\("#)
        for relativePath in filesToCheck {
            let fileURL = root.appendingPathComponent(relativePath)
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let whole = NSRange(text.startIndex..., in: text)
            let calls = anyCall.numberOfMatches(in: text, range: whole)
            XCTAssertGreaterThan(calls, 0, "\(relativePath) must call LibraryListing.rows")
            XCTAssertEqual(
                regex.numberOfMatches(in: text, range: whole), calls,
                "\(relativePath) must pass 'order:' in every LibraryListing.rows call")
        }
    }
}

// MARK: - Test Doubles

private final class MacSurfacesFakeEngine: ListenerAudioEngine, @unchecked Sendable {
    var duration = 600.0
    var currentTime = 0.0
    var isPlaying = false
    func load(url: URL) throws {}
    func load(url: URL, completionGeneration: UInt64) throws {}
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
}

private final class MacSurfacesFakeSession: ListenerAudioSession, @unchecked Sendable {
    func activate() throws {}
    func deactivate() {}
}

private final class MacSurfacesFakeNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func clear() {}
}

@MainActor
private final class MacSurfacesFakeRemote: LibraryRemoteCommands {
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) {}
    func setSkipIntervals(back: TimeInterval, forward: TimeInterval) {}
}

@MainActor
private final class MacSurfacesFakeEvents: LibrarySessionEvents {
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {}
}

@MainActor
private final class MacSurfacesFakeWatchSession: WatchSessionProtocol {
    var isSupported = true
    var activationState: WatchSessionActivationState = .notActivated
    var isPaired = false
    var isWatchAppInstalled = false
    weak var delegate: (any WatchSessionDelegate)?
    private(set) var contexts: [[String: Any]] = []

    func activate() {
        activationState = .inactive
    }

    func updateApplicationContext(_ context: [String: Any]) throws {
        contexts.append(context)
    }

    func completeActivation() {
        activationState = .activated
        delegate?.watchSessionDidActivate()
    }

    func watchStateChanged() { delegate?.watchSessionWatchStateDidChange() }
    func becomeInactive() { activationState = .inactive }
    func deactivate() { activationState = .notActivated }
    func receive(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {}
}

@MainActor
private final class MacSurfacesFakeWatchTarget: VoiceCommandTarget {
    func voiceSnapshot() async -> VoiceSnapshot {
        VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
    }

    func perform(_ action: VoiceAction) async -> VoiceOutcome {
        .done
    }
}
