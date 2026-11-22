import AVFoundation
import XCTest
@testable import WiltedProducer

@MainActor
final class BulletinSpeechGainTests: XCTestCase {
    func testGainNeverExceedsPlaybackVolume() {
        for playbackVolume: Float in [0, 0.05, 0.25, 0.5, 0.75, 1] {
            let speechVolume = BulletinSpeechGain.volume(forPlaybackVolume: playbackVolume)
            XCTAssertGreaterThanOrEqual(speechVolume, 0)
            XCTAssertLessThanOrEqual(speechVolume, playbackVolume)
            XCTAssertEqual(speechVolume, playbackVolume * BulletinSpeechGain.playbackAttenuation)
            if playbackVolume > 0 {
                XCTAssertLessThan(speechVolume, playbackVolume)
            }
        }
    }

    func testSystemSpeakerAppliesGainAndFollowsPlaybackVolume() {
        var utterances: [AVSpeechUtterance] = []
        let speaker = SystemBulletinSpeaker { utterances.append($0) }

        XCTAssertTrue(speaker.speak("First headline.", playbackVolume: 0.8, finished: {}))
        XCTAssertEqual(utterances.last?.volume, BulletinSpeechGain.volume(forPlaybackVolume: 0.8))

        XCTAssertTrue(speaker.speak("Second headline.", playbackVolume: 0.3, finished: {}))
        XCTAssertEqual(utterances.last?.volume, BulletinSpeechGain.volume(forPlaybackVolume: 0.3))
        XCTAssertEqual(utterances.count, 2)
        guard utterances.count == 2 else { return }
        XCTAssertLessThan(utterances[1].volume, utterances[0].volume)
    }
}
