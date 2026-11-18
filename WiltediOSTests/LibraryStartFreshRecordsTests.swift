import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// The in-memory transport whose read of one episode's records can be counted, delayed or failed.
private struct StartRecordsTransport: LibraryTransport {
    enum Mode { case answers, held, fails }

    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var _mode = Mode.answers
        private var _reads = 0
        private var _toldDevices: Set<String>?
        private var _toldEntries: Set<ItemID> = []
        var mode: Mode { get { lock.withLock { _mode } } set { lock.withLock { _mode = newValue } } }
        private var _publishFails = false
        /// True while the phone has no connection for its own writes.
        var publishFails: Bool { get { lock.withLock { _publishFails } } set { lock.withLock { _publishFails = newValue } } }
        var reads: Int { lock.withLock { _reads } }
        var toldEntries: Set<ItemID> { lock.withLock { _toldEntries } }
        func noteRead() { lock.withLock { _reads += 1 } }
        private var _waiting: [CheckedContinuation<Void, Never>] = []
        private var _released = false
        /// Returns once the test calls `release()`.
        func untilReleased() async {
            await withCheckedContinuation { continuation in
                let released = lock.withLock { () -> Bool in
                    if !_released { _waiting.append(continuation) }
                    return _released
                }
                if released { continuation.resume() }
            }
        }
        func release() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                _released = true
                defer { _waiting = [] }
                return _waiting
            }
            waiting.forEach { $0.resume() }
        }
        /// From here on a read covers only this device and the devices the transport was told of,
        /// as a CloudKit transport's does in a new process that has fetched no record yet.
        func becomeANewProcess() { lock.withLock { _toldDevices = [] } }
        func tell(devices: [String], entries: [ItemID]) {
            lock.withLock { _toldDevices?.formUnion(devices); _toldEntries.formUnion(entries) }
        }
        func visible(_ records: LibraryDeviceRecords) -> LibraryDeviceRecords {
            guard let told = lock.withLock({ _toldDevices }) else { return records }
            func known(_ observed: ObservedPlayback) -> Bool { observed.record.deviceID == "phone" || told.contains(observed.record.deviceID) }
            return LibraryDeviceRecords(nowPlaying: records.nowPlaying.filter(known), progress: records.progress.filter(known))
        }
    }

    let inner: InMemoryLibraryTransport
    let control: Control

    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await inner.mediaOffers() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        if control.publishFails { throw LibraryTransportError.transport("offline") }
        try await inner.publish(record, as: channel)
    }
    func track(devices: [String], entries: [ItemID]) async { control.tell(devices: devices, entries: entries) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { control.visible(try await inner.fetchDeviceRecords()) }
    func fetchDeviceRecords(entries: Set<ItemID>) async throws -> LibraryDeviceRecords {
        control.noteRead()
        switch control.mode {
        case .answers: break
        case .held: await control.untilReleased()
        case .fails: throw LibraryTransportError.transport("offline")
        }
        return control.visible(try await inner.fetchDeviceRecords(entries: entries))
    }
}

/// A row start reads the episode's records fresh (2026-11-18): the phone's last sync can be five
/// minutes old, or older than the Mac's listening when the row is pressed right after the app opens,
/// and the start then used an old position or none.
@MainActor
final class LibraryStartFreshRecordsTests: XCTestCase {
    private struct Rig {
        let model: LibraryAppModel
        let player: LibraryPlayer
        let mac: InMemoryLibraryTransport
        let control: StartRecordsTransport.Control

        @MainActor func row() throws -> LibraryRow { try XCTUnwrap(model.queued.first { $0.id.rawValue == "a" }) }
    }

    private var scratch: URL!
    private let entryID = try! ItemID(rawValue: "a")
    private let revision = try! RevisionID(rawValue: "rev-1")

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("start-fresh-records-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    /// One hour-long episode queued and on the phone, synced once before anything was played anywhere.
    private func makeRig(wait: Duration = .seconds(5), resumeReadAfterPause: TimeInterval = SyncCadence.tickInterval) async throws -> Rig {
        let suite = "wilted.start-records.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let show = LibrarySource(id: try ItemID(rawValue: "show"), kind: .podcastFeed, title: "The Show")
        let changes: [LibraryChange] = [
            .source(show),
            .entry(try LibraryEntry(
                id: entryID, kind: .podcastEpisode, sourceID: show.id, title: "Episode A", summary: "",
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: 3_600)),
            .slot(try QueueSlot(entryID: entryID, sortKey: 0)),
        ]
        _ = try await mac.push(changes: changes.enumerated().map {
            PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })
        try await mac.publishPublication(try LibraryPublication(id: "pub-1", publishedAt: Date(), writerDeviceID: "mac"))
        let control = StartRecordsTransport.Control()
        let phone = StartRecordsTransport(
            inner: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
            control: control)
        let mirror = FileLibraryStore(url: scratch.appendingPathComponent("mirror.json"))
        try await PreparedMediaFixture.bootstrap(mirror, transport: phone)
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let payload = Data((0..<2_000).map { UInt8($0 % 251) })
        let file = scratch.appendingPathComponent("audio")
        try payload.write(to: file)
        _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: file, for: try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: entryID, revisionID: revision,
            contentHash: MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 3_600)), owner: "fixture-owner")
        let engine = AutoEngine()
        engine.duration = 3_600
        let player = LibraryPlayer(
            engine: engine, session: AutoSession(), nowPlaying: AutoNowPlaying(),
            remoteCommands: AutoRemote(), sessionEvents: AutoEvents(), tickInterval: .seconds(3600))
        let model = LibraryAppModel(
            transport: phone, store: mirror, deviceID: "phone", mediaCache: cache,
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval, sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                settleSleep: { _ in }, startRecordsWait: wait, resumeReadAfterPause: resumeReadAfterPause, resumeRecordsWait: wait),
            preferences: defaults, now: { Date() })
        model.attachPlayer(player)
        await model.refresh()
        return Rig(model: model, player: player, mac: mac, control: control)
    }

    /// The Mac pausing at `position`, as its handoff controller publishes it.
    private func macPauses(_ rig: Rig, at position: Double, epoch: Int) async throws {
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: entryID, revision: revision, positionSeconds: position, rate: 1,
            isPlaying: false, epoch: epoch, publishedAt: Date())
        try await rig.mac.publish([(record, .nowPlaying), (record, .progress)])
    }

    private func phoneRecord(_ rig: Rig) async throws -> DevicePlaybackPosition {
        let records = try await rig.mac.fetchDeviceRecords()
        return try XCTUnwrap(records.nowPlaying.first { $0.record.deviceID == "phone" }?.record)
    }

    func testARowPressedBeforeTheSyncSawTheMacsPauseStartsAtThatPause() async throws {
        let rig = try await makeRig()
        try await macPauses(rig, at: 3_130, epoch: 480)

        let outcome = await rig.model.playCached(try rig.row())
        await rig.model.waitForHandoff()

        XCTAssertEqual(outcome, .resumed)
        XCTAssertEqual(rig.player.position, 3_130)
        XCTAssertEqual(rig.player.status, .playing)
        // The phone takes over from there, so the Mac is never handed a position near the start.
        let published = try await phoneRecord(rig)
        XCTAssertEqual(published.positionSeconds, 3_130)
        XCTAssertEqual(published.epoch, 481)
    }

    func testARowPressedAfterTheMacMovedOnStartsAtTheNewerPosition() async throws {
        let rig = try await makeRig()
        try await macPauses(rig, at: 500, epoch: 3)
        await rig.model.refresh()
        try await macPauses(rig, at: 900, epoch: 4)

        await rig.model.playCached(try rig.row())

        XCTAssertEqual(rig.player.position, 900)
    }

    func testAStartDoesNotWaitForRecordsThatAreSlow() async throws {
        let rig = try await makeRig(wait: .milliseconds(20))
        try await macPauses(rig, at: 500, epoch: 3)
        await rig.model.refresh()
        try await macPauses(rig, at: 900, epoch: 4)
        rig.control.mode = .held

        await rig.model.playCached(try rig.row())   // returns while the read is still unanswered

        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 500, "the last position the phone synced")
        // The late answer is still kept for the next start.
        rig.control.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while rig.model.resumeStart(for: entryID, cachedRevision: revision) != 900, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(rig.model.checkpoints[entryID]?.record.positionSeconds, 900)
    }

    func testAStartWithNoConnectionUsesWhatThePhoneLastSynced() async throws {
        let rig = try await makeRig()
        try await macPauses(rig, at: 500, epoch: 3)
        await rig.model.refresh()
        rig.control.mode = .fails

        let began = ContinuousClock.now
        await rig.model.playCached(try rig.row())

        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2), "a failed read ends the wait at once")
        XCTAssertEqual(rig.player.position, 500)
        XCTAssertEqual(rig.player.status, .playing)
    }

    func testThePhonesOwnNewerPauseStillWinsOverAnOlderMacRecord() async throws {
        let rig = try await makeRig()
        try await macPauses(rig, at: 500, epoch: 3)
        await rig.model.playCached(try rig.row())   // the phone takes over at epoch 4 from 500
        await rig.model.waitForHandoff()
        rig.player.seek(to: 1_200)
        await rig.model.waitForHandoff()
        rig.player.pause()
        await rig.model.waitForHandoff()
        rig.player.stop()
        await rig.model.waitForHandoff()

        await rig.model.playCached(try rig.row())

        XCTAssertEqual(rig.player.position, 1_200)
    }

    // MARK: A relaunched phone

    /// David's report, 2026-11-18: the Mac paused at 52:11 and went idle, the phone app was opened
    /// two hours later in a new process, and the episode started from the beginning.
    func testARelaunchedPhoneWhoseMacWentIdleStartsWhereTheMacPaused() async throws {
        let rig = try await makeRig()
        try await macPauses(rig, at: 3_130, epoch: 480)
        rig.control.becomeANewProcess()
        await rig.model.refresh()   // the round a launch runs

        XCTAssertEqual(rig.model.checkpoints[entryID]?.record.positionSeconds, 3_130, "the round still reads the Mac")
        await rig.model.playCached(try rig.row())

        XCTAssertEqual(rig.player.position, 3_130)
    }

    func testARowPressedBeforeARelaunchedPhonesFirstRoundStartsWhereTheMacPaused() async throws {
        let rig = try await makeRig()
        try await macPauses(rig, at: 3_130, epoch: 480)
        rig.control.becomeANewProcess()

        await rig.model.playCached(try rig.row())

        XCTAssertEqual(rig.player.position, 3_130)
    }

    func testARoundNamesTheEpisodesThePhoneHoldsOtherDevicesPositionsFor() async throws {
        let rig = try await makeRig()
        try await macPauses(rig, at: 3_130, epoch: 480)
        await rig.model.refresh()   // saves the Mac's position
        XCTAssertFalse(rig.control.toldEntries.contains(entryID))

        await rig.model.refresh()

        XCTAssertTrue(rig.control.toldEntries.contains(entryID), "so a later round reads it even after the Mac moves on")
    }

    func testResumingTheLoadedEpisodeAndAnAutomaticStartReadNothing() async throws {
        let rig = try await makeRig()
        let row = try rig.row()
        let automatic = await rig.model.startCached(row, kind: .automatic)
        XCTAssertEqual(automatic, .started)
        XCTAssertEqual(rig.control.reads, 0, "auto-continue follows a round that is at most one tick old")
        rig.player.pause()
        await rig.model.waitForHandoff()
        let readsWhilePlaying = rig.control.reads

        let outcome = await rig.model.playCached(row)

        XCTAssertEqual(outcome, .resumed)
        XCTAssertEqual(rig.control.reads, readsWhilePlaying, "a resume of the loaded episode starts nothing new")
    }

    // MARK: Resuming the loaded, paused episode

    /// The phone plays the episode from its row, moves to `position` and pauses there.
    private func phonePauses(_ rig: Rig, at position: Double) async throws {
        await rig.model.playCached(try rig.row())
        await rig.model.waitForHandoff()
        rig.player.seek(to: position)
        rig.player.pause()
        await rig.model.waitForHandoff()
        try await Task.sleep(for: .milliseconds(50))   // what another device does next is later on every clock
    }

    /// The Mac takes the episode over after the phone and stops at `position`.
    private func macPlaysOn(_ rig: Rig, to position: Double) async throws -> Int {
        let epoch = try await phoneRecord(rig).epoch + 1
        try await macPauses(rig, at: position, epoch: epoch)
        return epoch
    }

    /// A play command from the lock screen, the car or a headset: through the player's admission.
    private func remotePlay(_ rig: Rig) async {
        rig.player.authorizePlayback = { _ in true }
        rig.player.play()
        await rig.player.admissionTask?.value
        await rig.model.waitForHandoff()
    }

    func testPlayOnAPausedEpisodeTheMacPlayedOnResumesWhereTheMacStopped() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        try await phonePauses(rig, at: 600)
        let macEpoch = try await macPlaysOn(rig, to: 1_500)

        await remotePlay(rig)

        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 1_500)
        // The phone takes over from there, so the Mac is not handed the phone's older place.
        let published = try await phoneRecord(rig)
        XCTAssertEqual(published.positionSeconds, 1_500)
        XCTAssertEqual(published.epoch, macEpoch + 1)
    }

    func testARowPressedOnAPausedEpisodeTheMacPlayedOnResumesWhereTheMacStopped() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        try await phonePauses(rig, at: 600)
        _ = try await macPlaysOn(rig, to: 1_500)

        let outcome = await rig.model.playCached(try rig.row())

        XCTAssertEqual(outcome, .resumed)
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 1_500)
    }

    func testAQuickPauseAndPlayReadsNothingAndStaysPut() async throws {
        let rig = try await makeRig()
        try await phonePauses(rig, at: 600)
        _ = try await macPlaysOn(rig, to: 1_500)
        let reads = rig.control.reads

        await remotePlay(rig)

        XCTAssertEqual(rig.control.reads, reads, "no other device takes an episode over and plays it on within one sync tick")
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 600)
    }

    func testASkipMadeWhilePausedAfterTheMacStoppedKeepsThePhonesPlace() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        try await phonePauses(rig, at: 600)
        _ = try await macPlaysOn(rig, to: 1_500)
        try await Task.sleep(for: .milliseconds(50))
        rig.player.seek(to: 630)   // the listener chose this place after the Mac stopped

        await remotePlay(rig)

        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 630)
    }

    func testAMacRecordWrittenBeforeThePhonePausedNeverMovesIt() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        await rig.model.playCached(try rig.row())
        await rig.model.waitForHandoff()
        // Outranks the phone's session, but was written before the phone paused.
        try await macPauses(rig, at: 300, epoch: try await phoneRecord(rig).epoch + 5)
        try await Task.sleep(for: .milliseconds(50))
        rig.player.seek(to: 1_200)
        rig.player.pause()
        await rig.model.waitForHandoff()

        await remotePlay(rig)

        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 1_200)
    }

    func testAResumeWithNoConnectionOrASlowOneStaysPutAndPlays() async throws {
        let rig = try await makeRig(wait: .milliseconds(20), resumeReadAfterPause: 0)
        try await phonePauses(rig, at: 600)
        _ = try await macPlaysOn(rig, to: 1_500)
        rig.control.mode = .fails
        await remotePlay(rig)
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 600)

        rig.player.pause()
        await rig.model.waitForHandoff()
        rig.control.mode = .held
        await remotePlay(rig)   // returns while the read is still unanswered
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 600)
        rig.control.release()
    }

    func testAPauseCommandDuringTheReadLeavesTheEpisodePausedWhereItWas() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        try await phonePauses(rig, at: 600)
        _ = try await macPlaysOn(rig, to: 1_500)
        rig.control.mode = .held
        rig.player.authorizePlayback = { _ in true }
        rig.player.play()
        let admission = rig.player.admissionTask
        await Task.yield()

        rig.player.pause()   // cancels the pending play
        rig.control.release()
        await admission?.value

        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertEqual(rig.player.position, 600)
    }

    /// The Mac offers its stored position at the epoch it last saw, without having played: a later
    /// date at the phone's own epoch. It can do so after a pause the phone could not publish.
    func testAMacPositionOfferedWithoutATakeoverNeverRewindsAPauseThePhoneCouldNotPublish() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        await rig.model.playCached(try rig.row())
        await rig.model.waitForHandoff()
        let phoneEpoch = try await phoneRecord(rig).epoch
        rig.control.publishFails = true   // no signal from here on
        rig.player.seek(to: 1_200)
        rig.player.pause()
        await rig.model.waitForHandoff()
        try await Task.sleep(for: .milliseconds(50))
        let stored = try DevicePlaybackPosition(
            deviceID: "mac", entryID: entryID, revision: revision, positionSeconds: 300, rate: 1,
            isPlaying: false, epoch: phoneEpoch, publishedAt: Date())
        try await rig.mac.publish(stored, as: .progress)

        await remotePlay(rig)

        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 1_200)
    }

    /// The whole phone session ran with no signal, so even its takeover never reached the server.
    func testAMacPositionOfferedAgainNeverRewindsASessionThePhoneCouldNotPublish() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        try await macPauses(rig, at: 300, epoch: 7)
        await rig.model.refresh()
        rig.control.publishFails = true   // no signal for the phone's writes from here on
        await rig.model.playCached(try rig.row())
        await rig.model.waitForHandoff()
        rig.player.seek(to: 1_200)
        rig.player.pause()
        await rig.model.waitForHandoff()
        try await Task.sleep(for: .milliseconds(50))
        let stored = try DevicePlaybackPosition(
            deviceID: "mac", entryID: entryID, revision: revision, positionSeconds: 300, rate: 1,
            isPlaying: false, epoch: 7, publishedAt: Date())
        try await rig.mac.publish(stored, as: .progress)

        await remotePlay(rig)

        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 1_200)
    }

    // MARK: A row pressed on the paused episode, while its records are read

    /// A row press on the paused episode with the read of its records held open.
    private func rowPressedWithTheReadHeld(_ rig: Rig) async throws -> Task<LibraryStartOutcome, Never> {
        rig.control.mode = .held
        let reads = rig.control.reads
        let row = try rig.row()
        let press = Task { @MainActor in await rig.model.playCached(row) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while rig.control.reads == reads, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(rig.control.reads, reads + 1, "the press is waiting on the read")
        return press
    }

    func testAPauseFromTheLockScreenWhileARowPressReadsLeavesTheEpisodePaused() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        try await phonePauses(rig, at: 600)
        _ = try await macPlaysOn(rig, to: 1_500)
        let press = try await rowPressedWithTheReadHeld(rig)

        rig.player.pause()   // the lock screen: no row command, so the start's token is unchanged
        rig.control.release()
        let outcome = await press.value

        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertEqual(rig.player.position, 600)
    }

    func testASkipWhileARowPressReadsIsTheListenersNewerWord() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        try await phonePauses(rig, at: 600)
        _ = try await macPlaysOn(rig, to: 1_500)
        let press = try await rowPressedWithTheReadHeld(rig)

        rig.player.seek(to: 700)
        rig.control.release()
        let outcome = await press.value

        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertEqual(rig.player.position, 700)
    }

    func testAPlayFromTheLockScreenWhileARowPressReadsIsNotUndoneOrMoved() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        try await phonePauses(rig, at: 600)
        _ = try await macPlaysOn(rig, to: 1_500)
        let press = try await rowPressedWithTheReadHeld(rig)

        XCTAssertTrue(rig.player.playAdmitted())
        rig.control.release()
        let outcome = await press.value

        XCTAssertEqual(outcome, .superseded, "the player's own command replaced the row press")
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertEqual(rig.player.position, 600)
    }

    func testAStopWhileARowPressReadsStartsNothing() async throws {
        let rig = try await makeRig(resumeReadAfterPause: 0)
        try await phonePauses(rig, at: 600)
        _ = try await macPlaysOn(rig, to: 1_500)
        let press = try await rowPressedWithTheReadHeld(rig)

        rig.player.stop()
        rig.control.release()
        let outcome = await press.value

        XCTAssertEqual(outcome, .superseded)
        XCTAssertFalse(rig.player.isPlaying)
    }
}
