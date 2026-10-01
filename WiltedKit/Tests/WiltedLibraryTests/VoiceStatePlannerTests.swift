import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// `timeLeft`, `setSpeed` and `sleepTimer`; rows are in docs/siri-voice-commands.md.
final class VoiceStatePlannerTests: XCTestCase {
    private let id = try! ItemID(rawValue: "item-1")

    private func snapshot(
        position: TimeInterval = 0, duration: TimeInterval = 3_600, rate: Double = 1, playing: Bool = true
    ) -> VoiceSnapshot {
        let episode = VoiceEpisode(id: id, title: "Tide Pools", showTitle: "Short Wave")
        return VoiceSnapshot(
            downloaded: [episode], knownShowTitles: ["Short Wave"],
            nowPlaying: VoiceNowPlaying(
                episode: episode, isPlaying: playing, canMarkCompleted: false,
                position: position, duration: duration, rate: rate))
    }

    private let empty = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)

    private func plan(_ command: VoiceCommand, _ snap: VoiceSnapshot) -> VoicePlan {
        VoiceCommandPlanner.plan(command, snapshot: snap)
    }

    // MARK: timeLeft

    func testTimeLeftNothingLoaded() {
        let result = plan(.timeLeft, empty)
        XCTAssertEqual(result, VoicePlan(action: .none, dialog: "Nothing is playing."))
    }

    func testTimeLeftIsRemainingMinutesRounded() {
        XCTAssertEqual(plan(.timeLeft, snapshot(position: 3_600 - 12 * 60)).dialog, "About 12 minutes left.")
        XCTAssertEqual(plan(.timeLeft, snapshot(position: 7_200 - 65 * 60, duration: 7_200)).dialog, "About 1 hour 5 minutes left.")
        XCTAssertEqual(plan(.timeLeft, snapshot(position: 0, duration: 7_200)).dialog, "About 2 hours left.")
        XCTAssertEqual(plan(.timeLeft, snapshot(position: 3_540)).dialog, "About 1 minute left.")
    }

    func testTimeLeftFollowsTheSpeedAndStaysCorrectWhilePaused() {
        let fast = plan(.timeLeft, snapshot(position: 3_600 - 30 * 60, rate: 1.5, playing: false))
        XCTAssertEqual(fast.dialog, "About 20 minutes left.")
        XCTAssertEqual(fast.action, .none)
    }

    func testTimeLeftUnderHalfAMinuteAndFinishedAndUnknown() {
        XCTAssertEqual(plan(.timeLeft, snapshot(position: 3_590)).dialog, "Less than a minute left.")
        XCTAssertEqual(plan(.timeLeft, snapshot(position: 3_600)).dialog, "Tide Pools has finished.")
        XCTAssertEqual(plan(.timeLeft, snapshot(duration: 0)).dialog, "I can't tell how long is left.")
    }

    // MARK: setSpeed

    func testSetSpeedEverySupportedRate() {
        for rate in VoiceCommandPlanner.supportedSpeeds {
            XCTAssertEqual(plan(.setSpeed(rate), snapshot()).action, .setSpeed(rate))
        }
    }

    func testSetSpeedDialogNamesTheRateAndWhetherSomethingPlays() {
        XCTAssertEqual(plan(.setSpeed(1.5), snapshot()).dialog, "Speed set to 1.5 times.")
        XCTAssertEqual(plan(.setSpeed(0.75), snapshot()).dialog, "Speed set to 0.75 times.")
        XCTAssertEqual(plan(.setSpeed(2), snapshot()).dialog, "Speed set to 2 times.")
        XCTAssertEqual(plan(.setSpeed(1), snapshot()).dialog, "Speed set to normal.")
        XCTAssertEqual(plan(.setSpeed(1.25), empty).dialog, "Default speed set to 1.25 times.")
        XCTAssertEqual(plan(.setSpeed(1.25), empty).action, .setSpeed(1.25))
    }

    func testSetSpeedRefusesARateThePlayerDoesNotOffer() {
        for rate in [0.5, 1.1, 3, .nan] {
            XCTAssertEqual(plan(.setSpeed(rate), snapshot()), VoicePlan(action: .none, dialog: "That speed isn't available."))
        }
    }

    // MARK: sleepTimer

    func testSleepTimerStartsWhileSomethingIsLoaded() {
        let result = plan(.sleepTimer(.minutes(30)), snapshot())
        XCTAssertEqual(result, VoicePlan(action: .startSleepTimer(minutes: 30), dialog: "Sleep timer set for 30 minutes."))
        XCTAssertEqual(plan(.sleepTimer(.minutes(1)), snapshot()).dialog, "Sleep timer set for 1 minute.")
        XCTAssertEqual(plan(.sleepTimer(.minutes(90)), snapshot(playing: false)).dialog, "Sleep timer set for 1 hour 30 minutes.")
    }

    func testSleepTimerEndOfEpisode() {
        XCTAssertEqual(
            plan(.sleepTimer(.endOfEpisode), snapshot()),
            VoicePlan(action: .stopAfterEpisode, dialog: "Sleep timer set for the end of this episode."))
        XCTAssertEqual(plan(.sleepTimer(.endOfEpisode), empty).dialog, "Nothing is playing.")
        XCTAssertEqual(plan(.sleepTimer(.endOfEpisode), snapshot(position: 3_600)).dialog, "Tide Pools has finished.")
        XCTAssertEqual(plan(.sleepTimer(.endOfEpisode), snapshot(duration: 0)).action, .stopAfterEpisode, "unknown length still stops at the end")
    }

    func testSleepTimerNeedsAnEpisode() {
        XCTAssertEqual(plan(.sleepTimer(.minutes(30)), empty), VoicePlan(action: .none, dialog: "Nothing is playing."))
    }

    func testSleepTimerOffAlwaysCancels() {
        let expected = VoicePlan(action: .cancelSleepTimer, dialog: "Sleep timer is off.")
        XCTAssertEqual(plan(.sleepTimer(.off), snapshot()), expected)
        XCTAssertEqual(plan(.sleepTimer(.off), empty), expected)
    }

    func testSleepTimerRefusesOutOfRangeMinutes() {
        for minutes in [0, -5, VoiceCommandPlanner.maxSleepMinutes + 1] {
            XCTAssertEqual(plan(.sleepTimer(.minutes(minutes)), snapshot()).action, .none)
        }
        XCTAssertEqual(plan(.sleepTimer(.minutes(VoiceCommandPlanner.maxSleepMinutes)), snapshot()).action, .startSleepTimer(minutes: 720))
    }
}
