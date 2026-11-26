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

private final class JournalLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
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
    private func tag(_ raw: String) -> String { PlaybackJournalRecord.itemTag(id(raw)) }

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
            ("the phone's own play of a", ["start-request kind=toggle item=\(tag("a"))"]),
            ("start of a", ["source=phone event=start item=\(tag("a"))", "position=0.0", "position-source=zero"]),
            ("explicit pause checkpoint", ["source=phone event=pause", "cause=explicit", "result=paused", "item=\(tag("a"))"]),
            ("remote pause", ["remote-command command=pause", "result=handled", "item=\(tag("a"))"]),
            ("Siri's mark", ["decision-begun action=markDone item=\(tag("a"))"]),
            ("a stopped", ["stop reason=withdraw trigger=queue-removed item=\(tag("a"))"]),
            ("finished here", ["finished-here action=remember item=\(tag("a"))"]),
            ("request sent", ["decision-sent action=markDone item=\(tag("a"))"]),
            ("second launch", ["launch build="]),
            ("remote play with nothing loaded", ["remote-command command=play", "loaded=false", "result=handled"]),
            ("the request that play made", ["start-request kind=select item=\(tag("b"))"]),
            ("start of b", ["source=phone event=start item=\(tag("b"))", "position=0.0", "position-source=zero"]),
            ("why b started", ["remote-resume command=play", "result=resumed", "item=\(tag("b"))"])
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
        let startLine = try XCTUnwrap(lines.last { $0.contains("event=start item=\(tag("a"))") })
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
        let startLine = try XCTUnwrap(lines.last { $0.contains("event=start item=\(tag("a"))") })
        XCTAssertTrue(startLine.contains("position=150.0"), "start position is 150.0: \(startLine)")
        XCTAssertTrue(startLine.contains("position-source=other-device"), "the Mac's position won: \(startLine)")
    }

    // MARK: - 3. Unit Tests

    func testNoteAppendsOneTimestampedLinePerCall() throws {
        let file = scratch.appendingPathComponent("unit-journal.log")
        let journal = LibraryJournal(url: file, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        journal.note("launch build=1.0.0")
        journal.note("stop reason=withdraw")

        let content = try String(contentsOf: file, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("schema=2 launch build=1.0.0"))
        XCTAssertTrue(lines[1].contains("schema=2 stop reason=withdraw"))

        let parts0 = lines[0].components(separatedBy: " ")
        XCTAssertEqual(parts0.count, 4)
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

    /// The third reading of the 17:32 report: Siri heard "play the next episode", which moves on
    /// without marking. The journal must show that it was a voice request and what it started.
    func testSirisPlayNextShowsAsAVoiceRequestThatStartedTheNextEpisode() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.refresh()
        try await start(rig, "a")

        _ = await VoiceCommandRunner.run(.playNext(show: nil), on: LibraryVoiceTarget(model: rig.model, player: rig.player))

        XCTAssertEqual(rig.player.item?.entryID, id("b"))
        XCTAssertFalse(rig.model.isFinishedHere(id("a")), "moving on marks nothing")
        try assertInOrder(journalLines(), [
            ("start of a", ["event=start item=\(tag("a"))"]),
            ("the voice request", ["voice-action"]),
            ("the start it asked for", ["start-request kind=select item=\(tag("b"))"]),
            ("where a was when b replaced it", ["stop reason=replaced item=\(tag("a")) position=0.0"]),
            ("start of b", ["event=start item=\(tag("b"))"]),
            ("its outcome", ["voice-action-outcome outcome=done"])
        ])
        XCTAssertFalse(try journalLines().contains { $0.contains("decision-begun") }, "no mark was made")
    }

    func testAPositionLookedUpForOneEpisodeIsNotReportedForAnother() async throws {
        try await seed()
        let rig = await launch()
        await rig.model.loadLocalState()
        rig.model.handoffState.ownPositions[id("a")] = ObservedPlayback(
            record: try DevicePlaybackPosition(
                deviceID: "phone", entryID: id("a"), revision: revision,
                positionSeconds: 98.0, isPlaying: false, epoch: 2,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_100)),
            serverModifiedAt: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(rig.model.resumeStart(for: id("a"), cachedRevision: revision), 98)

        XCTAssertEqual(rig.player.pendingPositionSource?.source, "own")
        let file = scratch.appendingPathComponent("b-direct.m4a")
        try payload.write(to: file)
        XCTAssertTrue(rig.player.start(LibraryPlayer.Item(entryID: id("b"), title: "Title b", showTitle: "", fileURL: file), at: 12))

        let startLine = try XCTUnwrap(try journalLines().last { $0.contains("event=start item=\(tag("b"))") })
        XCTAssertTrue(startLine.contains("position-source=unknown"), startLine)
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

    func testJournalRedactsTextAndPrivateIdentifiersBeforeFileAndOSLog() throws {
        let capture = JournalLogCapture()
        let privateEntry = try ItemID(rawValue: "private-entry-7d63")
        let privateOwner = "owner-private-58fa"
        let privateDevice = "Dave's iPhone 16"
        let journal = LibraryJournal(
            url: journalURL,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            logLine: { capture.append($0) })

        journal.note("start entry=\(privateEntry.rawValue) title=\"Secret episode title\" position=14.2 autoplay=true")
        journal.note("confirmation-asked question=\"Remove Private Show?\" owner=\(privateOwner) device=\"\(privateDevice)\" token=secret-token")
        journal.note(PlaybackJournalRecord(
            source: .phone, event: .routeLost, itemID: privateEntry,
            positionSeconds: 14.2, epoch: 3, cause: .routeLoss,
            result: .paused, isPlaying: false, speechHeld: true))

        let fileLines = try String(contentsOf: journalURL, encoding: .utf8)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(fileLines.count, 3)
        let fileBodies = fileLines.map { line in
            guard let separator = line.firstIndex(of: " ") else { return line }
            return String(line[line.index(after: separator)...])
        }
        XCTAssertEqual(capture.lines, fileBodies.map { PlaybackJournalPrivacy.publicLogLine(from: $0) })
        XCTAssertTrue(fileBodies[0].contains("item=\(PlaybackJournalRecord.itemTag(privateEntry))"))
        XCTAssertTrue(fileBodies[0].contains("position=14.2 autoplay=true"))
        XCTAssertTrue(fileBodies[1].contains("confirmation-asked"))
        XCTAssertFalse(fileBodies[1].contains("question="))
        XCTAssertTrue(fileBodies[2].contains("source=phone event=route-lost"))
        XCTAssertFalse(capture.lines.joined().contains(PlaybackJournalRecord.itemTag(privateEntry)), "OSLog must not expose joinable tags")
        XCTAssertFalse(capture.lines.joined().contains("position=14.2"), "OSLog omits listening position")
        let allOutput = fileLines.joined(separator: "\n") + capture.lines.joined(separator: "\n")
        for privateValue in [privateEntry.rawValue, privateOwner, privateDevice, "Secret episode title", "Private Show", "secret-token"] {
            XCTAssertFalse(allOutput.contains(privateValue), "diagnostics must not contain \(privateValue)")
        }
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let privateDirectory = scratch.appendingPathComponent("private-playback-v2", isDirectory: true)
        XCTAssertTrue(LibraryJournal.preparePrivateDirectory(at: privateDirectory))
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: privateDirectory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testV2ArchiveSecuresExistingFilesWithoutChangingTheSharedLogsDirectory() throws {
        let sharedLogs = scratch.appendingPathComponent("Logs", isDirectory: true)
        let privateDirectory = sharedLogs.appendingPathComponent("playback-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
        let url = privateDirectory.appendingPathComponent("playback-journal.log")
        let backup = url.appendingPathExtension("1")
        try Data("preserved old row\n".utf8).write(to: url)
        try Data("preserved backup row\n".utf8).write(to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sharedLogs.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: privateDirectory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: backup.path)
        let journal = LibraryJournal(url: url, logLine: { _ in })

        journal.note(PlaybackJournalRecord(source: .phone, event: .pause, result: .paused))

        func mode(_ path: URL) throws -> Int? {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue
        }
        XCTAssertEqual(try mode(sharedLogs), 0o755, "the shared Logs parent keeps its existing mode")
        XCTAssertEqual(try mode(privateDirectory), 0o700)
        XCTAssertEqual(try mode(url), 0o600)
        XCTAssertEqual(try mode(backup), 0o600)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("preserved old row\n"), "tightening permissions must preserve old evidence")
        XCTAssertTrue(contents.contains("event=pause"))
    }

    func testV2ArchiveDropsWriteWhenItsPrivateDirectoryCannotBeCreated() throws {
        let blockedParent = scratch.appendingPathComponent("not-a-directory")
        try Data("blocking parent".utf8).write(to: blockedParent)
        let url = blockedParent.appendingPathComponent("playback-v2/playback-journal.log")
        let capture = JournalLogCapture()
        let journal = LibraryJournal(url: url, logLine: { capture.append($0) })
        let itemID = id("private-blocked-phone-item")
        let record = PlaybackJournalRecord(source: .phone, event: .pause, itemID: itemID, positionSeconds: 42)

        journal.note(record)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(capture.lines, [record.publicLogLine])
        XCTAssertFalse(capture.lines.joined().contains(itemID.rawValue))
        XCTAssertFalse(capture.lines.joined().contains(PlaybackJournalRecord.itemTag(itemID)))
        XCTAssertFalse(capture.lines.joined().contains("position=42"))
    }
}
