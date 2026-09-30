import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// Which durable Mac positions are handed to another device.
final class WiltedMacStoredPositionsTests: XCTestCase {
    private func id(_ letter: String) -> ItemID { try! ItemID(rawValue: "item-" + String(repeating: letter, count: 64)) }
    private let revA = try! RevisionID(rawValue: "rev-a")
    private let revB = try! RevisionID(rawValue: "rev-b")

    private func state(
        _ item: ItemID, _ revision: RevisionID, position: Double, duration: Double = 1_000, completed: Bool = false
    ) -> (String, PlaybackState) {
        let value = try! PlaybackState(
            itemID: item, revisionID: revision, sessionID: "session-x", sequence: 3, positionSeconds: position,
            durationSeconds: duration, completed: completed, intent: .progress, deviceID: "mac-test",
            updatedAt: Timestamp(Date(timeIntervalSince1970: 5_000)))
        return ("\(item.rawValue)|\(revision.rawValue)", value)
    }

    private func derive(
        queue: [ItemID], retired: Set<ItemID> = [], ready: [ItemID: RevisionID],
        states: [(String, PlaybackState)], completed: Set<ItemID> = []
    ) -> [WiltedMacStoredPositionsResult] {
        WiltedMacStoredPositions.derive(
            queue: queue, retired: retired, readyRevisions: ready,
            playbackStates: Dictionary(uniqueKeysWithValues: states), completed: completed
        ).map { WiltedMacStoredPositionsResult(entryID: $0.entryID, revision: $0.revision, position: $0.positionSeconds) }
    }

    func testStartedUnfinishedQueuedEpisodeIsPublishedAtItsReadyRevision() {
        let a = id("a")
        let result = derive(queue: [a], ready: [a: revA], states: [state(a, revA, position: 321)])
        XCTAssertEqual(result, [.init(entryID: a, revision: revA, position: 321)])
    }

    func testAPositionAdoptedFromThePhoneIsNotPublishedBackAsTheMacs() {
        let a = id("a")
        let states = [state(a, revA, position: 321)]
        func derived(adopted: [ItemID: Double]) -> [HandoffCoordinator.StoredPosition] {
            WiltedMacStoredPositions.derive(
                queue: [a], retired: [], readyRevisions: [a: revA],
                playbackStates: Dictionary(uniqueKeysWithValues: states), completed: [], adoptedPositions: adopted)
        }
        XCTAssertTrue(derived(adopted: [a: 321]).isEmpty, "unchanged since adoption: still the phone's")
        XCTAssertTrue(derived(adopted: [a: 320.7]).isEmpty, "within the tolerance")
        XCTAssertEqual(derived(adopted: [a: 100]).map(\.positionSeconds), [321], "the Mac moved it since: publish")
        XCTAssertEqual(derived(adopted: [:]).map(\.positionSeconds), [321])
    }

    func testPositionIsNeverPairedWithAnotherRevision() {
        let a = id("a")
        // Only the old revision has a checkpoint; the Mac's ready revision is the new one.
        XCTAssertTrue(derive(queue: [a], ready: [a: revB], states: [state(a, revA, position: 321)]).isEmpty)
    }

    func testNotStartedCompletedRetiredUnqueuedAndNearEndAreLeftOut() {
        let (a, b, c, d, e, f) = (id("a"), id("b"), id("c"), id("d"), id("e"), id("f"))
        let ready = [a: revA, b: revA, c: revA, d: revA, e: revA, f: revA]
        let result = derive(
            queue: [a, b, c, d, e], retired: [c], ready: ready,
            states: [
                state(a, revA, position: 0), state(b, revA, position: 400, completed: true),
                state(c, revA, position: 400), state(d, revA, position: 999.5),
                state(e, revA, position: 400), state(f, revA, position: 400),
            ],
            completed: [e])
        XCTAssertTrue(result.isEmpty, "\(result)")
    }
}

private struct WiltedMacStoredPositionsResult: Equatable {
    let entryID: ItemID
    let revision: RevisionID
    let position: Double
}
