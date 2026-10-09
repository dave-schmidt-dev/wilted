import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Deliberate synthetic Mac preparation; legacy fixtures never call this helper.
enum PreparedMediaFixture {
    static func hash(_ bytes: Data) -> String {
        MediaHash.prefix + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func certified(_ offer: LibraryMediaOffer) throws -> LibraryMediaOffer {
        try LibraryMediaOffer(entryID: offer.entryID, revisionID: offer.revisionID,
            contentHash: offer.contentHash, byteCount: offer.byteCount, mediaType: offer.mediaType,
            durationSeconds: offer.durationSeconds, state: offer.state,
            preparation: LibraryMediaPreparation(preparedAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))))
    }

    static func adopt(into cache: any LibraryMediaCache, verifiedFile: URL,
                      for offer: LibraryMediaOffer, owner: String) async throws -> URL {
        let scope = await LibraryAppModel.mediaLibraryScope
        try await cache.bindOwner(ownerToken: owner, libraryScope: scope, held: false)
        let issued = await cache.admission(entryID: offer.entryID, ownerToken: owner,
            libraryScope: scope, transportGeneration: 0)
        let admission = try XCTUnwrap(issued)
        return try await cache.adopt(verifiedFile: verifiedFile, for: offer, admission: admission)
    }
    /// Commits the caller's actual library and owner before a cold model can bind its cache.
    static func bootstrap(_ store: any LibraryStore, transport: any LibraryTransport) async throws {
        let owner = await transport.verifiedOwnerToken()
        _ = try XCTUnwrap(owner)
        _ = try await LibraryReconciler(transport: transport, store: store).synchronize().get()
        let saved = await store.state()
        XCTAssertEqual(saved.ownerToken, owner)
        XCTAssertFalse(saved.reviewHold)
    }

    /// Uses the production reconciler and its verified owner/commit path, never a snapshot fake.
    static func bootstrap(_ store: any LibraryStore, cache: any LibraryMediaCache, owner: String) async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "fixture-mac")
        let writer = InMemoryLibraryTransport(deviceID: "fixture-mac", server: server, verifiedOwnerToken: owner)
        let entries = await cache.cachedEntries()
        var changes: [LibraryChange] = []
        for (offset, pair) in entries.sorted(by: { $0.key.rawValue < $1.key.rawValue }).enumerated() {
            changes.append(.entry(try LibraryEntry(id: pair.key, kind: .podcastEpisode, sourceID: pair.key,
                title: "Episode", summary: "", publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 600)))
            changes.append(.slot(try QueueSlot(entryID: pair.key, sortKey: Double(offset))))
        }
        _ = try await writer.push(changes: changes.enumerated().map {
            PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })
        let reader = InMemoryLibraryTransport(deviceID: "fixture-phone", server: server, verifiedOwnerToken: owner)
        _ = try await LibraryReconciler(transport: reader, store: store).synchronize().get()
    }

}
