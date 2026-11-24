import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltediOS

final class LibraryListenNextAudioCacheTests: XCTestCase {
    private let owner = "audio-cache-owner"

    func testCacheIsOfferBoundAndRequestScopedForDeletion() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("story-audio-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let firstSource = scratch.appendingPathComponent("first.m4a")
        let secondSource = scratch.appendingPathComponent("second.m4a")
        try Data([1, 2, 3, 4]).write(to: firstSource)
        try Data([5, 6, 7, 8]).write(to: secondSource)
        let firstOffer = try offer(requestID: "request-one", source: firstSource)
        let secondOffer = try offer(requestID: "request-two", source: secondSource)
        let cache = LibraryListenNextAudioCache(outboxURL: scratch.appendingPathComponent("pending.json"))

        let firstCached = try cache.store(firstSource, for: firstOffer, ownerToken: owner)
        let secondCached = try cache.store(secondSource, for: secondOffer, ownerToken: owner)
        XCTAssertEqual(firstCached, cache.url(for: firstOffer, ownerToken: owner))
        XCTAssertNotEqual(firstCached, secondCached)
        XCTAssertEqual(try MediaHash.sha256(fileAt: firstCached), firstOffer.contentHash)

        try cache.removeAudio(for: firstOffer.requestID, ownerToken: owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCached.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondCached.path))
    }

    func testCacheRejectsBytesThatDoNotMatchTheExactOffer() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("story-audio-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let source = scratch.appendingPathComponent("audio.m4a")
        try Data([1, 2, 3, 4]).write(to: source)
        let offer = try LibraryStoryAudioOffer(
            requestID: "request-wrong-hash", storyID: "story", requesterDeviceID: "phone",
            voiceID: "voice", voiceRevision: "voice-r1", audioRevision: try RevisionID(rawValue: "revision"),
            contentHash: "sha256:" + String(repeating: "0", count: 64), byteCount: 4,
            mediaType: "audio/mp4", durationSeconds: 1
        )
        let cache = LibraryListenNextAudioCache(outboxURL: scratch.appendingPathComponent("pending.json"))

        XCTAssertThrowsError(try cache.store(source, for: offer, ownerToken: owner))
        XCTAssertNil(cache.url(for: offer, ownerToken: owner).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }

    private func offer(requestID: String, source: URL) throws -> LibraryStoryAudioOffer {
        let values = try FileManager.default.attributesOfItem(atPath: source.path)
        return try LibraryStoryAudioOffer(
            requestID: requestID, storyID: "story-\(requestID)", requesterDeviceID: "phone",
            voiceID: "voice", voiceRevision: "voice-r1", audioRevision: try RevisionID(rawValue: "revision-\(requestID)"),
            contentHash: try MediaHash.sha256(fileAt: source),
            byteCount: (values[.size] as? NSNumber)?.int64Value ?? 0,
            mediaType: "audio/mp4", durationSeconds: 1
        )
    }
}
