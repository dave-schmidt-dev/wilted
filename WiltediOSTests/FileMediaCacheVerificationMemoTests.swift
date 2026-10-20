import Darwin
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Counts full-file byte checks through `FileMediaCache`'s `byteVerifier` seam. While failing,
/// every check is refused without reading the file.
actor HashCounter {
    private(set) var calls = 0
    private var failing = false

    func setFailing(_ value: Bool) { failing = value }

    func check(_ url: URL, byteCount: Int64, contentHash: String) async -> Bool {
        calls += 1
        guard !failing else { return false }
        return await MediaFetcher.verifies(url, byteCount: byteCount, contentHash: contentHash)
    }

    nonisolated var verifier: @Sendable (URL, Int64, String) async -> Bool {
        { await self.check($0, byteCount: $1, contentHash: $2) }
    }
}

/// The cache's verification memo (W-INV-040): an unchanged file verified once in this process is
/// not hashed again, and any change, failure, removal or replacement makes it verify again.
final class FileMediaCacheVerificationMemoTests: XCTestCase {
    private let entryID = try! ItemID(rawValue: "memo-entry")
    private let bytes = Data([1, 2, 3, 4, 5, 6, 7, 8])
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("memo-ios-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private struct Rig {
        let cache: FileMediaCache
        let counter: HashCounter
        let offer: LibraryMediaOffer
        let cached: CachedMedia
        /// The resolved path the memo is keyed by.
        let path: String
    }

    private func incomingFile() throws -> URL {
        let url = scratch.appendingPathComponent("incoming-\(UUID())")
        try bytes.write(to: url)
        return url
    }

    /// A real cache holding one certified, owner-bound file. Adoption hashes the incoming copy.
    private func makeRig() async throws -> Rig {
        let counter = HashCounter()
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"), byteVerifier: counter.verifier)
        let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: entryID, revisionID: RevisionID(rawValue: "rev-1"), contentHash: PreparedMediaFixture.hash(bytes),
            byteCount: Int64(bytes.count), mediaType: "audio/mp4", durationSeconds: 600))
        _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: incomingFile(), for: offer, owner: "owner")
        let entries = await cache.cachedEntries()
        let cached = try XCTUnwrap(entries[entryID])
        let path = try XCTUnwrap(cached.fileIdentity()).path
        return Rig(cache: cache, counter: counter, offer: offer, cached: cached, path: path)
    }

    /// Verifies `cached` (the rig's file by default) and reports how many hashes that took.
    private func verify(_ rig: Rig, _ cached: CachedMedia? = nil) async -> (passed: Bool, hashes: Int) {
        let before = await rig.counter.calls
        let passed = await rig.cache.verifies(cached ?? rig.cached)
        let after = await rig.counter.calls
        return (passed, after - before)
    }

    private func remembered(_ rig: Rig) async -> Bool { await rig.cache.remembersVerification(atPath: rig.path) }

    func testUnchangedFileIsHashedOnceThenAdmittedWithoutHashing() async throws {
        let rig = try await makeRig()
        let seeded = await remembered(rig)
        XCTAssertFalse(seeded, "adoption hashes the incoming copy but never seeds the memo for the file it replaced")
        let first = await verify(rig)
        XCTAssertTrue(first.passed)
        XCTAssertEqual(first.hashes, 1, "the first check in this process hashes the whole file")
        for _ in 0..<3 {
            let again = await verify(rig)
            XCTAssertTrue(again.passed)
            XCTAssertEqual(again.hashes, 0, "an unchanged file verified in this process is not hashed again")
        }
    }

    func testChangedModificationDateIsHashedAgainBeforeItIsAdmitted() async throws {
        let rig = try await makeRig()
        _ = await verify(rig)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                              ofItemAtPath: rig.cached.url.path)
        let changed = await verify(rig)
        XCTAssertTrue(changed.passed, "intact bytes still pass")
        XCTAssertEqual(changed.hashes, 1, "a changed modification date hashes the file again")
        let settled = await verify(rig)
        XCTAssertEqual(settled.hashes, 0, "the new identity is remembered once it passed")
    }

    func testChangedSizeIsRefusedThenHashedAgainWhenRestored() async throws {
        let rig = try await makeRig()
        _ = await verify(rig)
        let handle = try FileHandle(forWritingTo: rig.cached.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([9]))
        let grown = await verify(rig)
        XCTAssertFalse(grown.passed, "a file whose size no longer matches its proof never plays")
        let keptGrown = await remembered(rig)
        XCTAssertFalse(keptGrown, "a refusal forgets the file")
        try handle.truncate(atOffset: UInt64(bytes.count))
        try handle.close()
        let restored = await verify(rig)
        XCTAssertTrue(restored.passed)
        XCTAssertEqual(restored.hashes, 1, "the restored file is hashed again before it is admitted")
    }

    func testSameSizeRewriteWithRestoredTimesIsHashedAgainAndRefused() async throws {
        let rig = try await makeRig()
        _ = await verify(rig)
        let before = try XCTUnwrap(rig.cached.fileIdentity())
        var status = stat()
        XCTAssertEqual(lstat(rig.cached.url.path, &status), 0)
        let handle = try FileHandle(forWritingTo: rig.cached.url)
        try handle.write(contentsOf: Data([9]))
        try handle.close()
        // Put the access and modification times back exactly, as a deliberate tamper would.
        let times = [status.st_atimespec, status.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, rig.cached.url.path, times, 0), 0)
        let after = try XCTUnwrap(rig.cached.fileIdentity())
        XCTAssertEqual(after.path, before.path)
        XCTAssertEqual(after.volume, before.volume)
        XCTAssertEqual(after.inode, before.inode)
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.modified, before.modified)
        XCTAssertNotEqual(after.statusChanged, before.statusChanged, "only the status-change time records the rewrite")
        let tampered = await verify(rig)
        XCTAssertFalse(tampered.passed, "tampered bytes never play")
        XCTAssertEqual(tampered.hashes, 1, "the changed identity is hashed again rather than admitted from the memo")
        let kept = await remembered(rig)
        XCTAssertFalse(kept)
        let retried = await verify(rig)
        XCTAssertFalse(retried.passed)
        XCTAssertEqual(retried.hashes, 1, "a refusal is never remembered")
    }

    func testFailedVerificationIsNeverRemembered() async throws {
        let rig = try await makeRig()
        await rig.counter.setFailing(true)
        for _ in 0..<2 {
            let refused = await verify(rig)
            XCTAssertFalse(refused.passed)
            XCTAssertEqual(refused.hashes, 1, "every attempt after a failure hashes again")
        }
        let kept = await remembered(rig)
        XCTAssertFalse(kept)
        await rig.counter.setFailing(false)
        let passed = await verify(rig)
        XCTAssertTrue(passed.passed)
        XCTAssertEqual(passed.hashes, 1)
        let memoized = await verify(rig)
        XCTAssertEqual(memoized.hashes, 0)
    }

    func testRemovalThroughTheCacheForgetsTheVerification() async throws {
        let rig = try await makeRig()
        _ = await verify(rig)
        let before = await remembered(rig)
        XCTAssertTrue(before)
        try await rig.cache.remove(entryID: entryID)
        let after = await remembered(rig)
        XCTAssertFalse(after)
    }

    func testReplacementThroughTheCacheForgetsTheVerificationAndHashesTheNewFile() async throws {
        let rig = try await makeRig()
        _ = await verify(rig)
        // Without its proof the file is no longer cached, so a new delivery replaces it in place.
        let marker = await rig.cache.markerURL(rig.cached.url)
        try FileManager.default.removeItem(at: marker)
        let outside = await remembered(rig)
        XCTAssertTrue(outside, "a change made outside the cache is caught by the proof and identity checks instead")
        let replaced = try await PreparedMediaFixture.adopt(into: rig.cache, verifiedFile: incomingFile(),
                                                            for: rig.offer, owner: "owner")
        XCTAssertEqual(replaced.standardizedFileURL, rig.cached.url.standardizedFileURL)
        let forgotten = await remembered(rig)
        XCTAssertFalse(forgotten, "replacing the audio forgets its earlier check")
        let entries = await rig.cache.cachedEntries()
        let fresh = try XCTUnwrap(entries[entryID])
        let reverified = await verify(rig, fresh)
        XCTAssertTrue(reverified.passed)
        XCTAssertEqual(reverified.hashes, 1, "the replacement is hashed before it plays")
    }

    func testReclaimThroughTheCacheForgetsTheVerification() async throws {
        let rig = try await makeRig()
        _ = await verify(rig)
        let marker = await rig.cache.markerURL(rig.cached.url)
        try FileManager.default.removeItem(at: marker)
        let reclaimed = await rig.cache.reclaimUnplayableAudio(keeping: [])
        XCTAssertEqual(reclaimed, [entryID])
        let after = await remembered(rig)
        XCTAssertFalse(after)
    }

    func testRevocationForgetsTheVerification() async throws {
        let rig = try await makeRig()
        _ = await verify(rig)
        try await rig.cache.revokePreparation(entryID: entryID)
        let after = await remembered(rig)
        XCTAssertFalse(after)
        let revoked = await verify(rig)
        XCTAssertFalse(revoked.passed, "a revoked proof never plays, memo or not")
    }

    func testMemoNeverRecordsAHashThatOverlappedAForget() throws {
        let file = scratch.appendingPathComponent("audio.m4a")
        try bytes.write(to: file)
        let identity = try XCTUnwrap(CachedMedia.FileIdentity(regularFileAt: file))
        let check = MediaVerificationMemo.Check(file: identity, contentHash: PreparedMediaFixture.hash(bytes),
                                                byteCount: Int64(bytes.count), generation: UUID())
        var memo = MediaVerificationMemo()
        let mark = memo.changes
        memo.forget(scratch.appendingPathComponent("elsewhere"))
        memo.record(check, ifUnchangedSince: mark)
        XCTAssertFalse(memo.admits(check), "a write that landed while the hash ran voids its result")
        memo.record(check, ifUnchangedSince: memo.changes)
        XCTAssertTrue(memo.admits(check))
        let otherGeneration = MediaVerificationMemo.Check(file: identity, contentHash: check.contentHash,
                                                          byteCount: check.byteCount, generation: UUID())
        XCTAssertFalse(memo.admits(otherGeneration), "a new cache generation verifies again")
        memo.forget(scratch)
        XCTAssertFalse(memo.admits(check), "forgetting a directory forgets every file beneath it")
    }

    func testIdentityRefusesASymbolicLink() throws {
        let file = scratch.appendingPathComponent("audio.m4a")
        try bytes.write(to: file)
        let link = scratch.appendingPathComponent("link.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNotNil(CachedMedia.FileIdentity(regularFileAt: file))
        XCTAssertNil(CachedMedia.FileIdentity(regularFileAt: link))
    }
}
