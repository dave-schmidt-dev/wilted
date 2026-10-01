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
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
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
            transport: InMemoryLibraryTransport(deviceID: "fixture-phone", server: server), store: store,
            deviceID: "fixture-phone", mediaCache: cache, preferences: defaults)
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id), [entryID])

        let hash = MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let offer = try LibraryMediaOffer(
            entryID: entryID, revisionID: try RevisionID(rawValue: "fixture-rev-1"), contentHash: hash,
            byteCount: Int64(data.count), mediaType: "audio/mp4", durationSeconds: duration)
        // `adopt` moves the file in, so hand it a copy and leave the source intact.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString).m4a")
        try data.write(to: staged)
        _ = try await cache.adopt(verifiedFile: staged, for: offer)
        let onPhone = await cache.cachedEntries()[entryID]
        XCTAssertNotNil(onPhone, "the audio must be on the phone")
    }
}
