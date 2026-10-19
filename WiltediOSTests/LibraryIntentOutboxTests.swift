import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// What the phone's `send(intent:)` does next, and every intent id it was asked to send.
final class OutboxSendScript: @unchecked Sendable {
    enum Mode: Sendable {
        case deliver
        /// The Mac is unreachable.
        case fail
        /// The Mac got it, but the answer never came back: the crash window between send and removal.
        case deliverThenFail
        /// Waits for `release()`, then delivers.
        case hold
    }

    private let lock = NSLock()
    private var current: Mode
    private var asked: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(_ mode: Mode) { current = mode }

    var mode: Mode {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var attempts: [String] { lock.withLock { asked } }

    func begin(_ intentID: String) -> Mode { lock.withLock { asked.append(intentID); return current } }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if released { return true }
                held.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            current = .deliver
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }
}

/// The in-memory transport with a scripted `send(intent:)`.
struct OutboxScriptedTransport: LibraryTransport {
    let base: InMemoryLibraryTransport
    let script: OutboxSendScript

    func send(intent: LibraryIntent) async throws {
        switch script.begin(intent.id) {
        case .deliver: try await base.send(intent: intent)
        case .fail: throw LibraryTransportError.transport("the Mac is unreachable")
        case .deliverThenFail:
            try await base.send(intent: intent)
            throw LibraryTransportError.transport("the answer was lost")
        case .hold:
            await script.waitForRelease()
            try await base.send(intent: intent)
        }
    }

    func verifiedOwnerToken() async -> String? { await base.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await base.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await base.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await base.push(changes: changes) }
    func listIntents() async throws -> [LibraryIntent] { try await base.listIntents() }
    func publishIntentOutcome(_ outcome: IntentOutcome) async throws { try await base.publishIntentOutcome(outcome) }
    func intentOutcomes() async throws -> [IntentOutcome] { try await base.intentOutcomes() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await base.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await base.fetchDeviceRecords() }
    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws { try await base.publishMedia(offer: offer, fileURL: fileURL) }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await base.mediaOffers() }
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        try await base.fetchMedia(offer, progress: progress)
    }
    func removeMedia(entryID: ItemID) async throws { try await base.removeMedia(entryID: entryID) }
    func publishStats(_ stats: LibraryStats) async throws { try await base.publishStats(stats) }
    func readStats() async throws -> LibraryStats? { try await base.readStats() }
    func publishTranscript(_ transcript: LibraryTranscript) async throws { try await base.publishTranscript(transcript) }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await base.transcript(entryID: entryID, revisionID: revisionID)
    }
    func removeTranscript(entryID: ItemID) async throws { try await base.removeTranscript(entryID: entryID) }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws { try await base.commitFetchedState(token) }
    func commitSentState(_ token: LibraryChangeToken?) async throws { try await base.commitSentState(token) }
}

/// The phone's durable outbox (audit IO-1): an unsent decision or Add is on disk before its send,
/// leaves only once the Mac has it, and a relaunch sends it once, with its own id. Every "relaunch"
/// is a new model over the same mirror and outbox files.
@MainActor
final class LibraryIntentOutboxTests: XCTestCase {
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let feed = URL(string: "https://feeds.example.com/show.xml")!
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var localSeq: UInt64 = 0
    private var scratch: URL!
    private var outboxURL: URL { scratch.appendingPathComponent("pending-intents.json") }
    private var mirrorURL: URL { scratch.appendingPathComponent("library-state.json") }
    private let suite = "library-intent-outbox-tests"

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-outbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outboxURL.path)
        try? FileManager.default.removeItem(at: scratch)
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    }

    // MARK: fixtures

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

    /// Larder: a, b, c in that order, all unfinished podcast episodes.
    private func seed() async throws {
        func entry(_ raw: String) throws -> LibraryEntry {
            try LibraryEntry(id: id(raw), kind: .podcastEpisode, sourceID: id("show"), title: "Title \(raw)", summary: "",
                             publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: 600)
        }
        try await macPush([
            .source(LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show")),
            .entry(try entry("a")), .entry(try entry("b")), .entry(try entry("c")),
            .slot(try QueueSlot(entryID: id("a"), sortKey: 0)),
            .slot(try QueueSlot(entryID: id("b"), sortKey: 1)),
            .slot(try QueueSlot(entryID: id("c"), sortKey: 2)),
        ])
    }

    /// One launch of the app: a new model over the same mirror and outbox.
    private func launch(_ script: OutboxSendScript, outbox: URL? = nil) -> LibraryAppModel {
        let now = now
        return LibraryAppModel(
            transport: OutboxScriptedTransport(
                base: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
                script: script),
            store: FileLibraryStore(url: mirrorURL), deviceID: "phone",
            decisionTiming: LibraryDecisionTiming(confirmationTimeout: 60),
            preferences: UserDefaults(suiteName: suite)!, outboxURL: outbox ?? outboxURL,
            now: { now }, timeZone: TimeZone(identifier: "UTC")!)
    }

    /// The intent ids on disk now.
    private func savedIDs() -> [String] {
        guard case let .saved(saved) = LibraryIntentOutbox(url: outboxURL).load() else { return [] }
        return saved.intentIDs.sorted()
    }

    private func serverIntentIDs() async throws -> [String] { try await mac.listIntents().map(\.id) }

    private func rows(_ model: LibraryAppModel) -> [String] { model.queued.map(\.id.rawValue) }

    // MARK: persist and remove-after-ack

    func testAnIntentIsOnDiskBeforeItsSendAndLeavesOnlyOnceTheTransportAcceptsIt() async throws {
        try await seed()
        let script = OutboxSendScript(.deliver)
        let model = launch(script)
        await model.refresh()
        script.mode = .hold

        model.performDecision(.removeFromLarder, entryID: id("b"))
        let sending = await waitOnClock { script.attempts.count == 1 }
        XCTAssertTrue(sending, "the send started")
        let pending = try XCTUnwrap(model.decisions.first)
        XCTAssertEqual(savedIDs(), [pending.id], "written before the send, while the Mac does not have it")
        XCTAssertTrue(model.isDurablyQueued(pending.id))

        script.release()
        let accepted = await waitOnClock { model.decisions.first?.isSent == true }
        XCTAssertTrue(accepted, "the transport accepted it")
        XCTAssertEqual(savedIDs(), [], "removed once the Mac has it")
        XCTAssertFalse(model.isDurablyQueued(pending.id))
        let onServer = try await serverIntentIDs()
        XCTAssertEqual(onServer, [pending.id])
    }

    // MARK: replay after relaunch, no duplicate

    func testAnUnsentDecisionSurvivesARelaunchAndIsSentOnceWithItsOwnID() async throws {
        try await seed()
        let offline = OutboxSendScript(.fail)
        let first = launch(offline)
        await first.refresh()
        await first.decide(.removeFromLarder, entryID: id("b"))
        let pending = try XCTUnwrap(first.decisions.first)
        XCTAssertFalse(pending.isSent)
        XCTAssertTrue(first.isDurablyQueued(pending.id))
        XCTAssertEqual(savedIDs(), [pending.id])
        guard case let .saved(onDisk) = LibraryIntentOutbox(url: outboxURL).load() else { return XCTFail("nothing saved") }
        XCTAssertEqual(onDisk.ownerToken, "fixture-owner", "stamped with the account the mirror bound on the first sync")

        // The app is killed with the decision unsent; the next launch has signal.
        let online = OutboxSendScript(.deliver)
        let second = launch(online)
        XCTAssertEqual(second.decisions.map(\.id), [pending.id], "tracked again as soon as the app starts")
        await second.loadLocalState()
        XCTAssertEqual(rows(second), ["a", "c"], "the row stays off the Larder while the decision is owed")
        await second.refresh()
        XCTAssertEqual(online.attempts, [pending.id], "sent once, with the id it was made with")
        let onServer = try await mac.listIntents()
        XCTAssertEqual(onServer.map(\.id), [pending.id])
        XCTAssertEqual(onServer.first?.action, .removeFromLarder(entryID: id("b")))
        XCTAssertEqual(savedIDs(), [])

        let quiet = OutboxSendScript(.deliver)
        let third = launch(quiet)
        await third.refresh()
        XCTAssertTrue(quiet.attempts.isEmpty, "an intent the Mac has is never sent again")
        XCTAssertTrue(third.decisions.isEmpty)
    }

    func testASendWhoseAnswerWasLostIsReplayedAsTheSameRequest() async throws {
        try await seed()
        let lost = OutboxSendScript(.deliverThenFail)
        let first = launch(lost)
        await first.refresh()
        await first.decide(.removeFromLarder, entryID: id("b"))
        let pending = try XCTUnwrap(first.decisions.first)
        XCTAssertEqual(savedIDs(), [pending.id], "the Mac has it, but the phone never heard, so it stays saved")

        let online = OutboxSendScript(.deliver)
        let second = launch(online)
        await second.refresh()
        XCTAssertEqual(online.attempts, [pending.id])
        let onServer = try await serverIntentIDs()
        XCTAssertEqual(onServer, [pending.id], "the replay reuses the id, so the Mac holds one request")
        XCTAssertEqual(savedIDs(), [])
    }

    func testAnUnsentAddSurvivesARelaunchAndIsSentWithItsOwnID() async throws {
        try await mac.publishStats(LibraryStats(supportedIntentActions: ["subscribe", "addArticle"]))
        let first = launch(OutboxSendScript(.fail))
        await first.addToMac(.subscribe(feed), title: "The Show")
        let add = try XCTUnwrap(first.adds.first)
        XCTAssertFalse(add.isSent)
        XCTAssertEqual(savedIDs(), [add.id])

        let online = OutboxSendScript(.deliver)
        let second = launch(online)
        XCTAssertEqual(second.adds.map(\.title), ["The Show"])
        await second.refresh()
        XCTAssertEqual(online.attempts, [add.id])
        let onServer = try await mac.listIntents()
        XCTAssertEqual(onServer.map(\.id), [add.id])
        XCTAssertEqual(onServer.first?.action, .subscribe(feedURL: feed))
        XCTAssertEqual(second.addStatus(for: try XCTUnwrap(second.adds.first)).text, "Sent to your Mac")
        XCTAssertEqual(savedIDs(), [])
    }

    func testAnUnsentDecisionStaysOwedWhenTheMacMovesItsEntry() async throws {
        try await seed()
        let script = OutboxSendScript(.fail)
        let model = launch(script)
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        let pending = try XCTUnwrap(model.decisions.first)

        // The Mac moves c between a and b, so b's place differs from when the decision was made.
        try await macPush([.slot(try QueueSlot(entryID: id("c"), sortKey: 0.5))])
        await model.refresh()
        XCTAssertEqual(model.decisions.map(\.id), [pending.id], "still owed to the Mac, which has never seen it")
        XCTAssertEqual(model.decisionStatus(for: id("b")), .pendingOnMac)
        XCTAssertEqual(rows(model), ["a", "c", "b"], "the Mac's newer state shows meanwhile")
        XCTAssertEqual(savedIDs(), [pending.id])

        script.mode = .deliver
        await model.refresh()
        let onServer = try await serverIntentIDs()
        XCTAssertEqual(onServer, [pending.id], "sent with the id it was made with")
        XCTAssertEqual(savedIDs(), [])
    }

    // MARK: files this build cannot use

    func testADamagedFileIsSetAsideAndTheNextIntentIsStillSaved() async throws {
        try await seed()
        let damaged = Data("{\"version\": 1, \"decisions\": [".utf8)
        try damaged.write(to: outboxURL)
        let model = launch(OutboxSendScript(.fail))
        XCTAssertTrue(model.decisions.isEmpty)
        let aside = try XCTUnwrap(LibraryIntentOutbox(url: outboxURL).setAsideURL)
        XCTAssertEqual(try Data(contentsOf: aside), damaged, "kept next to it, never deleted or replayed")

        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        let pending = try XCTUnwrap(model.decisions.first)
        XCTAssertEqual(savedIDs(), [pending.id])
        XCTAssertTrue(model.isDurablyQueued(pending.id))
    }

    func testAFileFromAnotherVersionIsSetAsideAndNothingInItIsSent() async throws {
        try await seed()
        let intent = try LibraryIntent.removeFromLarder(entryID: id("b"), deviceID: "phone", createdAt: now)
        try LibraryIntentOutbox(url: outboxURL).save(.init(ownerToken: "fixture-owner", decisions: [decision(intent)]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: outboxURL)) as? [String: Any])
        json["version"] = LibraryIntentOutbox.version + 1
        let newer = try JSONSerialization.data(withJSONObject: json)
        try newer.write(to: outboxURL)

        let script = OutboxSendScript(.deliver)
        let model = launch(script)
        XCTAssertTrue(model.decisions.isEmpty)
        await model.refresh()
        XCTAssertTrue(script.attempts.isEmpty)
        let onServer = try await serverIntentIDs()
        XCTAssertTrue(onServer.isEmpty)
        let aside = try XCTUnwrap(LibraryIntentOutbox(url: outboxURL).setAsideURL)
        XCTAssertEqual(try Data(contentsOf: aside), newer)
    }

    func testAFileWithAnActionThisBuildCannotSendIsSetAsideAndSavingStillWorks() async throws {
        try await seed()
        for action: Any in [["futureAction": ["entryID": "b"]], ["unsupported": [String: Any]()]] {
            let intent = try LibraryIntent.removeFromLarder(entryID: id("b"), deviceID: "phone", createdAt: now)
            try LibraryIntentOutbox(url: outboxURL).save(.init(ownerToken: "fixture-owner", decisions: [decision(intent)]))
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: outboxURL)) as? [String: Any])
            var decisions = try XCTUnwrap(json["decisions"] as? [[String: Any]])
            var saved = try XCTUnwrap(decisions[0]["intent"] as? [String: Any])
            saved["action"] = action
            decisions[0]["intent"] = saved
            json["decisions"] = decisions
            try JSONSerialization.data(withJSONObject: json).write(to: outboxURL)

            let script = OutboxSendScript(.fail)
            let model = launch(script)
            XCTAssertTrue(model.decisions.isEmpty, "\(action) is never replayed")
            await model.refresh()
            await model.decide(.removeFromLarder, entryID: id("c"))
            let pending = try XCTUnwrap(model.decisions.first)
            XCTAssertEqual(savedIDs(), [pending.id], "the next decision is still saved")
            model.cancelDecision(entryID: id("c"))
        }
        let onServer = try await serverIntentIDs()
        XCTAssertTrue(onServer.isEmpty)
    }

    func testAFileThatCannotBeReadIsNeverReplacedThatRun() async throws {
        try await seed()
        let intent = try LibraryIntent.removeFromLarder(entryID: id("c"), deviceID: "phone", createdAt: now)
        try LibraryIntentOutbox(url: outboxURL).save(.init(ownerToken: "fixture-owner", decisions: [decision(intent)]))
        let before = try Data(contentsOf: outboxURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: outboxURL.path)

        let model = launch(OutboxSendScript(.fail))
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        let pending = try XCTUnwrap(model.decisions.first)
        XCTAssertFalse(model.isDurablyQueued(pending.id), "nothing new counts as saved")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outboxURL.path)
        XCTAssertEqual(try Data(contentsOf: outboxURL), before, "the unread file was left exactly as it was")
    }

    func testIntentsSavedUnderAnotherAccountAreNeverSent() async throws {
        try await seed()
        let bind = launch(OutboxSendScript(.deliver))
        await bind.refresh()
        let owner = await bind.mediaStoreState().ownerToken
        XCTAssertEqual(owner, "fixture-owner", "the mirror is bound to this account")
        let intent = try LibraryIntent.removeFromLarder(entryID: id("b"), deviceID: "phone", createdAt: now)
        try LibraryIntentOutbox(url: outboxURL).save(.init(ownerToken: "another-owner", decisions: [decision(intent)]))

        let script = OutboxSendScript(.deliver)
        let model = launch(script)
        await model.refresh()
        XCTAssertTrue(script.attempts.isEmpty)
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertEqual(savedIDs(), [])
        let onServer = try await serverIntentIDs()
        XCTAssertTrue(onServer.isEmpty)
    }

    func testTheFileRoundTripsEveryKind() throws {
        let decisionIntent = try LibraryIntent.reorder(entryID: id("b"), afterEntryID: nil, deviceID: "phone", createdAt: now)
        let addIntent = try LibraryIntent.addArticle(url: URL(string: "https://example.com/story")!, deviceID: "phone", createdAt: now)
        let ack = try LibraryIntent.mediaCached(entryID: id("a"), revisionID: RevisionID(rawValue: "rev-1"), deviceID: "phone", createdAt: now)
        let saved = LibraryIntentOutbox.Saved(
            ownerToken: "fixture-owner",
            decisions: [LibraryIntentOutbox.Decision(
                intent: decisionIntent, baseline: EntryPlacement(removal: .none, isQueued: true, predecessor: id("a")),
                isSilent: true, retiresEpisode: false, supersededByRestore: true)],
            adds: [LibraryIntentOutbox.Add(intent: addIntent, title: "example.com/story")],
            acknowledgements: [ack])
        let outbox = LibraryIntentOutbox(url: outboxURL)
        try outbox.save(saved)
        XCTAssertEqual(outbox.load(), .saved(saved))
        XCTAssertEqual(LibraryIntentOutbox(url: nil).load(), .empty, "a memory-only outbox has nothing on disk")
    }

    private func decision(_ intent: LibraryIntent) -> LibraryIntentOutbox.Decision {
        LibraryIntentOutbox.Decision(
            intent: intent, baseline: EntryPlacement(removal: .none, isQueued: true, predecessor: id("a")),
            isSilent: false, retiresEpisode: true, supersededByRestore: false)
    }
}
