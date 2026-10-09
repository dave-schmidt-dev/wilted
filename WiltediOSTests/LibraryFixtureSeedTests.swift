import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Not a test: a seeding tool for attended simulator runs (CarPlay, Siri, the Larder). Hosted tests
/// run inside the app, so this writes into the app's own container; a later plain launch of the app
/// then lists one downloaded episode with no iCloud account and no network.
///
///     touch /abs/path/tone.m4a.seed-once
///     TEST_RUNNER_WILTED_SEED_AUDIO=/abs/path/tone.m4a xcodebuild test ... \
///         -only-testing:WiltediOSTests/LibraryFixtureSeedTests
///
/// Skipped unless `WILTED_SEED_AUDIO` names a real audio file and its one-shot `.seed-once` token file
/// exists (the test removes the token), so a leftover exported variable never wipes the app's data.
@MainActor
final class LibraryFixtureSeedTests: XCTestCase {
    func testSeedOneDownloadedEpisodeIntoTheAppContainer() async throws {
        guard let path = ProcessInfo.processInfo.environment["WILTED_SEED_AUDIO"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_WILTED_SEED_AUDIO to an audio file to seed a fixture library")
        }
        // One-shot: the seed deletes the app's library and cache, so an exported variable left over from
        // an attended run must never re-trigger it. Create `<audio>.seed-once` to allow exactly one seed.
        let token = URL(fileURLWithPath: path + ".seed-once")
        guard FileManager.default.fileExists(atPath: token.path) else {
            throw XCTSkip("create \(token.path) to allow one seed")
        }
        defer { try? FileManager.default.removeItem(at: token) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let duration = Double(ProcessInfo.processInfo.environment["WILTED_SEED_SECONDS"] ?? "") ?? 90

        let directory = LibraryEnvironment.defaultDirectory()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: FileMediaCache.defaultRoot())
        let store = FileLibraryStore(url: directory.appendingPathComponent("library-state.json"))
        let cache = FileMediaCache(rootURL: FileMediaCache.defaultRoot())

        let entryID = try ItemID(rawValue: "fixture-episode-1")
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let show = LibrarySource(id: try ItemID(rawValue: "fixture-show"), kind: .podcastFeed, title: "Fixture Show")
        let entry = try LibraryEntry(
            id: entryID, kind: .podcastEpisode, sourceID: show.id, title: "Fixture tone episode", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: duration)
        let changes: [LibraryChange] = [.source(show), .entry(entry), .slot(try QueueSlot(entryID: entryID, sortKey: 0))]
        _ = try await mac.push(changes: changes.enumerated().map {
            PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })

        let suite = "wilted.fixtureseed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "fixture-phone", server: server, verifiedOwnerToken: "fixture-owner"), store: store,
            deviceID: "fixture-phone", mediaCache: cache, preferences: defaults)
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id), [entryID])

        let hash = MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: entryID, revisionID: try RevisionID(rawValue: "fixture-rev-1"), contentHash: hash,
            byteCount: Int64(data.count), mediaType: "audio/mp4", durationSeconds: duration))
        // `adopt` moves the file in, so hand it a copy and leave the source intact.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString).m4a")
        try data.write(to: staged)
        _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: staged, for: offer, owner: "fixture-owner")
        let onPhone = await cache.cachedEntries()[entryID]
        XCTAssertNotNil(onPhone, "the audio must be on the phone")
    }

    func testNormalRootFixtureKeepsTruthfulPreparedProofAndIsolatedHeldAccount() async throws {
        let normal = LibraryUITestFixture.Stack(scenario: .normal)
        let held = LibraryUITestFixture.Stack(scenario: .heldAccount)
        addTeardownBlock { @MainActor in
            try await normal.closeFixture()
            try await held.closeFixture()
        }
        await normal.seed()
        await held.seed()
        await normal.model.loadLocalState()
        await held.model.loadLocalState()
        let cached = await normal.model.mediaCache.cachedEntries()
        XCTAssertEqual(Set(cached.keys.map(\.rawValue)), Set(LibraryUITestFixture.episodeIDs))
        for media in cached.values {
            let proof = try XCTUnwrap(media.preparation)
            XCTAssertEqual(proof.ownerToken, "fixture-owner")
            XCTAssertEqual(proof.libraryScope, LibraryAppModel.mediaLibraryScope)
            XCTAssertEqual(proof.offer.preparation?.schemaVersion, 1)
            XCTAssertEqual(proof.offer.preparation?.preparedAt, Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
            XCTAssertEqual(proof.offer.revisionID, try RevisionID(rawValue: "rev-1"))
            XCTAssertEqual(proof.offer.byteCount, 512)
            XCTAssertEqual(proof.offer.contentHash, PreparedMediaFixture.hash(Data(repeating: 7, count: 512)))
            let verified = await normal.model.mediaCache.verifies(media)
            XCTAssertTrue(verified)
        }
        XCTAssertEqual(normal.model.queued.count, 2)
        XCTAssertEqual(normal.model.visibleRows.count, 2)
        XCTAssertTrue(held.model.accountQuarantined)
        XCTAssertEqual(held.model.queued.count, 2, "the real held mirror retains the original queue")
        let heldEntries = await held.model.mediaCache.cachedEntries()
        XCTAssertTrue(heldEntries.isEmpty, "a review hold cannot grant playback admission")
        let normalAfterHeld = await normal.model.mediaCache.cachedEntries()
        XCTAssertEqual(normalAfterHeld.count, 2, "the second Stack cannot delete the first Stack's scratch")
    }

    func testDelayedRootCacheDelegatesAdmissionVerificationAndRevocation() async throws {
        let stack = LibraryUITestFixture.Stack(scenario: .normal)
        addTeardownBlock { @MainActor in try await stack.closeFixture() }
        await stack.seed()
        await stack.model.loadLocalState()
        let inner = try XCTUnwrap(stack.model.mediaCache as? FileMediaCache)
        let delayed = LibraryUITestDelayedCache(inner: inner, delay: .zero)
        let id = try ItemID(rawValue: LibraryUITestFixture.episodeIDs[0])
        let entries = await delayed.cachedEntries()
        let cached = try XCTUnwrap(entries[id])
        let proof = try XCTUnwrap(cached.preparation)
        let issued = await delayed.admission(entryID: id, ownerToken: "fixture-owner",
            libraryScope: LibraryAppModel.mediaLibraryScope, transportGeneration: 0)
        let admission = try XCTUnwrap(issued)
        let permitsBefore = await delayed.permits(admission, for: proof.offer)
        let verifiesBefore = await delayed.verifies(cached)
        let fileBefore = await delayed.cachedFile(for: proof.offer, admission: admission)
        XCTAssertTrue(permitsBefore)
        XCTAssertTrue(verifiesBefore)
        XCTAssertEqual(fileBefore, cached.url)
        try await delayed.revokePreparation(entryID: id)
        let permitsAfter = await delayed.permits(admission, for: proof.offer)
        let verifiesAfter = await delayed.verifies(cached)
        let fileAfter = await delayed.cachedFile(for: proof.offer, admission: admission)
        XCTAssertFalse(permitsAfter)
        XCTAssertFalse(verifiesAfter, "the old snapshot is not permission after real ledger revocation")
        XCTAssertNil(fileAfter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.url.path), "revocation preserves exact cached bytes")
        let refreshed = await delayed.cachedEntries()
        XCTAssertNil(refreshed[id])
        try await delayed.bindOwner(ownerToken: "other-owner", libraryScope: LibraryAppModel.mediaLibraryScope, held: false)
        let wrongOwner = await delayed.admission(entryID: id, ownerToken: "fixture-owner",
            libraryScope: LibraryAppModel.mediaLibraryScope, transportGeneration: 0)
        XCTAssertNil(wrongOwner)
    }

}
