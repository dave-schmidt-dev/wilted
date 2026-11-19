import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

private final class JournalTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_700_000_000
    var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

@MainActor
private final class JournalTestRemote: LibraryRemoteCommands {
    var handler: (@MainActor (LibraryRemoteCommand) -> Bool)?
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) { self.handler = handler }
}

@MainActor
final class LibraryJournalTests: XCTestCase {
    private var scratch: URL!
    private var journalURL: URL!
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
    private let revision = try! RevisionID(rawValue: "rev-1")
    private let payload = Data((0..<2_000).map { UInt8($0 % 251) })
    private let clock = JournalTestClock()
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var localSeq: UInt64 = 0
    private var cache: FileMediaCache!
    private var mirrorURL: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        journalURL = scratch.appendingPathComponent("playback-journal.log")
        cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        mirrorURL = scratch.appendingPathComponent("mirror.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private struct Rig {
        let model: LibraryAppModel
        let player: LibraryPlayer
        let engine: AutoEngine
        let remote: JournalTestRemote
        let runtime: LibraryRuntime
        let journal: LibraryJournal
    }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func macPush(_ changes: [LibraryChange]) async throws {
        let pending = changes.map { change -> PendingLibraryChange in
            localSeq += 1
            return PendingLibraryChange(localSeq: localSeq, change: change, baseVersion: versions[change.key] ?? 0)
        }
        let result = try await mac.push(changes: pending)
        XCTAssertTrue(result.failures.isEmpty)
        for ack in result.acknowledged { versions[ack.key] = ack.version }
    }

    private func entry(_ raw: String, removal: LibraryRemoval = .none) throws -> LibraryEntry {
        try LibraryEntry(
            id: id(raw), kind: .podcastEpisode, sourceID: id("show"), title: "Title \(raw)", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: 600, removal: removal,
            removedAt: removal == .none ? nil : clock.now)
    }

    private func seed() async throws {
        var changes: [LibraryChange] = [.source(LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show"))]
        for (offset, raw) in ["a", "b", "c"].enumerated() {
            changes.append(.entry(try entry(raw)))
            changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: Double(offset))))
        }
        try await macPush(changes)
        let bootstrap = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        try await PreparedMediaFixture.bootstrap(FileLibraryStore(url: mirrorURL), transport: bootstrap)
        for raw in ["a", "b", "c"] {
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try payload.write(to: file)
            let digest = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(
                entryID: id(raw), revisionID: revision, contentHash: digest,
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600))
            try await mac.publishMedia(offer: offer, fileURL: file)
            _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: file, for: offer, owner: "fixture-owner")
        }
    }

    private func launch(listOrder: LibraryListOrder = .mac) async -> Rig {
        let clock = clock
        let engine = AutoEngine()
        let remote = JournalTestRemote()
        let journal = LibraryJournal(url: journalURL, now: { clock.now })
        let player = LibraryPlayer(
            engine: engine, session: AutoSession(), nowPlaying: AutoNowPlaying(),
            remoteCommands: remote, sessionEvents: AutoEvents(), tickInterval: .seconds(3600))
        player.apply(LibraryPlaybackPreferences(
            defaultSpeed: 1.0, skipBackSeconds: 15, skipForwardSeconds: 30, autoPlayNext: true))
        player.journal = journal
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
            store: FileLibraryStore(url: mirrorURL), deviceID: "phone", mediaCache: cache,
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval,
                sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                settleSleep: { _ in }),
            ownPositionsURL: scratch.appendingPathComponent("own-positions.json"),
            outboxURL: scratch.appendingPathComponent("pending-intents.json"),
            finishedHereURL: scratch.appendingPathComponent("finished-here.json"),
            now: { clock.now }, timeZone: TimeZone(identifier: "UTC")!,
            journal: journal)
        model.listOrder = listOrder
        model.attachPlayer(player)
        let suite = "library-journal-suite-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = LibrarySettingsStore(defaults: defaults)
        let runtime = LibraryRuntime(model: model, player: player, settings: settings, journal: journal)
        runtime.installRemoteCommands()
        return Rig(model: model, player: player, engine: engine, remote: remote, runtime: runtime, journal: journal)
    }

    private func start(_ rig: Rig, _ raw: String) async throws {
        let row = try XCTUnwrap(rig.model.queued.first { $0.id == id(raw) })
        await rig.model.playCached(row)
        XCTAssertEqual(rig.player.item?.entryID, id(raw))
    }

    private func journalLines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        let content = try String(contentsOf: journalURL, encoding: .utf8)
        return content.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: - 1. Acceptance, 17:04-style

    func testAcceptance1704PlaybackAndDecisionJournalLifecycle() async throws {
        try await seed()

        // 1. Launch
        let rig = await launch()
        await rig.model.refresh()

        // 2. Start episode a
        try await start(rig, "a")

        // 3. Deliver a remote pause
        let pauseHandled = rig.player.handleRemote(.pause)
        XCTAssertTrue(pauseHandled)

        // 4. Siri mark completed
        let target = LibraryVoiceTarget(model: rig.model, player: rig.player)
        let line = await VoiceCommandRunner.run(.markCompleted, on: target)
        XCTAssertTrue(line.contains("Title a"))
        XCTAssertTrue(rig.model.isFinishedHere(id("a")))
        XCTAssertNil(rig.player.item)

        // 5. Relaunch (launch() then loadLocalState())
        let relaunched = await launch()
        await relaunched.model.loadLocalState()
        XCTAssertTrue(relaunched.model.isFinishedHere(id("a")))

        // 6. Deliver a remote play
        let playHandled = relaunched.player.handleRemote(.play)
        XCTAssertTrue(playHandled)

        // Wait for remote resume of b to complete and start
        for _ in 0..<100 where relaunched.player.item?.entryID != id("b") {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(relaunched.player.item?.entryID, id("b"))

        try assertInOrder(journalLines(), [
            ("first launch", ["launch build="]),
            ("start of a", ["start entry=a", "position=0.0", "position-source=zero"]),
            ("remote pause", ["remote-command command=pause", "result=handled", "entry=a"]),
            ("Siri's mark", ["voice-action", "markCompleted"]),
            ("decision begun", ["decision-begun", "entry=a"]),
            ("a stopped", ["stop reason=", "entry=a"]),
            ("finished here", ["finished-here action=remember entry=a"]),
            ("request sent", ["decision-sent action=markDone entry=a"]),
            ("second launch", ["launch build="]),
            ("remote play with nothing loaded", ["remote-command command=play", "loaded=false", "result=handled"]),
            ("start of b", ["start entry=b", "position=0.0", "position-source=zero"]),
            ("why b started", ["remote-resume command=play", "result=resumed", "entry=b"])
        ])
    }

    /// Asserts each step's line (one holding all its fragments) follows the step before it. A miss
    /// prints the whole journal, which is the evidence a reader would have.
    private func assertInOrder(
        _ lines: [String], _ steps: [(name: String, fragments: [String])], file: StaticString = #filePath, line: UInt = #line
    ) {
        var from = lines.startIndex
        for step in steps {
            guard let index = lines[from...].firstIndex(where: { text in step.fragments.allSatisfy { text.contains($0) } }) else {
                return XCTFail("no line for \(step.name) after line \(from):\n" + lines.joined(separator: "\n"), file: file, line: line)
            }
            from = index + 1
        }
    }

    // MARK: - 2. Acceptance, 23:05-style

    func testAcceptance2305AStartAtThePhonesOwnSavedPositionSaysSo() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.loadLocalState()
        rig.model.handoffState.ownPositions[id("a")] = ObservedPlayback(
            record: try DevicePlaybackPosition(
                deviceID: "phone", entryID: id("a"), revision: revision,
                positionSeconds: 98.0, isPlaying: false, epoch: 2,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_100)),
            serverModifiedAt: Date(timeIntervalSince1970: 1_700_000_100))

        try await start(rig, "a")

        let lines = try journalLines()
        let startLine = try XCTUnwrap(lines.last { $0.contains("start entry=a") })
        XCTAssertTrue(startLine.contains("position=98.0"), "start position is 98.0: \(startLine)")
        XCTAssertTrue(startLine.contains("position-source=own"), "position-source is own: \(startLine)")
    }

    func testAcceptance2305AStartAtTheMacsNewerPositionSaysSo() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.loadLocalState()
        let macRecord = try DevicePlaybackPosition(
            deviceID: "mac", entryID: id("a"), revision: revision, positionSeconds: 150.0, rate: 1,
            isPlaying: false, epoch: 3, publishedAt: clock.now)
        try await mac.publish([(macRecord, .nowPlaying), (macRecord, .progress)])
        await rig.model.refresh()
        rig.model.handoffState.ownPositions[id("a")] = ObservedPlayback(
            record: try DevicePlaybackPosition(
                deviceID: "phone", entryID: id("a"), revision: revision,
                positionSeconds: 50.0, isPlaying: false, epoch: 1,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            serverModifiedAt: Date(timeIntervalSince1970: 1_700_000_000))

        try await start(rig, "a")

        let lines = try journalLines()
        let startLine = try XCTUnwrap(lines.last { $0.contains("start entry=a") })
        XCTAssertTrue(startLine.contains("position=150.0"), "start position is 150.0: \(startLine)")
        XCTAssertTrue(startLine.contains("position-source=other-device"), "the Mac's position won: \(startLine)")
    }

    // MARK: - 3. Unit Tests

    func testNoteAppendsOneTimestampedLinePerCall() throws {
        let file = scratch.appendingPathComponent("unit-journal.log")
        let journal = LibraryJournal(url: file, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        journal.note("first-test-line")
        journal.note("second-test-line")

        let content = try String(contentsOf: file, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("first-test-line"))
        XCTAssertTrue(lines[1].contains("second-test-line"))

        let parts0 = lines[0].components(separatedBy: " ")
        XCTAssertEqual(parts0.count, 2)
        let formatter = ISO8601DateFormatter()
        XCTAssertNotNil(formatter.date(from: parts0[0]), "timestamp must be valid ISO8601")
    }

    func testNilJournalChangesNothing() async throws {
        try await seed()
        let engine = AutoEngine()
        let remote = JournalTestRemote()
        let player = LibraryPlayer(
            engine: engine, session: AutoSession(), nowPlaying: AutoNowPlaying(),
            remoteCommands: remote, sessionEvents: AutoEvents(), tickInterval: .seconds(3600))
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
            store: FileLibraryStore(url: mirrorURL), deviceID: "phone", mediaCache: cache,
            now: { Date() }, timeZone: TimeZone(identifier: "UTC")!)
        model.attachPlayer(player)
        await model.loadLocalState()

        XCTAssertNil(player.journal)
        XCTAssertNil(model.journal)

        let row = try XCTUnwrap(model.queued.first { $0.id == id("a") })
        await model.playCached(row)
        XCTAssertEqual(player.item?.entryID, id("a"))
        player.pause()
        XCTAssertEqual(player.status, .paused)
        player.stop()
        XCTAssertNil(player.item)
    }

    func testLinesCarryNoOwnerToken() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        try await start(rig, "a")
        rig.player.pause()

        let content = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertFalse(content.contains("fixture-owner"), "journal must never carry owner tokens")
        XCTAssertFalse(content.contains("token="), "journal must not carry token parameters")
    }
}
