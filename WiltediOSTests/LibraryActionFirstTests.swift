import Foundation
import SwiftUI
import WiltedCatalog
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The outbox tests' scripted transport, with a scripted `readStats()` as well: `.hold` waits for
/// `release()`, `.fail` is a Mac that cannot be reached, and anything else reads the published stats.
struct StatsScriptedTransport: LibraryTransport {
    let base: OutboxScriptedTransport
    let stats: OutboxSendScript

    func readStats() async throws -> LibraryStats? {
        switch stats.begin("readStats") {
        case .fail, .deliverThenFail: throw LibraryTransportError.transport("the Mac is unreachable")
        case .hold: await stats.waitForRelease()
        case .deliver: break
        }
        return try await base.readStats()
    }

    func send(intent: LibraryIntent) async throws { try await base.send(intent: intent) }
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
    func publishTranscript(_ transcript: LibraryTranscript) async throws { try await base.publishTranscript(transcript) }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await base.transcript(entryID: entryID, revisionID: revisionID)
    }
    func removeTranscript(entryID: ItemID) async throws { try await base.removeTranscript(entryID: entryID) }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws { try await base.commitFetchedState(token) }
    func commitSentState(_ token: LibraryChangeToken?) async throws { try await base.commitSentState(token) }
}

/// W-INV-040: what the person does shows first; the backend work behind it never stands in front of the
/// screen. Each test holds the backend step (the cache check, the Mac's capability read, the delete),
/// looks at what the person sees, then lets the step finish and checks how it resolved.
@MainActor
final class LibraryActionFirstTests: XCTestCase {
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
    private let entryID = try! ItemID(rawValue: "item-a")
    private let feed = URL(string: "https://feeds.example.com/show.xml")!
    private let audio = Data(repeating: 7, count: 500)
    private var scratch: URL!

    override func setUp() async throws {
        await HostedAccessibility.prepare()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("action-first-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    // MARK: Fixture

    private var storeURL: URL { scratch.appendingPathComponent("library-state.json") }
    private var outboxURL: URL { scratch.appendingPathComponent("outbox.json") }

    private func phone(_ sends: OutboxSendScript) -> OutboxScriptedTransport {
        OutboxScriptedTransport(
            base: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
            script: sends)
    }

    /// One launch of the app on a phone the Mac has linked: a new model over the same mirror, cache and outbox.
    private func launch(_ transport: any LibraryTransport, cache: any LibraryMediaCache) -> LibraryAppModel {
        let suite = "library-action-first-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let model = LibraryAppModel(
            transport: transport, store: FileLibraryStore(url: storeURL), deviceID: "phone", mediaCache: cache,
            mediaTiming: LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
            preferences: UserDefaults(suiteName: suite)!, outboxURL: outboxURL, timeZone: TimeZone(identifier: "UTC")!)
        model.deviceLinked = true
        return model
    }

    private func readyOffer() throws -> LibraryMediaOffer {
        try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: entryID, revisionID: RevisionID(rawValue: "rev-1"), contentHash: PreparedMediaFixture.hash(audio),
            byteCount: Int64(audio.count), mediaType: "audio/mp4", durationSeconds: 600))
    }

    /// A first session listed the Mac's prepared episode and downloaded its audio, so the mirror holds the
    /// prepared row and the cache holds the file.
    private func seedDownloadedEpisode(into cache: FileMediaCache) async throws {
        let show = LibrarySource(id: try ItemID(rawValue: "show"), kind: .podcastFeed, title: "The Show")
        let entry = try LibraryEntry(
            id: entryID, kind: .podcastEpisode, sourceID: show.id, title: "Episode A", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: 600)
        let changes: [LibraryChange] = [.source(show), .entry(entry), .slot(try QueueSlot(entryID: entryID, sortKey: 0))]
        _ = try await mac.push(changes: changes.enumerated().map {
            PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })
        let upload = scratch.appendingPathComponent("upload.mp4")
        try audio.write(to: upload)
        try await mac.publishMedia(offer: try readyOffer(), fileURL: upload)
        await launch(phone(OutboxSendScript(.deliver)), cache: cache).refresh()
        let saved = await FileLibraryStore(url: storeURL).state()
        XCTAssertEqual(saved.displayPreparedIDs, [entryID], "the first session saved the prepared row")
        let file = scratch.appendingPathComponent("downloaded.mp4")
        try audio.write(to: file)
        _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: file, for: readyOffer(), owner: "fixture-owner")
    }

    private func larder(_ model: LibraryAppModel) -> HostedView<some View> {
        HostedView(NavigationStack { LibraryListView(model: model, onPlay: { _ in }) })
    }

    /// The row's audio controls on screen (Download, Delete download, Play), then its audio actions by name.
    private func audioControls(_ hosted: HostedView<some View>) -> [String] {
        let raw = entryID.rawValue
        let controls = ["wilted-library-media-get-\(raw)", "wilted-library-media-remove-\(raw)", "wilted-library-play-\(raw)"]
        let actions = hosted.element("wilted-library-title-\(raw)")?.customActionNames ?? []
        return controls.filter { hosted.element($0) != nil } + actions.filter { ["Download", "Play"].contains($0) }
    }

    /// Waits, on real time, until the gated cache is holding a call.
    private func holding(_ cache: GatedMediaCache) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await cache.isHeld { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func savedIDs() -> Set<String> {
        guard case let .saved(saved) = LibraryIntentOutbox(url: outboxURL).load() else { return [] }
        return saved.intentIDs
    }

    // MARK: Cold launch

    func testALaunchListsTheSavedLarderWhileItChecksTheAudioOnThePhone() async throws {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        try await seedDownloadedEpisode(into: cache)
        let gated = GatedMediaCache(cache)
        await gated.arm()
        let model = launch(UnavailableLibraryTransport(reason: "no signal"), cache: gated)
        let hosted = larder(model)

        let loading = Task { await model.loadLocalState() }
        let held = await holding(gated)
        XCTAssertTrue(held, "the check of the audio on the phone is under way")
        hosted.settle()
        XCTAssertTrue(model.larderReady, "LibraryRoot draws the list, not \"Opening your larder…\"")
        XCTAssertFalse(model.localStateLoaded)
        XCTAssertNotNil(hosted.element("wilted-library-title-item-a"), "the saved row is on screen")
        XCTAssertNil(model.media[entryID], "the row does not say the audio is on the phone before that is known")
        XCTAssertFalse(model.canRequestAudio)
        XCTAssertEqual(audioControls(hosted), [], "no Download and no Play while the audio is being checked")

        await gated.release()
        await loading.value
        hosted.settle()
        XCTAssertTrue(model.localStateLoaded)
        XCTAssertEqual(model.media[entryID], .onPhone)
        XCTAssertEqual(audioControls(hosted), ["wilted-library-media-remove-item-a", "wilted-library-play-item-a", "Play"])
    }

    func testALaunchSendsNoAcknowledgementAndTheSyncRoundSendsTheSavedOne() async throws {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        try await seedDownloadedEpisode(into: cache)
        let ack = try LibraryIntent.mediaCached(
            entryID: entryID, revisionID: RevisionID(rawValue: "rev-1"), deviceID: "phone", createdAt: Date())
        try LibraryIntentOutbox(url: outboxURL).save(LibraryIntentOutbox.Saved(ownerToken: "fixture-owner", acknowledgements: [ack]))
        let sends = OutboxSendScript(.deliver)
        let model = launch(phone(sends), cache: cache)

        await model.loadLocalState()
        XCTAssertEqual(model.media[entryID], .onPhone)
        XCTAssertEqual(sends.attempts, [], "the local read sends nothing")
        XCTAssertTrue(model.isDurablyQueued(ack.id), "the acknowledgement waits in the outbox")

        await model.refresh()
        XCTAssertEqual(sends.attempts, [ack.id], "the sync round sends it once")
        XCTAssertNil(model.unacknowledgedMedia[entryID])
        XCTAssertEqual(savedIDs(), [])
    }

    // MARK: Add

    private func adding(stats: OutboxSendScript, sends: OutboxSendScript) -> LibraryAppModel {
        launch(StatsScriptedTransport(base: phone(sends), stats: stats),
               cache: FileMediaCache(rootURL: scratch.appendingPathComponent("cache")))
    }

    func testAnAddShowsItsRowBeforeTheMacIsAskedWhatItApplies() async throws {
        try await mac.publishStats(LibraryStats(supportedIntentActions: ["subscribe", "addArticle"]))
        let stats = OutboxSendScript(.hold)
        let sends = OutboxSendScript(.deliver)
        let model = adding(stats: stats, sends: sends)

        let pressing = Task { await model.addToMac(.subscribe(feed), title: "The Show") }
        let asking = await waitOnClock { stats.attempts.count == 1 }
        XCTAssertTrue(asking, "the Mac is being asked what it applies")
        let add = try XCTUnwrap(model.adds.first, "the row is there while the Mac is asked")
        XCTAssertEqual(model.adds.count, 1)
        XCTAssertEqual(model.addStatus(for: add).text, "Not sent yet. Trying again.")
        XCTAssertTrue(model.isDurablyQueued(add.id), "a kill now still sends it after the relaunch")
        XCTAssertEqual(sends.attempts, [], "nothing is sent before the Mac says it applies it")

        stats.release()
        await pressing.value
        XCTAssertEqual(sends.attempts, [add.id])
        XCTAssertEqual(model.adds.first?.isSent, true)
        XCTAssertEqual(model.addStatus(for: try XCTUnwrap(model.adds.first)).text, "Sent to your Mac")
        XCTAssertEqual(savedIDs(), [])
    }

    func testAnAddTheMacDoesNotApplyLeavesWithTheUpdateMessage() async throws {
        try await mac.publishStats(LibraryStats(supportedIntentActions: ["addArticle"]))
        let stats = OutboxSendScript(.hold)
        let sends = OutboxSendScript(.deliver)
        let model = adding(stats: stats, sends: sends)

        let pressing = Task { await model.addToMac(.subscribe(feed), title: "The Show") }
        let asking = await waitOnClock { stats.attempts.count == 1 }
        XCTAssertTrue(asking)
        XCTAssertEqual(model.adds.count, 1, "the row shows first")
        XCTAssertNil(model.addNotice)

        stats.release()
        await pressing.value
        XCTAssertTrue(model.adds.isEmpty, "the Mac said no, so the row is taken back")
        XCTAssertEqual(model.addNotice, LibraryAppModel.updateMacText(deviceKind: model.deviceKind))
        XCTAssertEqual(sends.attempts, [], "the Mac gets no intent it does not apply")
        XCTAssertEqual(savedIDs(), [], "and nothing is left to send after a relaunch")
    }

    func testAnAddWhoseCapabilityReadFailsStaysQueuedAndIsSentNextRound() async throws {
        try await mac.publishStats(LibraryStats(supportedIntentActions: ["subscribe", "addArticle"]))
        let stats = OutboxSendScript(.fail)
        let sends = OutboxSendScript(.deliver)
        let model = adding(stats: stats, sends: sends)

        await model.addToMac(.subscribe(feed), title: "The Show")
        let add = try XCTUnwrap(model.adds.first)
        XCTAssertEqual(model.addStatus(for: add).text, "Not sent yet. Trying again.")
        XCTAssertNil(model.addNotice, "a failed read is not a no")
        XCTAssertTrue(model.isDurablyQueued(add.id))
        XCTAssertEqual(sends.attempts, [])

        stats.mode = .deliver
        await model.refresh()
        XCTAssertEqual(sends.attempts, [add.id])
        XCTAssertEqual(model.adds.first?.isSent, true)
    }

    // MARK: Remove from phone

    /// A launched Larder whose row has its audio on the phone.
    private func downloadedLarder() async throws -> (LibraryAppModel, GatedMediaCache, FileMediaCache) {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        try await seedDownloadedEpisode(into: cache)
        let gated = GatedMediaCache(cache)
        let model = launch(UnavailableLibraryTransport(reason: "no signal"), cache: gated)
        await model.loadLocalState()
        XCTAssertEqual(model.media[entryID], .onPhone)
        return (model, gated, cache)
    }

    func testRemoveFromPhoneClearsTheRowBeforeTheDeleteFinishes() async throws {
        let (model, gated, cache) = try await downloadedLarder()
        let hosted = larder(model)
        XCTAssertEqual(audioControls(hosted), ["wilted-library-media-remove-item-a", "wilted-library-play-item-a", "Play"])
        await gated.armRemoval()

        let removing = Task { await model.removeFromPhone(entryID: entryID) }
        let held = await holding(gated)
        XCTAssertTrue(held, "the delete is under way")
        hosted.settle()
        XCTAssertNil(model.media[entryID], "the row no longer says the audio is on the phone")
        XCTAssertNil(hosted.element("wilted-library-media-remove-item-a"))
        XCTAssertNil(hosted.element("wilted-library-play-item-a"))
        let stillThere = await cache.cachedEntries()[entryID]
        XCTAssertNotNil(stillThere, "the file is still being deleted")
        model.startMediaRequest(entryID: entryID)
        XCTAssertNil(model.media[entryID], "no download starts on audio that is being deleted")

        await gated.release()
        await removing.value
        let gone = await cache.cachedEntries()[entryID]
        XCTAssertNil(gone)
        XCTAssertNil(model.media[entryID])
    }

    func testARemoveThatFailsShowsTheErrorAndKeepsTheAudio() async throws {
        let (model, gated, cache) = try await downloadedLarder()
        await gated.armRemoval(failing: true)

        let removing = Task { await model.removeFromPhone(entryID: entryID) }
        let held = await holding(gated)
        XCTAssertTrue(held)
        XCTAssertNil(model.media[entryID], "the row cleared at once")

        await gated.release()
        await removing.value
        guard case let .failed(text) = model.media[entryID] else {
            return XCTFail("the row shows the delete failed: \(String(describing: model.media[entryID]))")
        }
        XCTAssertTrue(text.hasPrefix("Could not remove the audio"), text)
        let kept = await cache.cachedEntries()[entryID]
        XCTAssertNotNil(kept, "the audio is still on the phone")

        await model.refreshMediaFromCache()
        XCTAssertEqual(model.media[entryID], .onPhone, "the next check shows it on the phone again")
    }
}
