import CloudKit
import Foundation
import WiltedCloudKit
import WiltedCloudKitLibrary
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacModelLibrarySyncTests: XCTestCase {
    private let flagOn = ["WILTED_LIBRARY_SYNC": "1"]
    private let feedURL = URL(string: "https://feeds.example.test/show.xml")!
    private let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

    private func makeModel(_ name: String) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    private func bootstrapped(_ name: String) async throws -> (WiltedMacModel, LocalLibraryStore) {
        let model = makeModel(name)
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return (model, try XCTUnwrap(model.store))
    }

    /// One feed with episodes "a", "b", "c" (none downloaded), returned in that order.
    private func seedEpisodes(_ store: LocalLibraryStore) async throws -> [ItemID] {
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        var ids: [ItemID] = []
        for (index, guid) in ["a", "b", "c"].enumerated() {
            let enclosure = URL(string: "https://media.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
                publishedTime: Timestamp(Date(timeIntervalSince1970: 1_700_000_000 + Double(index))),
                enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created
            ))
            ids.append(id)
        }
        return ids
    }

    private func source(_ store: LocalLibraryStore, playback: WiltedMacPlaybackSample? = nil) -> WiltedMacLocalLibraryStateSource {
        WiltedMacLocalLibraryStateSource(store: store, deviceID: "mac-test") { playback }
    }

    private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    func testManagedPublisherWiresStableDeviceAndDurableApprovedOwnerReceipt() async throws {
        let (model, store) = try await bootstrapped("publication-model-managed")
        let device = model.libraryDeviceID(); let server = InMemoryLibraryServer(writerDeviceID: device)
        let fixture = WiltedMacLibraryAccountFixture()
        XCTAssertTrue(model.startLibrarySyncIfEnabled(environment: flagOn,
            transport: InMemoryLibraryTransport(deviceID: device, server: server), debounce: .milliseconds(20), account: fixture.source))
        fixture.signIn(recordName: "publication-model-owner")
        try await eventually("approved") { model.libraryAccountStatus == .active }
        let controller = try XCTUnwrap(model.librarySyncController); await controller.tickRound()
        _ = try await seedEpisodes(store); await controller.tickRound()
        let observed = try await model.fulfilledLibraryPublication()
        let owner = CloudKitAccountIdentity.token(for: "publication-model-owner")
        let durable = try await WiltedMacLibraryPublicationStore.store(store).load(owner: owner)
        XCTAssertNotNil(observed); XCTAssertEqual(observed?.writerDeviceID, device); XCTAssertEqual(observed, durable.fulfilled)
        model.stopLibrarySync(); await model.waitForLibrarySyncShutdown()
    }
    func testStoppedManagedPublisherReleasesItsApprovedAccountOwner() async throws {
        var model: WiltedMacModel? = try await bootstrapped("publication-owner-lifetime").0
        let device = try XCTUnwrap(model).libraryDeviceID()
        let fixture = WiltedMacLibraryAccountFixture()
        XCTAssertTrue(try XCTUnwrap(model).startLibrarySyncIfEnabled(environment: flagOn,
            transport: InMemoryLibraryTransport(deviceID: device, server: InMemoryLibraryServer(writerDeviceID: device)),
            debounce: .milliseconds(20), account: fixture.source))
        weak var account = model?.libraryAccount; let publisher = try XCTUnwrap(model?.librarySyncController?.publisher)
        XCTAssertNotNil(account)
        model?.stopLibrarySync(); await model?.waitForLibrarySyncShutdown(); model = nil
        await Task.yield()
        XCTAssertNil(account, "Stopped publisher must not retain its approved owner through willOpen")
        do { _ = try await publisher.fulfilledPublication(); XCTFail("Released owner must fail closed") }
        catch { XCTAssertEqual(error as? WiltedMacLibraryAccountError, .notApproved) }
    }
    func testUnmanagedFixturePublishesContentWithoutInventingApprovedAuthorEvidence() async throws {
        let (model, store) = try await bootstrapped("publication-model-unmanaged"); _ = try await seedEpisodes(store)
        let server = InMemoryLibraryServer(writerDeviceID: "fixture")
        XCTAssertTrue(model.startLibrarySyncIfEnabled(environment: flagOn,
            transport: InMemoryLibraryTransport(deviceID: "fixture", server: server), debounce: .milliseconds(20)))
        await model.librarySyncController?.tickRound()
        let observed = try await model.fulfilledLibraryPublication(); let content = await server.currentSnapshot
        XCTAssertNil(observed); XCTAssertEqual(content.entries.count, 3)
        model.stopLibrarySync(); await model.waitForLibrarySyncShutdown()
    }

    // MARK: State source

    func testStateSourceMapsFeedsEpisodesQueueRemovalAndListening() async throws {
        let (_, store) = try await bootstrapped("library-sync-state")
        let ids = try await seedEpisodes(store)
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [ids[2], ids[0], ids[1]]))
        _ = try await store.retireEpisode(ids[1])
        _ = try await store.dismissPodcastEpisode(ids[2])
        try await store.saveListening(PodcastListeningState(
            episodeID: ids[0], completedAt: Timestamp(Date(timeIntervalSince1970: 50)), lastRevisionID: nil,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 60))
        ))

        let state = try await source(store).currentState()

        XCTAssertEqual(state.feeds.map(\.title), ["Show"])
        XCTAssertEqual(state.feeds.first?.kind, .podcastFeed)
        XCTAssertEqual(Set(state.episodes.map(\.id)), Set(ids))
        XCTAssertTrue(state.episodes.allSatisfy { $0.kind == .podcastEpisode })
        let removals = Dictionary(uniqueKeysWithValues: state.episodes.map { ($0.id, $0.removal) })
        XCTAssertEqual(removals[ids[0]], LibraryRemoval.none)
        XCTAssertEqual(removals[ids[1]], .retired)
        XCTAssertEqual(removals[ids[2]], .dismissed)
        let removedAt: [ItemID: Date?] = Dictionary(uniqueKeysWithValues: state.episodes.map { ($0.id, $0.removedAt) })
        XCTAssertNil(removedAt[ids[0]] ?? nil, "a live episode has no removal date")
        XCTAssertNotNil(removedAt[ids[1]] ?? nil, "retired carries the store's retirement date")
        XCTAssertNotNil(removedAt[ids[2]] ?? nil, "dismissed carries the store's removal date")
        XCTAssertEqual(state.queue, [ids[0]], "removed episodes leave the published queue; order is kept")
        XCTAssertEqual(state.listening.map(\.itemID), [ids[0]])
        XCTAssertEqual(state.listening.first?.deviceID, "mac-test")
        XCTAssertNil(state.currentPlayback, "no playback sample")
    }

    func testStateSourcePublishesCurrentPlaybackOnlyWithAPreparedRevision() async throws {
        let directory = wiltedTemporaryDirectory("library-sync-playback-media")
        let (_, store) = try await bootstrapped("library-sync-playback")
        let ids = try await seedEpisodes(store)
        let sample = WiltedMacPlaybackSample(episodeID: ids[0], positionSeconds: 12, rate: 1.5, isPlaying: false)
        let unprepared = try await source(store, playback: sample).currentState()
        XCTAssertNil(unprepared.currentPlayback)

        let enclosure = URL(string: "https://media.example.test/ready.mp3")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let readyID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "ready", enclosureURL: enclosure)
        try await WiltedMacModelTests.addReadyEpisode(
            readyID, guid: "ready", feedID: feedID, feedURL: feedURL, enclosureURL: enclosure,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_100), directory: directory, store: store, created: created
        )
        let ready = WiltedMacPlaybackSample(episodeID: readyID, positionSeconds: 12, rate: 1.5, isPlaying: false)
        let state = try await source(store, playback: ready).currentState()
        let position = try XCTUnwrap(state.currentPlayback)
        XCTAssertEqual(position.entryID, readyID)
        XCTAssertEqual(position.positionSeconds, 12)
        XCTAssertEqual(position.rate, 1.5)
        XCTAssertEqual(position.deviceID, "mac-test")
        XCTAssertFalse(position.isPlaying)
    }

    // MARK: Intents

    func testSinkRecordsMediaRequestsWithoutAConsumerAndDeduplicates() async throws {
        let sink = WiltedMacLibraryIntentSink()
        let intent = try LibraryIntent.requestMedia(entryID: try ItemID(rawValue: "item-a"), deviceID: "iphone", id: "i-1")
        try await sink.receive(intent)
        try await sink.receive(intent)
        let recorded = await sink.recorded
        XCTAssertEqual(recorded, [intent])
    }

    func testSinkRoutesToConsumerAndRetriesAfterAFailure() async throws {
        actor Calls { var ids: [String] = []; var failing = true
            func call(_ intent: LibraryIntent) throws {
                ids.append(intent.id)
                if failing { failing = false; throw NSError(domain: "test", code: 1) }
            }
        }
        let calls = Calls()
        let sink = WiltedMacLibraryIntentSink { intent in try await calls.call(intent) }
        let intent = try LibraryIntent.requestMedia(entryID: try ItemID(rawValue: "item-a"), deviceID: "iphone", id: "i-2")
        do { try await sink.receive(intent); XCTFail("expected failure") } catch {}
        let afterFailure = await sink.recorded
        XCTAssertTrue(afterFailure.isEmpty)
        try await sink.receive(intent)
        let ids = await calls.ids
        let recorded = await sink.recorded
        XCTAssertEqual(ids, ["i-2", "i-2"])
        XCTAssertEqual(recorded.count, 1)
    }

    // MARK: Wiring

    func testFlagOffStartsNothing() async throws {
        let (model, _) = try await bootstrapped("library-sync-off")
        XCTAssertFalse(model.startLibrarySyncIfEnabled(environment: [:]))
        XCTAssertNil(model.librarySyncController)
        XCTAssertFalse(model.startLibrarySyncIfEnabled(environment: ["WILTED_LIBRARY_SYNC": "0"]))
    }

    func testPublisherRepublishesOnQueueRemovalAndPlaybackChanges() async throws {
        let (model, store) = try await bootstrapped("library-sync-publish")
        let ids = try await seedEpisodes(store)
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [ids[0], ids[1]]))
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let transport = InMemoryLibraryTransport(deviceID: "mac-test", server: server)

        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: transport, debounce: .milliseconds(20)
        ))
        try await eventually("first publish") { await server.currentSnapshot.entries.count == 3 }
        var snapshot = await server.currentSnapshot
        XCTAssertEqual(snapshot.queue.map(\.entryID), [ids[0], ids[1]])
        XCTAssertEqual(snapshot.sources.count, 1)

        // Queue reorder: the store changes, then the model's observed queue moves.
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [ids[1], ids[0]]))
        model.podcastQueueIDs = [ids[1].rawValue, ids[0].rawValue]
        try await eventually("queue reorder") { await server.currentSnapshot.queue.first?.entryID == ids[1] }

        // Removal: retiring drops the episode from the observed queue, as the model's reload does.
        _ = try await store.retireEpisode(ids[0])
        model.podcastQueueIDs = [ids[1].rawValue]
        try await eventually("retire") { await server.currentSnapshot.entries[ids[0]]?.removal == .retired }
        snapshot = await server.currentSnapshot
        XCTAssertEqual(snapshot.queue.map(\.entryID), [ids[1]])

        model.stopLibrarySync()
        XCTAssertNil(model.librarySyncController)
    }

    func testMediaRequestFromTheServerIsRecordedThroughTheSink() async throws {
        let (model, store) = try await bootstrapped("library-sync-intent")
        let ids = try await seedEpisodes(store)
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let phone = InMemoryLibraryTransport(deviceID: "iphone", server: server)
        try await phone.send(intent: LibraryIntent.requestMedia(entryID: ids[0], deviceID: "iphone", id: "i-3"))

        model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server),
            debounce: .milliseconds(20)
        )
        let sink = try XCTUnwrap(model.librarySyncController).sink
        try await eventually("intent recorded") { await sink.recorded.count == 1 }
        let recorded = await sink.recorded
        XCTAssertEqual(recorded.first?.action, .requestMedia(entryID: ids[0]))
    }

    func testEnvironmentFlagTurnsLegacyEngineOffAndDefaultLeavesItOn() async throws {
        let (defaultModel, _) = try await bootstrapped("library-sync-legacy-default")
        XCTAssertNotNil(defaultModel.syncLifecycle, "a test host's default keeps the legacy engine")
        XCTAssertNil(defaultModel.librarySyncController)

        setenv("WILTED_LIBRARY_SYNC", "1", 1)
        defer { unsetenv("WILTED_LIBRARY_SYNC") }
        let (flagged, _) = try await bootstrapped("library-sync-legacy-flag")
        XCTAssertNil(flagged.syncLifecycle, "each app owns exactly one engine")
        XCTAssertNotNil(flagged.librarySyncController)
        XCTAssertNotNil(flagged.libraryDeviceID().range(of: "mac-"))
        flagged.stopLibrarySync()
    }
    // MARK: Positions adopted from the phone

    func testAPhonePositionOnTheServerBecomesTheStoredPositionThroughTheRealWiring() async throws {
        let (model, store) = try await bootstrapped("library-sync-position-import")
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        let directory = wiltedTemporaryDirectory("library-sync-position-import-audio")
        var ids: [ItemID] = []
        for (index, guid) in ["a", "b"].enumerated() {
            let enclosure = URL(string: "https://media.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await WiltedMacModelTests.addReadyEpisode(
                id, guid: guid, feedID: feedID, feedURL: feedURL, enclosureURL: enclosure,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)), directory: directory,
                store: store, created: created)
            ids.append(id)
        }
        // "b" was finished on the Mac: a phone position must not bring it back.
        try await store.saveListening(PodcastListeningState(
            episodeID: ids[1], completedAt: Timestamp(Date()), lastRevisionID: nil, updatedAt: Timestamp(Date())))
        let snapshot = try await store.podcastLibrarySnapshot()
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let phone = HandoffCoordinator(
            transport: InMemoryLibraryTransport(deviceID: "iphone", server: server), deviceID: "iphone")
        for id in ids {
            let revision = try XCTUnwrap(snapshot.readyRevisions[id]).revision.revisionID
            try await phone.takeover(entryID: id, revision: revision, positionSeconds: 1)
            try await phone.paused(at: 4)
        }

        model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server),
            debounce: .milliseconds(20))
        let revisionA = try XCTUnwrap(snapshot.readyRevisions[ids[0]]).revision.revisionID
        try await eventually("the phone's position is stored") {
            (try? await store.playbackState(for: ids[0], revisionID: revisionA))?.positionSeconds == 4
        }
        let revisionB = try XCTUnwrap(snapshot.readyRevisions[ids[1]]).revision.revisionID
        let finished = try await store.playbackState(for: ids[1], revisionID: revisionB)
        XCTAssertNil(finished, "a finished episode is not resurrected")
        model.stopLibrarySync()
    }

    // MARK: Runtime selection (Task 5.1)

    private let liveFacts = WiltedMacLibraryBuildFacts(compiledLive: true, hostsTests: false)

    /// A model that believes it is a normal live launch. Bootstrap runs the real selection, so
    /// the production transport it reaches must be this Debug build's unavailable stand-in.
    private func liveBootstrapped(_ name: String) async throws -> (WiltedMacModel, LocalLibraryStore) {
#if WILTED_CLOUDKIT_LIVE
        throw XCTSkip("live-default wiring is exercised only where the production transport is inert")
#else
        let model = makeModel(name)
        model.librarySyncBuildFacts = liveFacts
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return (model, try XCTUnwrap(model.store))
#endif
    }

    func testRuntimeSelectionDefaultsOnlyANormalLiveLaunchToThePublisher() {
        typealias Selection = WiltedMacLibraryRuntimeSelection
        let nonLive = WiltedMacLibraryBuildFacts(compiledLive: false, hostsTests: false)
        let liveTestHost = WiltedMacLibraryBuildFacts(compiledLive: true, hostsTests: true)
        let cases: [([String: String], WiltedMacLibraryBuildFacts, Bool, Selection.Engine, Selection.Reason)] = [
            ([:], liveFacts, false, .libraryPublisher, .liveDefault),
            (["WILTED_LIBRARY_SYNC": ""], liveFacts, false, .libraryPublisher, .liveDefault),
            ([:], nonLive, false, .legacy, .nonLiveBuild),
            ([:], liveTestHost, false, .legacy, .testHost),
            ([:], liveFacts, true, .legacy, .fixture),
            (flagOn, nonLive, false, .libraryPublisher, .explicitOn),
            (flagOn, liveTestHost, false, .libraryPublisher, .explicitOn),
            (flagOn, liveFacts, true, .none, .fixture),
            (["WILTED_LIBRARY_SYNC": "0"], liveFacts, false, .legacy, .explicitOff),
            (["WILTED_LIBRARY_SYNC": "off"], liveFacts, false, .legacy, .explicitOff),
            (["WILTED_LIBRARY_SYNC": "true"], liveFacts, false, .legacy, .explicitOff),
        ]
        for (environment, facts, fixture, engine, reason) in cases {
            let selection = Selection.select(environment: environment, facts: facts, fixtureMode: fixture)
            XCTAssertEqual(selection.engine, engine, "\(environment) \(facts) fixture=\(fixture)")
            XCTAssertEqual(selection.reason, reason, "\(environment) \(facts) fixture=\(fixture)")
            XCTAssertEqual(selection, Selection.select(environment: environment, facts: facts, fixtureMode: fixture),
                           "a relaunch with the same inputs selects the same engine")
        }
        let liveDefault = Selection.select(environment: [:], facts: liveFacts, fixtureMode: false)
        XCTAssertTrue(liveDefault.admits(managedTransport: true))
        XCTAssertFalse(liveDefault.admits(managedTransport: false), "the default never runs unmanaged")
        XCTAssertTrue(Selection.select(environment: flagOn, facts: liveFacts, fixtureMode: false)
            .admits(managedTransport: false), "an explicit 1 keeps today's unmanaged runs")
        XCTAssertFalse(Selection.select(environment: ["WILTED_LIBRARY_SYNC": "0"], facts: liveFacts, fixtureMode: false)
            .admits(managedTransport: true))
    }

    func testALiveLaunchRunsExactlyOneEngineAndNeverTheUnavailableTransport() async throws {
        let (model, _) = try await liveBootstrapped("library-sync-live-bootstrap")
        XCTAssertEqual(model.libraryRuntimeSelection(environment: [:]).reason, .liveDefault)
        XCTAssertNil(model.syncLifecycle, "the legacy engine never runs beside the library publisher")
        XCTAssertNil(model.librarySyncController, "the unavailable stand-in is refused, not started")
        XCTAssertEqual(model.libraryAccountStatus, .transportUnavailable)

        // An unmanaged transport is refused by the default too, with the same visible status.
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        XCTAssertFalse(model.startLibrarySyncIfEnabled(
            environment: [:], transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server)))
        XCTAssertNil(model.librarySyncController)
        XCTAssertEqual(model.libraryAccountStatus, .transportUnavailable)

        // A managed transport starts by default, gated on the account.
        let account = WiltedMacLibraryAccountFixture()
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: [:], transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server),
            debounce: .milliseconds(20), account: account.source))
        XCTAssertEqual(model.libraryAccountStatus, .awaitingAccount)
        XCTAssertNil(model.syncLifecycle)
        model.stopLibrarySync()
        await model.waitForLibrarySyncShutdown()
    }

    func testExplicitOffKeepsTheLegacyEngineInALiveBuildAndExplicitOnStillRunsUnmanaged() async throws {
        let off: WiltedMacModel
        do {
            setenv("WILTED_LIBRARY_SYNC", "0", 1)
            defer { unsetenv("WILTED_LIBRARY_SYNC") }
            off = try await liveBootstrapped("library-sync-live-off").0
        }
        XCTAssertNotNil(off.syncLifecycle, "explicit off keeps the legacy engine")
        XCTAssertNil(off.librarySyncController)
        XCTAssertFalse(off.startLibrarySyncIfEnabled(environment: ["WILTED_LIBRARY_SYNC": "0"]))
        await off.close()

        let (model, _) = try await liveBootstrapped("library-sync-live-on")
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server)))
        XCTAssertEqual(model.libraryAccountStatus, .unmanaged)
        model.stopLibrarySync()
        await model.waitForLibrarySyncShutdown()
    }

    func testAFixtureLaunchStaysInertEvenWhenLiveOrForcedOn() async throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("library-sync-fixture"),
            preferences: WiltedMacTestPreferences.ephemeral())
        model.librarySyncBuildFacts = liveFacts
        XCTAssertEqual(model.libraryRuntimeSelection(environment: [:]).engine, .legacy)
        XCTAssertEqual(model.libraryRuntimeSelection(environment: flagOn).engine, .none)
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        XCTAssertFalse(model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: InMemoryLibraryTransport(deviceID: "mac-test", server: server),
            account: WiltedMacLibraryAccountFixture().source))
        XCTAssertNil(model.librarySyncController)
        await model.close()
    }

    /// The real CloudKit library transport over an engine that never reaches iCloud: the account
    /// events CKSyncEngine reports drive the binding, and recovery clears the transport itself.
    func testTheCloudKitTransportIsAlwaysManagedAndRecoversThroughItsOwnReset() async throws {
        let events = WiltedMacInertEngineEvents()
        let driver = WiltedMacInertEngineDriver(events: events)
        let transport = try CloudKitLibraryTransport(
            deviceID: "mac-test", isLibraryWriter: true, driver: driver,
            driverFactory: { _ in WiltedMacInertEngineDriver(events: events) }, outbox: CloudKitLibraryOutbox())
        XCTAssertNotNil(WiltedMacLibraryAccountSource.transport(transport), "a live transport is always managed")

        let (model, store) = try await liveBootstrapped("library-sync-cloudkit-account")
        XCTAssertTrue(model.startLibrarySyncIfEnabled(environment: [:], transport: transport, debounce: .milliseconds(20)))
        XCTAssertEqual(model.libraryAccountStatus, .awaitingAccount)
        let owner = CloudKitAccountIdentity.token(for: "_c93e-raw-icloud-owner-record")

        driver.emit(.accountChanged(.signIn, identity: CloudKitAccountIdentity(currentOwnerToken: owner)))
        try await eventually("owner bound") { model.libraryAccountStatus == .active }
        let bound = try await store.libraryAccountBinding()
        XCTAssertEqual(bound?.ownerToken, owner)

        driver.emit(.accountChanged(.signOut, identity: CloudKitAccountIdentity()))
        try await eventually("signed out") { model.libraryAccountStatus == .reviewRequired(.signOut) }
        let quarantined = await transport.isQuarantined()
        XCTAssertTrue(quarantined)

        driver.emit(.accountChanged(.signIn, identity: CloudKitAccountIdentity(currentOwnerToken: owner)))
        try await eventually("same owner recovered") { model.libraryAccountStatus == .active }
        let cleared = await transport.isQuarantined()
        XCTAssertFalse(cleared, "recovery resets the real transport's quarantine")
        model.stopLibrarySync()
        await model.waitForLibrarySyncShutdown()
    }
}

/// A CloudKit engine that never reaches iCloud: every operation fails, and the test injects the
/// account events CKSyncEngine would report.
/// The fixture must reach whichever fresh driver the transport now owns, just as an account
/// change reaches newly constructed engines. Old epochs still get ignored by production code.
private final class WiltedMacInertEngineEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<CloudKitEngineEvent>.Continuation] = []
    func register(_ continuation: AsyncStream<CloudKitEngineEvent>.Continuation) {
        lock.withLock { continuations.append(continuation) }
    }
    func emit(_ event: CloudKitEngineEvent) {
        let targets = lock.withLock { continuations }
        for target in targets { target.yield(event) }
    }
}

private final class WiltedMacInertEngineDriver: CloudKitEngineDriver, @unchecked Sendable {
    private struct Offline: Error {}
    private let stream: AsyncStream<CloudKitEngineEvent>
    private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
    private let fixtureEvents: WiltedMacInertEngineEvents

    init(events: WiltedMacInertEngineEvents) {
        fixtureEvents = events
        (stream, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        events.register(continuation)
    }

    func emit(_ event: CloudKitEngineEvent) { fixtureEvents.emit(event) }

    var events: AsyncStream<CloudKitEngineEvent> { get async { stream } }
    func ensureZone() async throws { throw Offline() }
    func fetchChanges() async throws { throw Offline() }
    func fetchChanges(zoneIDs: Set<CKRecordZone.ID>) async throws { throw Offline() }
    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { throw Offline() }
    func fetchRecordsIfPresent(_ ids: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?) async throws -> [CKRecord] {
        throw Offline()
    }
    func ensureZone(_ zoneID: CKRecordZone.ID) async throws { throw Offline() }
    func saveRecordRaw(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws { throw Offline() }
    func fetchAssetRecordRaw(_ id: CKRecord.ID, assetField: String, to destination: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord { throw Offline() }
    func deleteRecordsRaw(_ ids: [CKRecord.ID]) async throws { throw Offline() }
    func sendChanges() async throws { throw Offline() }
    func cancelOperations() async {}
    func resetZoneBootstrap() async {}
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {}
    func isValidStateData(_ data: Data) -> Bool { true }
}
