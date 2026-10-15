import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

struct AssociationFixture {
    let a = try! ItemID(rawValue: "episode-a")
    let b = try! ItemID(rawValue: "episode-b")
    let feed = try! ItemID(rawValue: "feed")
    let revisionA = try! RevisionID(rawValue: "revision-a")
    let revisionB = try! RevisionID(rawValue: "revision-b")
    let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let now = Date(timeIntervalSince1970: 1_000)

    func association(version: Int = 1, members: [ItemID]? = nil,
                     choice: LibraryEpisodeAssociation.ManualChoice? = .keep,
                     decidedAt: Date? = Date(timeIntervalSince1970: 900), terminal: Bool = false,
                     associationVersion: Int = 1) -> LibraryEpisodeAssociation {
        LibraryEpisodeAssociation(schemaVersion: version, groupID: groupID, representativeID: a,
            memberIDs: members ?? [a, b], associationVersion: associationVersion, isTerminal: terminal,
            latestManualChoice: choice, manualDecidedAt: decidedAt, hasConflictingManualChoices: true)
    }

    func entry(_ id: ItemID, association: LibraryEpisodeAssociation? = nil,
               sourceID: ItemID? = nil, kind: LibraryKind = .podcastEpisode) throws -> LibraryEntry {
        try LibraryEntry(id: id, kind: kind, sourceID: sourceID ?? feed, title: id.rawValue,
            summary: "", publishedAt: now, episodeAssociation: association)
    }

    func entries() throws -> [LibraryEntry] {
        try [entry(a, association: association()), entry(b, association: association())]
    }

    func offer(_ id: ItemID, revision: RevisionID, hash: String = "a", bytes: Int64 = 1_000,
               type: String = "audio/m4a", duration: Double? = 600,
               prepared: Bool = true) throws -> LibraryMediaOffer {
        try LibraryMediaOffer(entryID: id, revisionID: revision,
            contentHash: "sha256:" + String(repeating: hash, count: 64), byteCount: bytes,
            mediaType: type, durationSeconds: duration, state: .available,
            preparation: prepared ? LibraryMediaPreparation(preparedAt: Timestamp(now)) : nil)
    }

    func observed() throws -> ObservedPlayback {
        ObservedPlayback(record: try DevicePlaybackPosition(deviceID: "mac", entryID: b,
            revision: revisionB, positionSeconds: 123, rate: 1.25, isPlaying: false, epoch: 4),
            serverModifiedAt: now)
    }
}

final class LibraryEpisodeAssociationTests: XCTestCase {
    let f = AssociationFixture()

    func testOldAndNewEntryCodecsAndRemovalCopiesPreserveRawIdentity() throws {
        let raw = try f.entry(f.b)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(raw)) as? [String: Any])
        old.removeValue(forKey: "episodeAssociation")
        XCTAssertEqual(try decoder.decode(LibraryEntry.self, from: JSONSerialization.data(withJSONObject: old)), raw)
        let associated = try f.entry(f.b, association: f.association())
        XCTAssertEqual(try decoder.decode(LibraryEntry.self, from: encoder.encode(associated)), associated)
        XCTAssertEqual(try associated.with(removal: .retired).episodeAssociation, f.association())
        XCTAssertEqual(try associated.applyingRemoval(.dismissed).episodeAssociation, f.association())
        let podcast = try LibraryEntry.podcastEpisode(id: f.b, sourceID: f.feed, title: "B", summary: "",
            publishedAt: f.now, episodeAssociation: f.association(),
            payload: PodcastEpisodePayload(enclosureURL: URL(string: "https://example.org/b.m4a")!))
        XCTAssertEqual(podcast.episodeAssociation, f.association())
        XCTAssertEqual(podcast.id, f.b)
        XCTAssertEqual(podcast.sourceID, f.feed)
    }

    func testMalformedMetadataNeverPreventsRawEntryDecode() throws {
        let raw = try f.entry(f.b)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as? [String: Any])
        for malformed: Any in ["unknown", ["schemaVersion": 1], ["groupID": "bad-uuid"]] {
            object["episodeAssociation"] = malformed
            let decoded = try JSONDecoder().decode(LibraryEntry.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded, raw)
        }
    }

    func testUnsupportedAndInvalidMetadataRetainsRawRows() throws {
        let invalid = [f.association(version: 2), f.association(members: [f.b, f.a]),
                       f.association(members: [f.a, f.a]), f.association(associationVersion: 0),
                       f.association(decidedAt: nil), f.association(choice: nil),
                       f.association(choice: .skip, terminal: false)]
        for association in invalid {
            let entries = try [f.entry(f.a, association: association), f.entry(f.b, association: association)]
            let decoded = try JSONDecoder().decode([LibraryEntry].self, from: JSONEncoder().encode(entries))
            XCTAssertEqual(decoded.count, 2)
            XCTAssertTrue(LibraryEpisodeAssociation.coherentGroups(in: decoded).isEmpty)
        }
    }

    func testCompleteCoherentGroupCarriesLatestKeepOverRawTerminalState() throws {
        var entries = try f.entries()
        entries[1] = try entries[1].with(removal: .retired)
        let group = try XCTUnwrap(LibraryEpisodeAssociation.group(for: f.b, in: entries))
        XCTAssertEqual(group.representativeID, f.a)
        XCTAssertFalse(group.isTerminal)
        XCTAssertEqual(group.latestManualChoice, .keep)
        XCTAssertEqual(group.manualDecidedAt, Date(timeIntervalSince1970: 900))
        XCTAssertTrue(group.hasConflictingManualChoices)
        XCTAssertEqual(entries[1].removal, .retired)
    }

    func testGenuineCompletionAfterKeepRemainsCoherentWithOriginalManualProvenance() throws {
        let metadata = f.association(terminal: true)
        let entries = try [f.entry(f.a, association: metadata), f.entry(f.b, association: metadata)]
        let decoded = try JSONDecoder().decode([LibraryEntry].self, from: JSONEncoder().encode(entries))
        let group = try XCTUnwrap(LibraryEpisodeAssociation.group(for: f.b, in: decoded))
        XCTAssertTrue(group.isSupported)
        XCTAssertTrue(group.isTerminal)
        XCTAssertEqual(group.latestManualChoice, .keep)
        XCTAssertEqual(group.manualDecidedAt, Date(timeIntervalSince1970: 900))
        XCTAssertEqual(group, metadata)
        XCTAssertEqual(decoded.map(\.id), [f.a, f.b])
    }

    func testPartialInconsistentCrossFeedWrongKindAndDuplicateGroupsFallBackRaw() throws {
        let entries = try f.entries()
        let inconsistent = try f.entry(f.b, association: f.association(associationVersion: 2))
        let otherFeed = try f.entry(f.b, association: f.association(), sourceID: ItemID(rawValue: "other-feed"))
        let otherKind = try f.entry(f.b, association: f.association(), kind: .article)
        for bad in [[entries[1]], [entries[0], inconsistent], [entries[0], otherFeed],
                    [entries[0], otherKind], entries + [entries[0]], [entries[0], try f.entry(f.b)]] {
            XCTAssertTrue(LibraryEpisodeAssociation.coherentGroups(in: bad).isEmpty)
        }
    }

    func testRawBQueueSurvivesDiffCodecAndReconcileWithoutRepresentativeSlot() throws {
        let rawEntries = try [f.entry(f.a), f.entry(f.b)]
        let slot = try QueueSlot(entryID: f.b, sortKey: 7)
        let before = LibrarySnapshot(entries: rawEntries, slots: [slot])
        let after = LibrarySnapshot(entries: try f.entries(), slots: [slot])
        let changes = LibraryStateDiffer.diff(from: before, to: after)
        XCTAssertEqual(changes.count, 2)
        XCTAssertFalse(changes.contains { if case .slotRemoved = $0 { true } else { false } })
        let encoded = try JSONEncoder().encode(changes)
        let decoded = try JSONDecoder().decode([LibraryChange].self, from: encoded)
        let batch = LibraryChangeBatch(generationID: "g", changes: decoded.enumerated().map {
            VersionedLibraryChange(version: UInt64($0.offset + 1), change: $0.element)
        }, token: nil)
        var state = LibraryStoreState()
        state.content = before
        let reconciled = LibraryReconciler.reconcile(state, with: batch)
        XCTAssertEqual(reconciled.content, after)
        XCTAssertEqual(reconciled.content.queue.map(\.entryID), [f.b])
        XCTAssertNil(reconciled.content.slots[f.a])
        XCTAssertEqual(LibraryEpisodeAssociation.group(for: f.b, in: Array(reconciled.content.entries.values))?.representativeID, f.a)
        XCTAssertEqual(LibraryReconciler.reconcile(reconciled, with: batch), reconciled)
    }

    func testAssociationDoesNotCollapseAnyRawQueueSlots() throws {
        let slots = try [QueueSlot(entryID: f.b, sortKey: 0), QueueSlot(entryID: f.a, sortKey: 1)]
        let before = LibrarySnapshot(entries: try [f.entry(f.a), f.entry(f.b)], slots: slots)
        let after = LibrarySnapshot(entries: try f.entries(), slots: slots)
        let changes = LibraryStateDiffer.diff(from: before, to: after)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.reduce(before) { $0.applying($1) }, after)
        XCTAssertEqual(after.queue.map(\.entryID), [f.b, f.a])
        XCTAssertEqual(LibraryEpisodeAssociation.coherentGroups(in: Array(after.entries.values)).count, 1)
    }
}
