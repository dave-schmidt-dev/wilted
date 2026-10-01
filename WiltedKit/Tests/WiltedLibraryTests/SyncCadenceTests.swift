import Foundation
import XCTest
@testable import WiltedLibrary

/// The intervals are the request budget. A change to any of them is a decision about how hard the
/// app hits CloudKit, so each is pinned here and must be changed on purpose.
final class SyncCadenceTests: XCTestCase {
    func testEveryDeviceHasOneThirtySecondTick() {
        XCTAssertEqual(SyncCadence.tickInterval, 30)
        // Everything periodic is the tick or a multiple of it; nothing is faster.
        XCTAssertEqual(SyncCadence.pollInterval, SyncCadence.tickInterval)
        XCTAssertEqual(SyncCadence.playingPublishInterval, SyncCadence.tickInterval)
        XCTAssertEqual(SyncCadence.phoneObserveInterval, SyncCadence.tickInterval)
        XCTAssertEqual(SyncCadence.phoneStateEveryRounds, 10)
        XCTAssertEqual(SyncCadence.rediscoverEveryCyclesWithPeers, 40)
    }

    func testTheSteadyStateIntervalsAreThirtySecondsOrLonger() {
        XCTAssertEqual(SyncCadence.pollInterval, 30)
        XCTAssertEqual(SyncCadence.playingPublishInterval, 30)
        XCTAssertEqual(SyncCadence.phoneObserveInterval, 30)
        XCTAssertEqual(SyncCadence.storedPositionRefreshInterval, 60)
        XCTAssertEqual(SyncCadence.rediscoverEveryCycles, 4)
    }

    func testAPlayingRecordIsDeadOnlyAfterThreePublishCadences() {
        XCTAssertEqual(SyncCadence.staleAfter, 90)
        XCTAssertEqual(HandoffResolver.staleAfter, SyncCadence.staleAfter)
        XCTAssertGreaterThan(SyncCadence.staleAfter, SyncCadence.playingPublishInterval * 2)
    }

    func testAdvancingAPlayingPositionIsBoundedByOneAndAHalfCadences() {
        XCTAssertEqual(SyncCadence.maxPlayingAdvance, 45)
        XCTAssertLessThan(SyncCadence.maxPlayingAdvance, SyncCadence.staleAfter)
    }

    func testTheCoordinatorPublishesOnTheCadence() {
        XCTAssertEqual(HandoffCoordinator.Configuration().publishInterval, SyncCadence.playingPublishInterval)
        XCTAssertEqual(HandoffCoordinator.Configuration().settleDelay, SyncCadence.takeoverSettleDelay)
    }

    func testEdgeAndBackoffConstants() {
        XCTAssertEqual(SyncCadence.playPressFetchTimeout, 2)
        XCTAssertEqual(SyncCadence.macTickInterval, 2)
        XCTAssertEqual(SyncCadence.backoffBase, 5)
        XCTAssertEqual(SyncCadence.backoffCap, 300)
    }
}
