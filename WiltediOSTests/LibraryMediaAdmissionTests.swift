import AVFoundation
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Local admission uses canonical byte identity without requiring a current Mac offer.
@MainActor
final class LibraryMediaAdmissionTests: XCTestCase {
    private var scratch: URL!
    private let entry = try! ItemID(rawValue: "audio-a")
    private let revision = try! RevisionID(rawValue: "rev-a")
    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("audio-admission-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }
    private func fixture() async throws -> (FileMediaCache, LibraryMediaOffer, URL) {
        let input = scratch.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: input)
        let offer = try LibraryMediaOffer(entryID: entry, revisionID: revision,
            contentHash: MediaHash.sha256(fileAt: input), byteCount: 4, mediaType: "audio/mp4",
            preparation: .init(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))))
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        try await cache.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        return (cache, offer, try await cache.adopt(verifiedFile: input, for: offer, admission: try await cacheAdmission(cache)))
    }
    func testInventoryExcludesCanonicalLegacyBytesWithoutPreparationProof() async throws {
        let (cache, offer, file) = try await canonicalLegacyFixture()
        XCTAssertEqual(try MediaHash.sha256(fileAt: file), offer.contentHash)
        XCTAssertEqual(try Data(contentsOf: file).count, Int(offer.byteCount))
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(names, [file.lastPathComponent], "The revision contains exact audio bytes only, with no preparation proof")
        let entries = await cache.cachedEntries()
        XCTAssertNil(entries[entry], "A valid canonical hash does not establish that the Mac prepared the audio")
    }

    func testRealCacheRefusesAdoptingLegacyReadyOfferWithoutPreparationProof() async throws {
        let input = scratch.appendingPathComponent("legacy-ready-delivery")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: input)
        let offer = try LibraryMediaOffer(entryID: entry, revisionID: revision,
            contentHash: MediaHash.sha256(fileAt: input), byteCount: Int64(bytes.count), mediaType: "audio/mp4")
        XCTAssertEqual(offer.state, .ready, "This is the existing legacy ready contract, not a notReady offer")
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("legacy-adoption-cache"))
        try await cache.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        do {
            _ = try await cache.adopt(verifiedFile: input, for: offer, admission: try await cacheAdmission(cache))
            XCTFail("Exact bytes and a legacy ready offer must not be adopted as prepared audio")
        } catch {
            // Refusal is the admission boundary; no new error or certificate API is assumed.
        }
        let entries = await cache.cachedEntries()
        XCTAssertNil(entries[entry], "Rejected legacy adoption must not leave playable inventory")
    }

    func testSelectedOnPhoneLarderRowCannotStartCanonicalLegacyBytes() async throws {
        let (cache, offer, file) = try await canonicalLegacyFixture()
        XCTAssertEqual(try MediaHash.sha256(fileAt: file), offer.contentHash)
        let model = try await admissionModel(cache: cache, transport: AdmissionTransport())
        model.decisionContent.entries[entry] = try LibraryEntry(id: entry, kind: .podcastEpisode,
            sourceID: entry, title: "Legacy episode", summary: "", publishedAt: Date(), durationSeconds: 600)
        model.decisionContent.slots[entry] = try QueueSlot(entryID: entry, sortKey: 0)
        model.rebuildRows()
        model.media[entry] = .onPhone
        let engine = RuntimeFakeEngine()
        let session = RuntimeFakeSession()
        let player = LibraryPlayer(engine: engine, session: session,
            nowPlaying: RuntimeFakeNowPlaying(), remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents())
        model.attachPlayer(player)
        let row = try XCTUnwrap(model.queued.first)
        XCTAssertEqual(row.id, entry, "The real model has a current Larder row")
        XCTAssertEqual(model.mediaState(for: entry), .onPhone, "The UI state alone must not certify preparation")
        let outcome = await model.playCachedWithoutToggling(row)
        XCTAssertFalse(outcome.opensNowPlaying, "Selected playback must refuse legacy bytes despite valid identity and On phone state")
        XCTAssertNil(player.item, "The actual player must never retain an unprepared legacy item")
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(session.activations, 0, "Rejected local admission must not activate the playback session")
    }

    /// Writes the exact canonical legacy layout directly, bypassing adoption and all preparation metadata.
    private func canonicalLegacyFixture() async throws -> (FileMediaCache, LibraryMediaOffer, URL) {
        let bytes = Data([1, 2, 3, 4])
        let input = scratch.appendingPathComponent("legacy-hash-source")
        try bytes.write(to: input)
        let offer = try LibraryMediaOffer(entryID: entry, revisionID: revision,
            contentHash: MediaHash.sha256(fileAt: input), byteCount: Int64(bytes.count), mediaType: "audio/mp4")
        let root = scratch.appendingPathComponent("canonical-legacy-cache", isDirectory: true)
        let directory = root.appendingPathComponent(entry.rawValue, isDirectory: true)
            .appendingPathComponent(revision.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(offer.contentHash.dropFirst(MediaHash.prefix.count)) + ".m4a"
        let file = directory.appendingPathComponent(name)
        try bytes.write(to: file)
        let cache = FileMediaCache(rootURL: root)
        try await cache.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        return (cache, offer, file)
    }

    private func cacheAdmission(_ cache: FileMediaCache) async throws -> MediaCacheAdmission {
        let token = await cache.admission(entryID: entry, ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, transportGeneration: 0)
        return try XCTUnwrap(token)
    }

    func testInventoryRejectsArbitraryFileName() async throws {
        let (cache, _, file) = try await fixture()
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("wrong.m4a"))
        let entries = await cache.cachedEntries()
        XCTAssertNil(entries[entry])
    }
    func testInventoryRejectsUnsupportedExtension() async throws {
        let (cache, _, file) = try await fixture()
        try FileManager.default.moveItem(at: file, to: file.deletingPathExtension().appendingPathExtension("txt"))
        let entries = await cache.cachedEntries()
        XCTAssertNil(entries[entry])
    }
    func testInventoryRejectsSymlinkFile() async throws {
        let (cache, _, file) = try await fixture()
        let outside = scratch.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: file, to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let entries = await cache.cachedEntries()
        XCTAssertNil(entries[entry])
    }
    func testInventoryRejectsSymlinkRevisionDirectory() async throws {
        let (cache, _, file) = try await fixture()
        let directory = file.deletingLastPathComponent(), outside = scratch.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: directory, to: outside)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        let entries = await cache.cachedEntries()
        XCTAssertNil(entries[entry])
    }
    func testExactReuseRejectsSameSizeCorruption() async throws {
        let (cache, offer, file) = try await fixture()
        try Data([4, 3, 2, 1]).write(to: file)
        let reused = await cache.cachedFile(for: offer, admission: try await cacheAdmission(cache))
        XCTAssertNil(reused)
    }
    func testAdoptionCollisionKeepsNewVerifiedDelivery() async throws {
        let (cache, offer, file) = try await fixture()
        try Data([4, 3, 2, 1]).write(to: file)
        let delivery = scratch.appendingPathComponent("new-delivery")
        try Data([1, 2, 3, 4]).write(to: delivery)
        let adopted = try await cache.adopt(verifiedFile: delivery, for: offer, admission: try await cacheAdmission(cache))
        XCTAssertEqual(try Data(contentsOf: adopted), Data([1, 2, 3, 4]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.path))
    }
    func testEligibilityLostWhileSelectedHashAwaitsCannotLoad() async throws {
        try await heldVerification { model in model.media[self.entry] = .available }
    }
    func testNewCommandWhileSelectedHashAwaitsCannotLoad() async throws {
        try await heldVerification { model in _ = model.beginExternalStart() }
    }
    func testEntryDisappearingWhileSelectedHashAwaitsCannotLoad() async throws {
        try await heldVerification { model in
            model.decisionContent.entries[self.entry] = nil
            model.rebuildRows()
        }
    }
    func testAccountGenerationChangingWhileSelectedHashAwaitsCannotLoad() async throws {
        try await heldVerification(changeGeneration: true) { _ in }
    }
    private func admissionModel(cache: any LibraryMediaCache, transport: AdmissionTransport) async throws -> LibraryAppModel {
        let store = FileLibraryStore(url: scratch.appendingPathComponent("mirror-\(UUID()).json"))
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "owner")
        let bootstrap = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "owner")
        let value = try LibraryEntry(id: entry, kind: .podcastEpisode, sourceID: entry,
            title: "Episode", summary: "", publishedAt: Date(), durationSeconds: 600)
        let slot = try QueueSlot(entryID: entry, sortKey: 0)
        let pushed = try await mac.push(changes: [
            .init(localSeq: 1, change: .entry(value), baseVersion: 0),
            .init(localSeq: 2, change: .slot(slot), baseVersion: 0)])
        XCTAssertTrue(pushed.failures.isEmpty)
        _ = try await LibraryReconciler(transport: bootstrap, store: store).synchronize().get()
        let accepted = await store.state()
        XCTAssertEqual(accepted.ownerToken, "owner")
        XCTAssertFalse(accepted.reviewHold)
        XCTAssertEqual(accepted.content.entries[entry], value)
        XCTAssertEqual(accepted.content.queue.map(\.entryID), [entry])
        let model = LibraryAppModel(transport: transport, store: store, deviceID: "phone", mediaCache: cache)
        await model.loadLocalState()
        return model
    }

    private func heldVerification(changeGeneration: Bool = false, _ intervene: @MainActor (LibraryAppModel) -> Void) async throws {
        let (files, _, _) = try await fixture()
        let gate = AdmissionCache(files)
        let transport = AdmissionTransport()
        let model = try await admissionModel(cache: gate, transport: transport)
        let accepted = await model.mediaStoreState()
        XCTAssertEqual(accepted.ownerToken, "owner")
        XCTAssertEqual(model.decisionContent.entries[entry], accepted.content.entries[entry])
        XCTAssertEqual(model.queued.map(\.id), [entry])
        model.media[entry] = .onPhone
        let player = LibraryPlayer(engine: RuntimeFakeEngine(), session: RuntimeFakeSession(),
            nowPlaying: RuntimeFakeNowPlaying(), remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents())
        model.attachPlayer(player)
        let row = try XCTUnwrap(model.queued.first)
        let pending = Task { await model.playCachedWithoutToggling(row) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.isHeld), ContinuousClock.now < deadline { await Task.yield() }
        let held = await gate.isHeld
        XCTAssertTrue(held, "the actual selected verifier must be suspended")
        intervene(model)
        if changeGeneration { await transport.advanceGeneration() }
        await gate.release()
        _ = await pending.value
        XCTAssertNil(player.item)
        XCTAssertFalse(player.isPlaying)
    }
    func testProductionEngineIsReleasedWhenPlayerIsStopped() throws {
        let file = try toneFile()
        let engine = LibraryAudioEngine()
        let player = LibraryPlayer(engine: engine, session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
                                   remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents())
        XCTAssertTrue(player.start(.init(entryID: entry, title: "Tone", showTitle: "", fileURL: file), autoplay: false))
        XCTAssertGreaterThan(engine.duration, 0)
        player.stop()
        XCTAssertEqual(engine.duration, 0, "clearing the model must release the actual decoder")
        XCTAssertFalse(engine.play())
    }

    private func toneFile() throws -> URL {
        let file = scratch.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 8_000)
        do {
            let writer = try AVAudioFile(forWriting: file, settings: format.settings)
            try writer.write(from: buffer)
        }
        return file
    }

    func testFailedReplacementLoadReleasesPreviouslyRetainedProductionEngine() throws {
        let engine = LibraryAudioEngine()
        let player = LibraryPlayer(engine: engine, session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
                                   remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents())
        XCTAssertTrue(player.start(.init(entryID: entry, title: "Tone", showTitle: "", fileURL: try toneFile()), autoplay: false))
        XCTAssertFalse(player.start(.init(entryID: entry, title: "Missing", showTitle: "",
            fileURL: scratch.appendingPathComponent("missing.wav")), autoplay: false))
        XCTAssertNil(player.item)
        XCTAssertEqual(engine.duration, 0)
        XCTAssertFalse(engine.play())
    }

    func testCertifiedMarkerReopensOfflineOnlyAfterSameOwnerBinding() async throws {
        let (_, offer, file) = try await fixture()
        let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reopened = FileMediaCache(rootURL: root)
        let unbound = await reopened.cachedEntries()
        XCTAssertTrue(unbound.isEmpty, "A stored owner is not a current binding")
        try await reopened.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let inventory = await reopened.cachedEntries()
        let cached = try XCTUnwrap(inventory[entry])
        XCTAssertEqual(cached.preparation?.offer, offer)
        let verified = await reopened.verifies(cached)
        XCTAssertTrue(verified, "Exact proof survives offline without a current Mac offer")
    }

    func testCertifiedCutLikeRevisionBindsItsOwnExactIdentity() async throws {
        let (cache, _, original) = try await fixture()
        let cut = scratch.appendingPathComponent("synthetic-cut")
        try Data([8, 7, 6]).write(to: cut)
        let offer = try LibraryMediaOffer(entryID: entry, revisionID: RevisionID(rawValue: "cut-r2"),
            contentHash: MediaHash.sha256(fileAt: cut), byteCount: 3, mediaType: "audio/mp4",
            preparation: .init(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_001))))
        let adopted = try await cache.adopt(verifiedFile: cut, for: offer, admission: try await cacheAdmission(cache))
        XCTAssertNotEqual(adopted, original)
        let cached = await cache.cachedFile(for: offer, admission: try await cacheAdmission(cache))
        XCTAssertEqual(cached, adopted)
    }

    func testHashAwaitRejectsRevocationOwnerChangeAndReviewHoldAfterActualVerification() async throws {
        for intervention in ["revoke", "owner", "hold"] {
            let (_, _, file) = try await fixture()
            let gate = PreparationHashGate()
            let reader = FileMediaCache(rootURL: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
                byteVerifier: { url, count, hash in
                    let actual = await MediaFetcher.verifies(url, byteCount: count, contentHash: hash)
                    await gate.hold()
                    return actual
                })
            try await reader.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
            let entries = await reader.cachedEntries()
            let cached = try XCTUnwrap(entries[entry])
            let pending = Task { await reader.verifies(cached) }
            await gate.waitUntilHeld()
            if intervention == "revoke" { try await reader.revokePreparation(entryID: entry) }
            else { try await reader.bindOwner(ownerToken: intervention == "owner" ? "other" : "owner",
                libraryScope: LibraryAppModel.mediaLibraryScope, held: intervention == "hold") }
            await gate.release()
            let admitted = await pending.value
            XCTAssertFalse(admitted, "The post-hash ledger fence must reject \(intervention)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Revocation does not destroy retained bytes")
        }
    }

    func testAdoptionHashAwaitCannotPublishProofAfterEntryRevocation() async throws {
        let (_, offer, file) = try await fixture()
        let input = scratch.appendingPathComponent("held-delivery")
        try Data(contentsOf: file).write(to: input)
        let gate = PreparationHashGate()
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("held-adoption"), byteVerifier: { url, count, hash in
            let actual = await MediaFetcher.verifies(url, byteCount: count, contentHash: hash)
            await gate.hold()
            return actual
        })
        try await cache.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let token = try await cacheAdmission(cache)
        let pending = Task {
            do { _ = try await cache.adopt(verifiedFile: input, for: offer, admission: token); return true }
            catch { return false }
        }
        await gate.waitUntilHeld()
        try await cache.revokePreparation(entryID: entry)
        await gate.release()
        let succeeded = await pending.value
        XCTAssertFalse(succeeded)
        let inventory = await cache.cachedEntries()
        XCTAssertTrue(inventory.isEmpty)
    }

    func testRevocationPersistsAndFreshCertifiedDeliveryReauthorizesRetainedBytes() async throws {
        let (cache, offer, file) = try await fixture()
        try await cache.revokePreparation(entryID: entry)
        let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reopened = FileMediaCache(rootURL: root)
        try await reopened.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let revoked = await reopened.cachedEntries()
        XCTAssertTrue(revoked.isEmpty)
        let input = scratch.appendingPathComponent("fresh-proof")
        try Data(contentsOf: file).write(to: input)
        let fresh = try LibraryMediaOffer(entryID: entry, revisionID: revision, contentHash: offer.contentHash,
            byteCount: offer.byteCount, mediaType: offer.mediaType,
            preparation: .init(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_002))))
        let adopted = try await reopened.adopt(verifiedFile: input, for: fresh, admission: try await cacheAdmission(reopened))
        XCTAssertEqual(adopted, file)
        let reauthorized = await reopened.cachedEntries()
        XCTAssertEqual(reauthorized[entry]?.preparation?.offer, fresh)
    }

    func testCorruptJournalCreatesFreshNonceAndCannotBlessOldMarker() async throws {
        let (cache, _, file) = try await fixture()
        let old = try await cacheAdmission(cache)
        let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(".preparation-ledger.json"))
        let reopened = FileMediaCache(rootURL: root)
        try await reopened.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let fresh = try await cacheAdmission(reopened)
        XCTAssertNotEqual(old.ownerEpoch, fresh.ownerEpoch)
        let inventory = await reopened.cachedEntries()
        XCTAssertTrue(inventory.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testProofWriteFailureLeavesRenamedAudioInventoryInert() async throws {
        let (_, offer, file) = try await fixture()
        let input = scratch.appendingPathComponent("marker-failure-delivery")
        try Data(contentsOf: file).write(to: input)
        let root = scratch.appendingPathComponent("marker-failure-cache")
        let cache = FileMediaCache(rootURL: root, preparationWriter: { _, _ in throw CocoaError(.fileWriteUnknown) })
        try await cache.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        do { _ = try await cache.adopt(verifiedFile: input, for: offer, admission: try await cacheAdmission(cache)); XCTFail("Proof publication must fail") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path), "The audio rename really happened before the proof write failed")
        let inventory = await cache.cachedEntries()
        XCTAssertTrue(inventory.isEmpty, "Rename without proof cannot become cached success")
    }

    func testMissingMalformedAndWrongScopeMarkersCannotEnterInventory() async throws {
        let (cache, _, file) = try await fixture()
        let marker = await cache.markerURL(file)
        let proofBytes = try Data(contentsOf: marker)
        try FileManager.default.removeItem(at: marker)
        let missing = await cache.cachedEntries()
        XCTAssertTrue(missing.isEmpty)
        try Data("not a proof".utf8).write(to: marker)
        let malformed = await cache.cachedEntries()
        XCTAssertTrue(malformed.isEmpty)
        try proofBytes.write(to: marker)
        try await cache.bindOwner(ownerToken: "owner", libraryScope: "different-library", held: false)
        let wrongScope = await cache.cachedEntries()
        XCTAssertTrue(wrongScope.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testOwnerJournalFailureCannotIssueAdmission() async throws {
        let root = scratch.appendingPathComponent("root-is-file")
        try Data([1]).write(to: root)
        let cache = FileMediaCache(rootURL: root)
        do { try await cache.bindOwner(ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false); XCTFail("Journal must fail") }
        catch {}
        let token = await cache.admission(entryID: entry, ownerToken: "owner", libraryScope: LibraryAppModel.mediaLibraryScope, transportGeneration: 0)
        XCTAssertNil(token)
    }

    func testVerifiedOfflineInventoryNeedsNoCurrentOffer() async throws {
        let (cache, _, file) = try await fixture()
        let entries = await cache.cachedEntries()
        XCTAssertEqual(entries[entry]?.url, file)
    }
}

private actor AdmissionCache: LibraryMediaCache {
    let files: FileMediaCache
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var isHeld = false
    init(_ files: FileMediaCache) { self.files = files }
    func storedAudioByteCounts() async -> [ItemID: Int64] { await files.storedAudioByteCounts() }
    func cachedEntries() async -> [ItemID: CachedMedia] { await files.cachedEntries() }
    func bindOwner(ownerToken: String?, libraryScope: String, held: Bool) async throws {
        try await files.bindOwner(ownerToken: ownerToken, libraryScope: libraryScope, held: held)
    }
    func admission(entryID: ItemID, ownerToken: String, libraryScope: String, transportGeneration: UInt64) async -> MediaCacheAdmission? {
        await files.admission(entryID: entryID, ownerToken: ownerToken, libraryScope: libraryScope, transportGeneration: transportGeneration)
    }
    func revokePreparation(entryID: ItemID) async throws { try await files.revokePreparation(entryID: entryID) }
    func permits(_ admission: MediaCacheAdmission, for offer: LibraryMediaOffer) async -> Bool { await files.permits(admission, for: offer) }

    func verifies(_ cached: CachedMedia) async -> Bool {
        await withCheckedContinuation { waiter = $0; isHeld = true }
        return await files.verifies(cached)
    }
    func release() { waiter?.resume(); waiter = nil }
    func cachedFile(for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async -> URL? { await files.cachedFile(for: offer, admission: admission) }
    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async throws -> URL {
        try await files.adopt(verifiedFile: verifiedFile, for: offer, admission: admission)
    }
    func remove(entryID: ItemID) async throws { try await files.remove(entryID: entryID) }
    func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript? { nil }
    func storeTranscript(_ transcript: LibraryTranscript) async {}
}

private actor AdmissionTransport: LibraryTransport {
    private var generation: UInt64 = 0
    func operationGeneration() -> UInt64 { generation }
    func advanceGeneration() { generation &+= 1 }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        throw LibraryTransportError.transport("offline")
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        throw LibraryTransportError.transport("offline")
    }
    func send(intent: LibraryIntent) async throws {}
    func listIntents() async throws -> [LibraryIntent] { [] }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {}
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { LibraryDeviceRecords() }
}

/// Gates only after the injected closure has completed the actual byte hash.
private actor PreparationHashGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var held = false
    func hold() async { await withCheckedContinuation { continuation = $0; held = true } }
    func waitUntilHeld() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !held, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(held, "The actual verifier await must be suspended")
    }
    func release() { continuation?.resume(); continuation = nil }
}
