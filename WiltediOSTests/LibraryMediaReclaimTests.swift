import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Storage reclaim deletes only audio that can never play: no preparation marker, or a proof
/// whose entry was revoked under the current owner and epoch. Anything it cannot judge stays.
@MainActor
final class LibraryMediaReclaimTests: XCTestCase {
    private var scratch: URL!
    private var root: URL { scratch.appendingPathComponent("cache") }
    private let scope = LibraryAppModel.mediaLibraryScope
    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("media-reclaim-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    /// Certified audio adopted through the production path.
    @discardableResult
    private func certify(_ cache: FileMediaCache, _ entry: String, revision: String, bytes: [UInt8]) async throws -> URL {
        let input = scratch.appendingPathComponent(UUID().uuidString)
        try Data(bytes).write(to: input)
        let offer = try LibraryMediaOffer(entryID: id(entry), revisionID: RevisionID(rawValue: revision),
            contentHash: MediaHash.sha256(fileAt: input), byteCount: Int64(bytes.count), mediaType: "audio/mp4",
            preparation: .init(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))))
        return try await PreparedMediaFixture.adopt(into: cache, verifiedFile: input, for: offer, owner: "owner")
    }

    /// Canonical bytes and a transcript with no preparation marker, as a pre-certification download left them.
    @discardableResult
    static func legacy(in root: URL, _ entry: String, revision: String, bytes: [UInt8]) throws -> URL {
        let data = Data(bytes)
        let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(entry).appendingPathComponent(revision)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent(FileMediaCache.transcriptFileName))
        let file = directory.appendingPathComponent("\(name).mp3")
        try data.write(to: file)
        return file
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testMarkerlessAudioIsReclaimedWithItsTranscriptAndFolder() async throws {
        let cache = FileMediaCache(rootURL: root)
        try await cache.bindOwner(ownerToken: "owner", libraryScope: scope, held: false)
        let file = try Self.legacy(in: root, "old", revision: "rev-1", bytes: [1, 2, 3])
        let before = await cache.storedAudioByteCounts()
        XCTAssertEqual(before, [id("old"): 3], "Storage counts the stranded bytes")

        let reclaimed = await cache.reclaimUnplayableAudio(keeping: [])
        XCTAssertEqual(reclaimed, [id("old")])
        XCTAssertFalse(exists(root.appendingPathComponent("old")), "audio, transcript and folders all go")
        XCTAssertFalse(exists(file))
        let after = await cache.storedAudioByteCounts()
        XCTAssertTrue(after.isEmpty)
    }

    func testRevokedAudioIsReclaimedAndCertifiedAudioKept() async throws {
        let cache = FileMediaCache(rootURL: root)
        let gone = try await certify(cache, "gone", revision: "rev-1", bytes: [1, 2])
        let kept = try await certify(cache, "kept", revision: "rev-1", bytes: [3, 4])
        try await cache.revokePreparation(entryID: id("gone"))

        let reclaimed = await cache.reclaimUnplayableAudio(keeping: [])
        XCTAssertEqual(reclaimed, [id("gone")])
        XCTAssertFalse(exists(gone))
        XCTAssertTrue(exists(kept))
        let playable = await cache.cachedEntries()
        XCTAssertEqual(Set(playable.keys), [id("kept")])
    }

    func testRevokedEntryKeepsItsNewerCertifiedRevision() async throws {
        let cache = FileMediaCache(rootURL: root)
        let old = try await certify(cache, "ep", revision: "rev-1", bytes: [1, 2])
        try await cache.revokePreparation(entryID: id("ep"))
        let new = try await certify(cache, "ep", revision: "rev-2", bytes: [3, 4])

        let reclaimed = await cache.reclaimUnplayableAudio(keeping: [])
        XCTAssertEqual(reclaimed, [id("ep")])
        XCTAssertFalse(exists(old.deletingLastPathComponent()), "only the revoked revision goes")
        XCTAssertTrue(exists(new))
        let playable = await cache.cachedEntries()
        XCTAssertEqual(playable[id("ep")]?.revisionID.rawValue, "rev-2")
    }

    func testUnconfirmedHeldOrResetBindingDeletesNothingCertified() async throws {
        let unbound = FileMediaCache(rootURL: root)
        let stranded = try Self.legacy(in: root, "old", revision: "rev-1", bytes: [9])
        let unconfirmed = await unbound.reclaimUnplayableAudio(keeping: [])
        XCTAssertTrue(unconfirmed.isEmpty, "no confirmed binding, no judgement")
        XCTAssertTrue(exists(stranded))

        let held = FileMediaCache(rootURL: root)
        try await held.bindOwner(ownerToken: "owner", libraryScope: scope, held: true)
        let whileHeld = await held.reclaimUnplayableAudio(keeping: [])
        XCTAssertTrue(whileHeld.isEmpty, "a held account deletes nothing")
        XCTAssertTrue(exists(stranded))

        let first = FileMediaCache(rootURL: root)
        let certified = try await certify(first, "ep", revision: "rev-1", bytes: [1, 2])
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(".preparation-ledger.json"))
        let reopened = FileMediaCache(rootURL: root)
        try await reopened.bindOwner(ownerToken: "owner", libraryScope: scope, held: false)
        let afterReset = await reopened.reclaimUnplayableAudio(keeping: [])
        XCTAssertEqual(afterReset, [id("old")], "a fresh epoch still clears marker-less bytes")
        XCTAssertTrue(exists(certified), "a proof from an earlier epoch is never judged revoked")
    }

    func testSparedEntriesKeepTheirAudio() async throws {
        let cache = FileMediaCache(rootURL: root)
        try await cache.bindOwner(ownerToken: "owner", libraryScope: scope, held: false)
        let busy = try Self.legacy(in: root, "busy", revision: "rev-1", bytes: [5])
        let reclaimed = await cache.reclaimUnplayableAudio(keeping: [id("busy")])
        XCTAssertTrue(reclaimed.isEmpty)
        XCTAssertTrue(exists(busy))
    }
}
