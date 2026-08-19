import AVFoundation
import XCTest
import WiltedListener

/// Covers the real `AVAudioSession` configuration rather than a fake.
///
/// Every other playback test injects a fake session, so the shipping activation was
/// exercised for the first time on a device, where it failed with OSStatus -50 and made
/// playback impossible. The simulator has a real audio session, so this rule belongs in
/// the ordinary gate.
final class ListenerAudioSessionTests: XCTestCase {
    func testTheShippingAudioSessionActivatesForSpokenPlayback() throws {
        let controller = AVAudioSessionController()
        addTeardownBlock { controller.deactivate() }

        XCTAssertNoThrow(try controller.activate())

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .spokenAudio)
        // AirPlay and Bluetooth A2DP are only settable with `playAndRecord`; requesting them
        // alongside `playback` is what produced the -50 on the device. They stay implicitly
        // available without the options.
        //
        // This assertion, not the one above, is what catches the defect: the simulator
        // accepts the invalid combination and retains the options, so activation succeeding
        // proves nothing on its own.
        XCTAssertFalse(session.categoryOptions.contains(.allowAirPlay))
        XCTAssertFalse(session.categoryOptions.contains(.allowBluetoothA2DP))
    }
}
