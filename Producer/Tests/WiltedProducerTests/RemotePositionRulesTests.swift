import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// The pure W-INV-006 rules behind `PlaybackController.applyRemotePosition`: when another
/// device's position is refused, and the session, sequence, intent and stamp it is stored with.
final class RemotePositionRulesTests: XCTestCase {
    private let item = try! ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
    private let revision = try! RevisionID(rawValue: "rev-a")
    private let duration: Double = 1_482
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func stored(
        position: Double, minutes: Double = 0, completed: Bool = false,
        session: String = "session-mac", sequence: Int64 = 3, intent: PlaybackIntent = .progress
    ) throws -> PlaybackState {
        try PlaybackState(
            itemID: item, revisionID: revision, sessionID: session, sequence: sequence, positionSeconds: position,
            durationSeconds: duration, completed: completed, intent: intent, deviceID: "mac-test",
            updatedAt: Timestamp(base.addingTimeInterval(minutes * 60)))
    }

    private func request(_ position: Double, minutes: Double, duration: Double = 1_482) -> RemotePositionRequest {
        RemotePositionRequest(
            itemID: item, revisionID: revision, positionSeconds: position, durationSeconds: duration,
            observedAt: base.addingTimeInterval(minutes * 60))
    }

    private func refusal(_ persisted: PlaybackState?, _ request: RemotePositionRequest) -> RemotePositionOutcome? {
        RemotePositionRules.refusal(
            persisted: persisted, positionSeconds: request.positionSeconds,
            durationSeconds: request.durationSeconds, observedAt: request.observedAt)
    }

    private func adopted(
        _ persisted: PlaybackState?, _ request: RemotePositionRequest, now: Date? = nil
    ) throws -> PlaybackState {
        try RemotePositionRules.state(
            persisted: persisted, request: request, deviceID: "phone-test",
            now: now ?? base.addingTimeInterval(3_600), newSessionID: { "session-new" })
    }

    func testACompletedEpisodeIsNeverResurrectedByAPosition() throws {
        let finished = try stored(position: 1_482, completed: true)
        XCTAssertEqual(refusal(finished, request(300, minutes: 10)), .completed)
    }

    func testARecordNotNewerThanTheStoredOneIsRefusedEvenWhenFurtherAlong() throws {
        let persisted = try stored(position: 100, minutes: 10)
        XCTAssertEqual(refusal(persisted, request(900, minutes: 10)), .notNewer)
        XCTAssertEqual(refusal(persisted, request(900, minutes: 5)), .notNewer)
    }

    func testUnusablePositionsAreRefusedAndAUsableNewerOneIsNot() throws {
        let persisted = try stored(position: 100)
        for position in [0, -5, .nan, .infinity, duration - 0.5, duration] {
            XCTAssertEqual(refusal(persisted, request(position, minutes: 10)), .unusable, "position \(position)")
        }
        XCTAssertEqual(refusal(persisted, request(300, minutes: 10, duration: 0)), .unusable)
        XCTAssertNil(refusal(persisted, request(300, minutes: 10)))
        XCTAssertNil(refusal(nil, request(300, minutes: 10)))
    }

    func testANewerBackwardMoveIsAnIntentionalRewindInANewSession() throws {
        let persisted = try stored(position: 900)
        let state = try adopted(persisted, request(120, minutes: 10, duration: 2_000))
        XCTAssertEqual(state.sessionID, "session-new")
        XCTAssertEqual(state.sequence, 1)
        XCTAssertEqual(state.intent, .rewind)
        XCTAssertFalse(state.completed)
        XCTAssertEqual(state.positionSeconds, 120)
        XCTAssertEqual(state.durationSeconds, duration, "the stored duration wins over the request's")
        XCTAssertEqual(state.deviceID, "phone-test")
    }

    func testAMoveWithinTheRewindToleranceKeepsTheSession() throws {
        let persisted = try stored(position: 900)
        let state = try adopted(persisted, request(900 - RemotePositionRules.rewindTolerance, minutes: 10))
        XCTAssertEqual(state.sessionID, "session-mac")
        XCTAssertEqual(state.sequence, 4)
        XCTAssertEqual(state.intent, .progress)
    }

    func testAForwardMoveAfterARewindKeepsTheRewindSessionAndIntent() throws {
        let rewound = try stored(position: 120, session: "session-rewind", sequence: 2, intent: .rewind)
        let state = try adopted(rewound, request(240, minutes: 10))
        XCTAssertEqual(state.sessionID, "session-rewind")
        XCTAssertEqual(state.sequence, 3)
        XCTAssertEqual(state.intent, .rewind)
        XCTAssertEqual(state.positionSeconds, 240)
    }

    func testAForwardMoveKeepsOrdinaryProgressAndRestartIntent() throws {
        let progress = try adopted(try stored(position: 100), request(300, minutes: 10))
        XCTAssertEqual(progress.sessionID, "session-mac")
        XCTAssertEqual(progress.sequence, 4)
        XCTAssertEqual(progress.intent, .progress)

        let restarted = try stored(position: 10, session: "session-restart", sequence: 1, intent: .restart)
        let state = try adopted(restarted, request(60, minutes: 10))
        XCTAssertEqual(state.sessionID, "session-restart")
        XCTAssertEqual(state.sequence, 2)
        XCTAssertEqual(state.intent, .restart)
    }

    func testAnEpisodeWithNothingStoredStartsAProgressSession() throws {
        let state = try adopted(nil, request(75, minutes: 1, duration: 2_000))
        XCTAssertEqual(state.sessionID, "session-new")
        XCTAssertEqual(state.sequence, 1)
        XCTAssertEqual(state.intent, .progress)
        XCTAssertFalse(state.completed)
        XCTAssertEqual(state.durationSeconds, 2_000)
    }

    func testTheAdoptedStateIsStampedWithTheSaveTimeButNeverLaterThanNow() throws {
        let persisted = try stored(position: 100)
        let saved = request(300, minutes: 10)
        XCTAssertEqual(try adopted(persisted, saved).updatedAt.date, saved.observedAt)

        let now = base.addingTimeInterval(5 * 60)
        XCTAssertEqual(try adopted(persisted, saved, now: now).updatedAt.date, now)
    }
}
