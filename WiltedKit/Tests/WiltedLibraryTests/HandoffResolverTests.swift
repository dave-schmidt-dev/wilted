import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class HandoffResolverTests: XCTestCase {
    private let entry = try! ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
    private let revisionA = try! RevisionID(rawValue: "rev-a")
    private let revisionB = try! RevisionID(rawValue: "rev-b")

    private func observed(
        _ device: String, epoch: Int, at seconds: TimeInterval, position: Double = 100, rate: Double = 1,
        playing: Bool = true, revision: RevisionID? = nil
    ) throws -> ObservedPlayback {
        ObservedPlayback(
            record: try DevicePlaybackPosition(deviceID: device, entryID: entry, revision: revision ?? revisionA,
                                               positionSeconds: position, rate: rate, isPlaying: playing, epoch: epoch),
            serverModifiedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    func testTakeoverSetsEpochToMaxSeenPlusOne() throws {
        let seen = try [observed("mac", epoch: 3, at: 10), observed("old", epoch: 1, at: 99)].map(\.record)
        XCTAssertEqual(HandoffResolver.takeoverEpoch(seen: seen), 4)
        XCTAssertEqual(HandoffResolver.takeoverEpoch(seen: []), 1)
        let phone = try observed("phone", epoch: 4, at: 20)
        let winner = try XCTUnwrap(HandoffResolver.winner(among: [observed("mac", epoch: 3, at: 10), phone]))
        XCTAssertEqual(winner.record.deviceID, "phone")
    }

    func testRelinquishOnHigherEpochOnly() throws {
        let mac = try observed("mac", epoch: 3, at: 10)
        let phone = try observed("phone", epoch: 4, at: 20)
        XCTAssertEqual(HandoffResolver.decision(localDeviceID: "mac", localEpoch: 3, observed: [mac, phone]),
                       .relinquish(to: "phone"))
        XCTAssertEqual(HandoffResolver.decision(localDeviceID: "phone", localEpoch: 4, observed: [mac, phone]),
                       .keepPlaying)
        let lowerEpoch = try observed("phone", epoch: 2, at: 30)
        XCTAssertEqual(HandoffResolver.decision(localDeviceID: "mac", localEpoch: 3, observed: [mac, lowerEpoch]),
                       .keepPlaying)
    }

    func testSimultaneousTakeoverResolvesToExactlyOneWinner() throws {
        let mac = try observed("mac", epoch: 4, at: 10)
        let phone = try observed("phone", epoch: 4, at: 11)
        XCTAssertEqual(HandoffResolver.decision(localDeviceID: "mac", localEpoch: 4, observed: [mac, phone]),
                       .relinquish(to: "phone"))
        XCTAssertEqual(HandoffResolver.decision(localDeviceID: "phone", localEpoch: 4, observed: [mac, phone]),
                       .keepPlaying)
        let tiedMac = try observed("mac", epoch: 4, at: 10)
        let tiedPhone = try observed("phone", epoch: 4, at: 10)
        XCTAssertEqual(HandoffResolver.decision(localDeviceID: "mac", localEpoch: 4, observed: [tiedMac, tiedPhone]),
                       .relinquish(to: "phone"))
        XCTAssertEqual(HandoffResolver.decision(localDeviceID: "phone", localEpoch: 4, observed: [tiedMac, tiedPhone]),
                       .keepPlaying)
    }

    func testStaleEpochLosesDespiteNewerServerDate() throws {
        let current = try observed("phone", epoch: 4, at: 10)
        let stale = try observed("mac", epoch: 3, at: 999)
        XCTAssertFalse(HandoffResolver.supersedes(stale, over: current))
        XCTAssertTrue(HandoffResolver.supersedes(current, over: stale))
        XCTAssertTrue(HandoffResolver.isStale(stale.record, seen: [current.record]))
        XCTAssertFalse(HandoffResolver.isStale(current.record, seen: [current.record, stale.record]))
        XCTAssertEqual(HandoffResolver.winner(among: [stale, current])?.record.deviceID, "phone")
        XCTAssertNil(HandoffResolver.winner(among: []))
    }

    func testRewindInsideEpochIsLegal() throws {
        let before = try observed("mac", epoch: 3, at: 10, position: 500)
        let rewound = try observed("mac", epoch: 3, at: 20, position: 120)
        XCTAssertTrue(HandoffResolver.supersedes(rewound, over: before))
        XCTAssertEqual(HandoffResolver.winner(among: [before, rewound])?.record.positionSeconds, 120)
        XCTAssertEqual(HandoffResolver.decision(localDeviceID: "mac", localEpoch: 3, observed: [rewound]), .keepPlaying)
    }

    func testResumePositionUsesRate() throws {
        let now = Date(timeIntervalSince1970: 110)
        let fast = try observed("mac", epoch: 1, at: 100, position: 100, rate: 2)
        XCTAssertEqual(HandoffResolver.resumePosition(of: fast, now: now), 120, accuracy: 1e-9)
        let paused = try observed("mac", epoch: 1, at: 100, position: 100, rate: 2, playing: false)
        XCTAssertEqual(HandoffResolver.resumePosition(of: paused, now: now), 100)
        let skewed = HandoffResolver.resumePosition(of: fast, now: now, clockOffset: 5)
        XCTAssertEqual(skewed, 130, accuracy: 1e-9)
        XCTAssertEqual(HandoffResolver.resumePosition(of: fast, now: Date(timeIntervalSince1970: 50)), 100)
        XCTAssertEqual(HandoffResolver.resumePosition(of: fast, now: now, durationSeconds: 110), 110)
    }

    func testRecordValidationAndCodableRoundTrip() throws {
        let record = try observed("mac", epoch: 2, at: 1).record
        XCTAssertEqual(try JSONDecoder().decode(NowPlayingRecord.self, from: JSONEncoder().encode(record)), record)
        XCTAssertThrowsError(try DevicePlaybackPosition(deviceID: "d", entryID: entry, revision: revisionA,
                                                        positionSeconds: 0, rate: 0, isPlaying: true, epoch: 0))
        XCTAssertThrowsError(try DevicePlaybackPosition(deviceID: "d", entryID: entry, revision: revisionA,
                                                        positionSeconds: -1, isPlaying: true, epoch: 0))
    }

    func testCompletionLastWriterWinsAcrossDifferingRevisions() throws {
        // Two devices hold different audio revisions of the same item; completion is item-scoped.
        _ = try observed("mac", epoch: 1, at: 1, revision: revisionA)
        _ = try observed("phone", epoch: 1, at: 2, revision: revisionB)
        let done = ListeningRecord(itemID: entry, completedAt: Date(timeIntervalSince1970: 10),
                                   updatedAt: Date(timeIntervalSince1970: 10), deviceID: "mac")
        let unplayed = ListeningRecord(itemID: entry, completedAt: nil,
                                       updatedAt: Date(timeIntervalSince1970: 20), deviceID: "phone")
        XCTAssertEqual(try ListeningRecord.merge(done, unplayed), unplayed)
        XCTAssertEqual(try ListeningRecord.merge(unplayed, done), unplayed)
        let redone = ListeningRecord(itemID: entry, completedAt: Date(timeIntervalSince1970: 30),
                                     updatedAt: Date(timeIntervalSince1970: 30), deviceID: "mac")
        XCTAssertTrue(try ListeningRecord.merge(unplayed, redone).isCompleted)
        let tieA = ListeningRecord(itemID: entry, completedAt: nil, updatedAt: Date(timeIntervalSince1970: 5), deviceID: "a")
        let tieB = ListeningRecord(itemID: entry, completedAt: Date(timeIntervalSince1970: 5),
                                   updatedAt: Date(timeIntervalSince1970: 5), deviceID: "b")
        XCTAssertEqual(try ListeningRecord.merge(tieA, tieB), try ListeningRecord.merge(tieB, tieA))
    }
}
