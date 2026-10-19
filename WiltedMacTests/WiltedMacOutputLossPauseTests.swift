import Foundation
import XCTest
@testable import WiltedMac
import WiltedProducer

@MainActor
private final class OutputLossMacRoute: MacAudioRouteSource {
    var route: MacAudioRoute? = MacAudioRoute(device: 10)
    var changed: (@MainActor () -> Void)?
    func start(changed: @escaping @MainActor () -> Void) -> Bool {
        self.changed = changed
        return true
    }
    func currentRoute() -> MacAudioRoute? { route }
    func stop() { changed = nil }
}

/// Speakers or headphones going away pauses playback and refreshes the
/// readout, without raising the route fault the Recover control answers.
@MainActor
final class WiltedMacOutputLossPauseTests: XCTestCase {
    func testOutputDropPausesAndRefreshesTheReadoutWithoutARouteFault() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("output-loss-pause"))
        let model = library.model
        let (backend, _) = library.installScriptedPlayback(on: model)
        let route = OutputLossMacRoute()
        model.playback?.enableOutputLossPause(source: route)
        model.playEpisode(library.episodes[0])
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.isPlaying)
        XCTAssertNotNil(route.changed, "playing registers the output listener")

        route.route = nil
        route.changed?()

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isPlaying, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isPlaying, "the output-loss callback refreshes the readout")
        XCTAssertFalse(backend.isPlaying)
        XCTAssertFalse(model.audioRouteFault)
        XCTAssertNil(model.playbackError)
        XCTAssertNil(route.changed, "a paused player keeps no output listener")
        await model.close()
    }
}
