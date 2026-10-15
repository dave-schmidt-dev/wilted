import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryEpisodeAliasTests: XCTestCase {
    private let a = try! ItemID(rawValue: "alias-a")
    private let b = try! ItemID(rawValue: "alias-b")
    private let feed = try! ItemID(rawValue: "alias-feed")
    private let revision = try! RevisionID(rawValue: "alias-revision")
    private let date = Date(timeIntervalSince1970: 10_000)
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("alias-ios-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func entries(terminal: Bool = false, choiceAt: Date? = nil) throws -> [LibraryEntry] {
        let association = LibraryEpisodeAssociation(groupID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            representativeID: a, memberIDs: [a, b], associationVersion: 1, isTerminal: terminal,
            latestManualChoice: choiceAt.map { _ in terminal ? .skip : .keep }, manualDecidedAt: choiceAt)
        return try [a, b].map { id in
            try LibraryEntry(id: id, kind: .podcastEpisode, sourceID: feed, title: id == a ? "Representative" : "Backing",
                summary: "", publishedAt: date, durationSeconds: 600,
                removal: terminal ? .retired : .none, removedAt: terminal ? date : nil, episodeAssociation: association)
        }
    }

    private func fixture() async throws -> (LibraryAppModel, FileMediaCache, InMemoryLibraryTransport, InMemoryLibraryTransport, FileLibraryStore) {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "owner")
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "owner")
        let values = try entries()
        var changes = values.map(LibraryChange.entry)
        changes.append(.slot(try QueueSlot(entryID: b, sortKey: 0)))
        let push = try await mac.push(changes: changes.enumerated().map {
            .init(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })
        XCTAssertTrue(push.failures.isEmpty)
        let store = FileLibraryStore(url: scratch.appendingPathComponent("mirror.json"))
        _ = try await LibraryReconciler(transport: phone, store: store).synchronize().get()
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        try await cache.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let input = scratch.appendingPathComponent("audio")
        try Data([1, 2, 3, 4]).write(to: input)
        let offer = try LibraryMediaOffer(entryID: b, revisionID: revision, contentHash: MediaHash.sha256(fileAt: input),
            byteCount: 4, mediaType: "audio/mp4", durationSeconds: 600,
            preparation: .init(preparedAt: Timestamp(date)))
        let admission = await cache.admission(entryID: b, ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope,
                                              transportGeneration: 0)
        _ = try await cache.adopt(verifiedFile: input, for: offer, admission: XCTUnwrap(admission))
        let model = LibraryAppModel(transport: phone, store: store, deviceID: "phone", mediaCache: cache)
        await model.loadLocalState()
        return (model, cache, mac, phone, store)
    }

    private func player(_ model: LibraryAppModel) -> LibraryPlayer {
        let player = LibraryPlayer(engine: RuntimeFakeEngine(), session: RuntimeFakeSession(),
            nowPlaying: RuntimeFakeNowPlaying(), remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents())
        model.attachPlayer(player)
        return player
    }

    func testBOnlyCertifiedBackingDisplaysAAndPlaysRawBAt123() async throws {
        let (model, cache, _, _, _) = try await fixture()
        let observed = ObservedPlayback(record: try DevicePlaybackPosition(deviceID: "mac", entryID: b,
            revision: revision, positionSeconds: 123, isPlaying: false, epoch: 2), serverModifiedAt: date)
        model.handoffState.ownPositions[b] = observed
        model.rebuildRows()
        XCTAssertEqual(model.queued.map(\.id), [b])
        XCTAssertEqual(model.visibleRows.map(\.id), [a])
        XCTAssertEqual(model.mediaState(for: a), .onPhone)
        let player = player(model)
        let row = try XCTUnwrap(model.visibleRows.first)
        let outcome = await model.playCachedWithoutToggling(row)
        XCTAssertEqual(outcome, .resumed)
        XCTAssertEqual(player.item?.entryID, b)
        XCTAssertEqual(player.position, 123)
        await model.refresh()
        XCTAssertEqual(player.item?.entryID, b, "Display folding cannot withdraw a retained raw slot")
        XCTAssertEqual(model.queued.map(\.id), [b])
        let inventory = await cache.cachedEntries()
        XCTAssertNotNil(inventory[b])
        XCTAssertNil(inventory[a])
    }

    func testRealCacheReopenRetainsBOnlyProofForOfflineAStart() async throws {
        let (model, _, _, _, store) = try await fixture()
        await model.refresh()
        let reopened = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let offline = AliasOfflineTransport()
        let cold = LibraryAppModel(transport: offline, store: store, deviceID: "phone", mediaCache: reopened)
        await cold.loadLocalState()
        XCTAssertEqual(cold.visibleRows.map(\.id), [a])
        XCTAssertEqual(cold.queued.map(\.id), [b])
        let requests = await offline.remoteReads
        XCTAssertEqual(requests, 0, "Reopening and inventory require no remote read")
        let player = player(cold)
        let result = try await cold.playCachedWithoutToggling(XCTUnwrap(cold.visibleRows.first))
        XCTAssertTrue(result.opensNowPlaying)
        XCTAssertEqual(player.item?.entryID, b)
        let inventory = await reopened.cachedEntries()
        XCTAssertNotNil(inventory[b]?.preparation)
        XCTAssertNil(inventory[a])
    }

    func testLogicalFinishWithdrawsLoadedBAndRestoreRetainsCacheAndOriginalIntentTime() async throws {
        let (model, cache, mac, _, _) = try await fixture()
        let player = player(model)
        _ = try await model.playCachedWithoutToggling(XCTUnwrap(model.visibleRows.first))
        await model.decide(.markDone, entryID: a)
        XCTAssertNil(player.item)
        XCTAssertTrue(model.visibleRows.isEmpty)
        let intent = try XCTUnwrap(model.decisions.first?.intent)
        let overlay = LibraryDecisionOverlay.apply(model.decisions, to: model.decisionContent)
        XCTAssertTrue(overlay.queue.isEmpty)
        XCTAssertEqual(overlay.entries[b]?.removedAt, intent.createdAt)
        XCTAssertEqual(overlay.entries[a]?.removedAt, intent.createdAt)
        await model.decide(.restore, entryID: a)
        let retainedFinish = try XCTUnwrap(model.decisions.first { $0.id == intent.id })
        let restore = try XCTUnwrap(model.decisions.first { $0.intent.action == .restore(entryID: a) })
        XCTAssertTrue(retainedFinish.supersededByRestore)
        XCTAssertTrue(retainedFinish.isSent)
        XCTAssertEqual(retainedFinish.intent, intent)
        XCTAssertGreaterThanOrEqual(restore.intent.createdAt, intent.createdAt)
        XCTAssertEqual(model.pendingDecision(for: b)?.id, restore.id)
        let sent = try await mac.listIntents()
        XCTAssertTrue(sent.contains { $0 == intent }, "Restore cannot retract or rewrite the already-sent finish")
        XCTAssertTrue(sent.contains { $0 == restore.intent })
        await model.resolveDecisions(outcomes: [])
        XCTAssertNotNil(model.decisions.first { $0.id == restore.id }, "Pre-finish snapshot must not prematurely settle Restore")
        await model.refreshMediaFromCache()
        XCTAssertEqual(model.visibleRows.map(\.id), [a])
        XCTAssertEqual(model.queued.map(\.id), [b])
        let inventory = await cache.cachedEntries()
        XCTAssertNotNil(inventory[b]?.preparation)
    }

    func testNewerExplicitMetadataSupersedesStaleFinishOverlay() async throws {
        let (model, cache, mac, _, store) = try await fixture()
        let before = await cache.cachedEntries()[b]
        await model.decide(.markDone, entryID: a)
        let old = try XCTUnwrap(model.decisions.first)
        let choiceAt = old.intent.createdAt.addingTimeInterval(1)
        let saved = await store.state()
        let changes = try entries(choiceAt: choiceAt).enumerated().map { offset, entry in
            let change = LibraryChange.entry(entry)
            return PendingLibraryChange(localSeq: UInt64(offset + 100), change: change,
                                        baseVersion: saved.versions[change.key] ?? 0)
        }
        let pushed = try await mac.push(changes: changes)
        XCTAssertTrue(pushed.failures.isEmpty)
        // Mirror commitment and cache readmission are both part of a real refresh.
        // Merely assigning metadata cannot certify a previously withdrawn row.
        await model.refresh()
        XCTAssertEqual(model.visibleRows.map(\.id), [a])
        XCTAssertEqual(model.queued.map(\.id), [b])
        XCTAssertEqual(model.decisionContent.entries[b]?.episodeAssociation?.manualDecidedAt, choiceAt)
        XCTAssertTrue(model.decisions.isEmpty)
        let retained = await cache.cachedEntries()[b]
        XCTAssertEqual(retained, before, "A later Keep reuses the exact raw B preparation, epochs and bytes")
        let sent = try await mac.listIntents()
        XCTAssertTrue(sent.contains { $0 == old.intent }, "New metadata never rewrites the original finish chronology")
    }

    func testAliasMetadataDoesNotCertifyChangedBytesOrNotReadyBacking() async throws {
        let (model, cache, _, _, _) = try await fixture()
        let inventory = await cache.cachedEntries()
        let backing = try XCTUnwrap(inventory[b])
        try Data([9, 8, 7, 6]).write(to: backing.url)
        let player = player(model)
        let result = try await model.playCachedWithoutToggling(XCTUnwrap(model.visibleRows.first))
        XCTAssertFalse(result.opensNowPlaying)
        XCTAssertNil(player.item)
        // An authoritative negative still revokes raw B, regardless of its display identity.
        let negative = LibraryMediaOffer.notReady(entryID: b)
        let possible = await model.mediaContext(live: true)
        let context = try XCTUnwrap(possible)
        let applied = await model.applyMediaOffers([negative], context: context)
        XCTAssertTrue(applied)
        let after = await cache.cachedEntries()
        XCTAssertNil(after[b])
        XCTAssertNil(after[a])
    }

    func testRestoreOverlayChangesEveryMemberWithoutInventingTransportSlots() throws {
        let values = try entries(terminal: true)
        var content = LibrarySnapshot()
        for entry in values { content.entries[entry.id] = entry }
        let intent = try LibraryIntent(id: "alias-restore", deviceID: "phone", createdAt: date.addingTimeInterval(1),
                                      action: .restore(entryID: a))
        let pending = PendingDecision(intent: intent, baseline: try XCTUnwrap(EntryPlacement(of: a, in: content)))
        let restored = LibraryDecisionOverlay.apply([pending], to: content)
        XCTAssertEqual(restored.entries[a]?.removal, LibraryRemoval.none)
        XCTAssertEqual(restored.entries[b]?.removal, LibraryRemoval.none)
        XCTAssertEqual(restored.entries[b]?.episodeAssociation?.manualDecidedAt, intent.createdAt)
        XCTAssertEqual(restored.entries[a]?.episodeAssociation?.isTerminal, false)
        XCTAssertTrue(restored.queue.isEmpty)
        XCTAssertEqual(content.entries[b]?.removal, .retired)
    }

    func testLargeAssociationProjectionResolvesOnceIndependentOfRenderedRows() throws {
        let model = LibraryAppModel(transport: InMemoryLibraryTransport(deviceID: "phone",
            server: InMemoryLibraryServer(writerDeviceID: "mac"), verifiedOwnerToken: "owner"), deviceID: "phone")
        var content = LibrarySnapshot()
        for index in 0..<300 {
            let ids = try ["large-\(index)-a", "large-\(index)-b"].map { try ItemID(rawValue: $0) }
            let group = LibraryEpisodeAssociation(groupID: UUID(), representativeID: ids[0], memberIDs: ids,
                associationVersion: 1, isTerminal: false)
            for id in ids {
                content.entries[id] = try LibraryEntry(id: id, kind: .podcastEpisode, sourceID: feed,
                    title: id.rawValue, summary: "", publishedAt: date, episodeAssociation: group)
                content.slots[id] = try QueueSlot(entryID: id, sortKey: Double(content.slots.count))
            }
        }
        model.decisionContent = content
        model.rebuildRows()
        let resolved = model.episodeAssociationResolutionCount
        XCTAssertEqual(resolved, 1)
        XCTAssertEqual(model.logicalQueued.count, 300)
        for row in model.queued {
            XCTAssertNotNil(model.episodeGroup(row.id))
            _ = model.logicalEntryID(row.id)
            _ = model.sameLogicalEpisode(row.id, row.id)
            _ = model.logicalIDs([row.id])
        }
        _ = model.logicalProgress; _ = model.logicalFinished
        model.rebuildRows()
        XCTAssertEqual(model.episodeAssociationResolutionCount, resolved,
            "Rows and unchanged rebuilds must reuse the coherent membership map")
    }

    func testProjectionTracksOptimisticRollbackVersionAndAccountReset() async throws {
        let (model, _, _, _, _) = try await fixture()
        let initial = model.episodeAssociationResolutionCount
        await model.decide(.markDone, entryID: a)
        XCTAssertEqual(model.projectedEpisodeGroupsByMember[b]?.isTerminal, true)
        XCTAssertEqual(model.episodeGroup(b)?.isTerminal, false, "Fetched metadata alone settles decisions")
        XCTAssertEqual(model.episodeAssociationResolutionCount, initial)
        model.cancelDecision(entryID: a)
        XCTAssertEqual(model.projectedEpisodeGroupsByMember[b]?.isTerminal, false)
        XCTAssertEqual(model.logicalQueued.map(\.id), [a])
        let updated = LibraryEpisodeAssociation(groupID: try XCTUnwrap(model.episodeGroup(a)).groupID,
            representativeID: b, memberIDs: [a, b], associationVersion: 2, isTerminal: false)
        var content = model.decisionContent
        for value in try entries() {
            content.entries[value.id] = try LibraryEntry(id: value.id, kind: value.kind, sourceID: value.sourceID,
                title: value.title, summary: value.summary, publishedAt: value.publishedAt,
                durationSeconds: value.durationSeconds, episodeAssociation: updated)
        }
        model.decisionContent = content
        model.rebuildRows()
        XCTAssertEqual(model.episodeGroup(a)?.associationVersion, 2)
        XCTAssertEqual(model.logicalEntryID(a), b)
        XCTAssertEqual(model.logicalQueued.map(\.id), [b])
        XCTAssertEqual(model.episodeAssociationResolutionCount, initial + 1)
        model.discardDecisionsAfterAccountChange()
        XCTAssertNil(model.episodeGroup(a))
        XCTAssertEqual(model.logicalEntryID(a), a)
        XCTAssertTrue(model.projectedEpisodeGroupsByMember.isEmpty)
        XCTAssertTrue(model.logicalProgress.isEmpty)
    }

    func testAssociatedContinuationExactBackingRetains123AndMismatchRefuses() async throws {
        let (model, _, _, _, _) = try await fixture()
        let source = ObservedPlayback(record: try DevicePlaybackPosition(deviceID: "mac", entryID: b,
            revision: revision, positionSeconds: 123, isPlaying: false, epoch: 2), serverModifiedAt: date)
        let inventory = await model.continuationInventory()
        let plan = LibraryContinuationPlanner.plan(records: .init(nowPlaying: [source]), deviceID: "phone",
            cachedRevisions: inventory.revisions, durations: model.entryDurations, now: date, clockOffset: 0,
            entries: Array(model.decisionContent.entries.values), mediaOffers: inventory.offers)
        guard case let .ready(id, position, _, _, _, retained) = plan else { return XCTFail("Exact B must continue") }
        XCTAssertEqual(id, b)
        XCTAssertEqual(position, 123)
        XCTAssertEqual(retained, source)
        let mismatch = LibraryContinuationPlanner.plan(records: .init(nowPlaying: [source]), deviceID: "phone",
            cachedRevisions: [a: revision], durations: model.entryDurations, now: date, clockOffset: 0,
            entries: Array(model.decisionContent.entries.values), mediaOffers: inventory.offers)
        guard case .refused = mismatch else { return XCTFail("Metadata alone cannot translate to A") }
    }
}


private actor AliasOfflineTransport: LibraryTransport {
    private(set) var remoteReads = 0
    func verifiedOwnerToken() async -> String? { "owner" }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        remoteReads += 1
        throw LibraryTransportError.transport("offline")
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        throw LibraryTransportError.transport("offline")
    }
    func send(intent: LibraryIntent) async throws { throw LibraryTransportError.transport("offline") }
    func listIntents() async throws -> [LibraryIntent] { [] }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
        remoteReads += 1
        throw LibraryTransportError.transport("offline")
    }
}
