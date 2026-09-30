import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The transcript on the phone: the follow-along rules, the cache beside the audio, and the
/// model's best-effort load.
@MainActor
final class LibraryTranscriptTests: XCTestCase {
    private var scratch: URL!
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    private let suite = "library-transcript-tests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: fixtures

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }
    private func revision(_ raw: String) -> RevisionID { try! RevisionID(rawValue: raw) }
    private func cues(_ starts: [Double]) -> [LibraryTranscriptCue] {
        starts.enumerated().map { LibraryTranscriptCue(start: $1, end: $1 + 1, text: "cue \($0)") }
    }

    private func timed(_ raw: String, revision rev: String = "rev-a", starts: [Double] = [0, 5, 10]) throws -> LibraryTranscript {
        try LibraryTranscript(entryID: id(raw), revisionID: revision(rev), cues: cues(starts))
    }

    private func makeCache() -> FileMediaCache { FileMediaCache(rootURL: scratch.appendingPathComponent("cache")) }

    private func cacheEpisode(_ cache: FileMediaCache, _ raw: String, revision rev: String = "rev-a") async throws {
        let data = Data(repeating: 7, count: 500)
        let hash = MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let offer = try LibraryMediaOffer(
            entryID: id(raw), revisionID: revision(rev), contentHash: hash, byteCount: 500,
            mediaType: "audio/mp4", durationSeconds: 60)
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        _ = try await cache.adopt(verifiedFile: file, for: offer)
    }

    private func makeModel(cache: FileMediaCache) -> LibraryAppModel {
        LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone",
            mediaCache: cache, preferences: defaults, timeZone: TimeZone(identifier: "UTC")!)
    }

    // MARK: follow-along rules

    func testCurrentIndexIsTheLastCueThatHasStarted() {
        let list = cues([0, 5, 10])
        XCTAssertEqual(LibraryTranscriptFollow.currentIndex(in: list, at: 0), 0)
        XCTAssertEqual(LibraryTranscriptFollow.currentIndex(in: list, at: 4.99), 0)
        XCTAssertEqual(LibraryTranscriptFollow.currentIndex(in: list, at: 5), 1)
        XCTAssertEqual(LibraryTranscriptFollow.currentIndex(in: list, at: 9999), 2)
    }

    func testCurrentIndexIsNilBeforeTheFirstCueWithoutAPositionOrWithNoCues() {
        XCTAssertNil(LibraryTranscriptFollow.currentIndex(in: cues([2, 5]), at: 1))
        XCTAssertNil(LibraryTranscriptFollow.currentIndex(in: cues([0]), at: nil))
        XCTAssertNil(LibraryTranscriptFollow.currentIndex(in: cues([0]), at: .nan))
        XCTAssertNil(LibraryTranscriptFollow.currentIndex(in: [], at: 3))
    }

    func testCurrentIndexAgreesWithTheKitsCueLookup() throws {
        let transcript = try timed("a", starts: [0, 3, 3, 8, 20])
        for seconds in stride(from: 0.0, through: 25.0, by: 0.5) {
            let index = LibraryTranscriptFollow.currentIndex(in: transcript.cues, at: seconds)
            XCTAssertEqual(index.map { transcript.cues[$0] }, transcript.cue(at: seconds), "at \(seconds)")
        }
    }

    func testAutoScrollPausesWhileDraggingAndForAFewSecondsAfter() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(LibraryTranscriptFollow.shouldAutoScroll(isDragging: false, lastTouch: nil, now: now))
        XCTAssertFalse(LibraryTranscriptFollow.shouldAutoScroll(isDragging: true, lastTouch: nil, now: now))
        XCTAssertFalse(LibraryTranscriptFollow.shouldAutoScroll(isDragging: false, lastTouch: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(LibraryTranscriptFollow.shouldAutoScroll(isDragging: false, lastTouch: now.addingTimeInterval(-4), now: now))
    }

    func testTappingACueSeeksOnlyWhenThatEpisodeIsPlaying() {
        let cue = LibraryTranscriptCue(start: 42, end: 45, text: "x")
        XCTAssertEqual(LibraryTranscriptFollow.seekTarget(for: cue, isPlayingItem: true), 42)
        XCTAssertNil(LibraryTranscriptFollow.seekTarget(for: cue, isPlayingItem: false))
    }

    // MARK: cache

    func testCacheStoresAndLoadsATranscriptBesideItsAudio() async throws {
        let cache = makeCache()
        try await cacheEpisode(cache, "a")
        let transcript = try timed("a")
        await cache.storeTranscript(transcript)
        let loaded = await cache.cachedTranscript(entryID: id("a"), revisionID: revision("rev-a"))
        XCTAssertEqual(loaded, transcript)
        let other = await cache.cachedTranscript(entryID: id("a"), revisionID: revision("rev-b"))
        XCTAssertNil(other)
        let entries = await cache.cachedEntries()
        XCTAssertEqual(entries[id("a")]?.revisionID, revision("rev-a"), "the transcript file is not mistaken for audio")
    }

    func testCacheKeepsAPlainTextTranscript() async throws {
        let cache = makeCache()
        try await cacheEpisode(cache, "a")
        let prose = try LibraryTranscript(entryID: id("a"), revisionID: revision("rev-a"), plainText: "Hello there.", isTruncated: true)
        await cache.storeTranscript(prose)
        let loaded = await cache.cachedTranscript(entryID: id("a"), revisionID: revision("rev-a"))
        XCTAssertEqual(loaded, prose)
    }

    func testCacheIgnoresATranscriptWhoseAudioIsNotCached() async throws {
        let cache = makeCache()
        await cache.storeTranscript(try timed("a"))
        let loaded = await cache.cachedTranscript(entryID: id("a"), revisionID: revision("rev-a"))
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("cache/a").path))
    }

    func testRemovingTheAudioRemovesTheTranscript() async throws {
        let cache = makeCache()
        try await cacheEpisode(cache, "a")
        await cache.storeTranscript(try timed("a"))
        try await cache.remove(entryID: id("a"))
        let loaded = await cache.cachedTranscript(entryID: id("a"), revisionID: revision("rev-a"))
        XCTAssertNil(loaded)
        await cache.storeTranscript(try timed("a"))
        let stillNone = await cache.cachedTranscript(entryID: id("a"), revisionID: revision("rev-a"))
        XCTAssertNil(stillNone, "a late store after removal writes nothing")
    }

    // MARK: model

    func testPrepareFetchesTheTranscriptForCachedAudioAndCachesIt() async throws {
        let cache = makeCache()
        try await cacheEpisode(cache, "a")
        let transcript = try timed("a")
        try await mac.publishTranscript(transcript)
        let model = makeModel(cache: cache)

        await model.prepareTranscript(entryID: id("a"))
        XCTAssertEqual(model.transcript(for: id("a")), transcript)
        let stored = await cache.cachedTranscript(entryID: id("a"), revisionID: revision("rev-a"))
        XCTAssertEqual(stored, transcript)
    }

    func testAFreshLaunchLoadsTheCachedTranscriptWithoutTheNetwork() async throws {
        let cache = makeCache()
        try await cacheEpisode(cache, "a")
        let transcript = try timed("a")
        await cache.storeTranscript(transcript)
        let model = makeModel(cache: cache) // the server holds no transcript

        await model.prepareTranscript(entryID: id("a"))
        XCTAssertEqual(model.transcript(for: id("a")), transcript)
    }

    func testAMissingTranscriptIsRetriedOncePerSessionAndNeverTouchesAudio() async throws {
        let cache = makeCache()
        try await cacheEpisode(cache, "a")
        let model = makeModel(cache: cache)

        await model.prepareTranscript(entryID: id("a"))
        XCTAssertNil(model.transcript(for: id("a")))
        try await mac.publishTranscript(try timed("a"))

        await model.prepareTranscript(entryID: id("a"))
        XCTAssertNil(model.transcript(for: id("a")), "the first open was the one retry for this session")
        let audio = await cache.cachedEntries()
        XCTAssertNotNil(audio[id("a")])

        let nextSession = makeModel(cache: cache)
        await nextSession.prepareTranscript(entryID: id("a"))
        XCTAssertNotNil(nextSession.transcript(for: id("a")), "a new session retries once more")
    }

    func testATranscriptForAnotherRevisionIsNotUsed() async throws {
        let cache = makeCache()
        try await cacheEpisode(cache, "a", revision: "rev-a")
        try await mac.publishTranscript(try timed("a", revision: "rev-b"))
        let model = makeModel(cache: cache)

        await model.prepareTranscript(entryID: id("a"))
        XCTAssertNil(model.transcript(for: id("a")))
    }

    func testNoAudioMeansNoTranscript() async throws {
        try await mac.publishTranscript(try timed("a"))
        let model = makeModel(cache: makeCache())
        await model.prepareTranscript(entryID: id("a"))
        XCTAssertNil(model.transcript(for: id("a")))
    }

    func testRemovingFromPhoneAndRemoveAllDropTheTranscript() async throws {
        let cache = makeCache()
        try await cacheEpisode(cache, "a")
        try await cacheEpisode(cache, "b")
        try await mac.publishTranscript(try timed("a"))
        let model = makeModel(cache: cache)
        await model.prepareTranscript(entryID: id("a"))
        XCTAssertNotNil(model.transcript(for: id("a")))

        await model.removeFromPhone(entryID: id("a"))
        XCTAssertNil(model.transcript(for: id("a")))
        let gone = await cache.cachedTranscript(entryID: id("a"), revisionID: revision("rev-a"))
        XCTAssertNil(gone)

        try await mac.publishTranscript(try timed("b"))
        await model.prepareTranscript(entryID: id("b"))
        XCTAssertNotNil(model.transcript(for: id("b")))
        _ = await model.removeAllDownloadedAudio(keeping: nil)
        XCTAssertNil(model.transcript(for: id("b")))
        let none = await cache.cachedTranscript(entryID: id("b"), revisionID: revision("rev-a"))
        XCTAssertNil(none)
    }
}
