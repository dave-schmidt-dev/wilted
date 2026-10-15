import Foundation
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer

/// Shared by the command tests and their visual-system counterparts.
extension XCTestCase {
    @MainActor
    func makePlaybackCommandModel(prepared: Bool = true) -> (WiltedMacModel, WiltedMacScriptedBackend, WiltedMacEpisode) {
        var arguments = ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"]
        if prepared { arguments.append("--wilted-ui-fixture-prepared") }
        let model = WiltedMacModel(
            arguments: arguments,
            stateDirectoryOverride: wiltedTemporaryDirectory("playback-commands"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let backend = WiltedMacScriptedBackend()
        model.installPlaybackBackendForTesting(backend)
        return (model, backend, model.episodes[0])
    }

    /// Loads the fixture episode through the owner, then pauses it.
    @MainActor
    func loadPausedThroughOwner(_ model: WiltedMacModel, _ episode: WiltedMacEpisode) async {
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playback?.itemID?.rawValue, episode.id)
    }
}

/// A backend whose start can be refused and whose rebuild can fail.
@MainActor
final class WiltedMacScriptedBackend: PlaybackBackend {
    var duration: TimeInterval = 600
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    var rate: Float = 1
    var volume: Float = 0
    private(set) var loadedGeneration: UInt64 = 0
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
    var refusesPlay = false
    var failNextLoads = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var loadCount = 0
    /// Runs inside `load(url:)`, i.e. while a selection is mid-flight.
    var onLoad: (() -> Void)?
    /// Runs inside `play()`, i.e. at the moment a start reaches the backend.
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?

    func load(url: URL) throws {
        if failNextLoads > 0 {
            failNextLoads -= 1
            throw CocoaError(.fileReadCorruptFile)
        }
        loadCount += 1
        loadedGeneration += 1
        currentTime = 0
        isPlaying = false
        onLoad?()
    }

    func play() -> Bool {
        playCount += 1
        onPlay?()
        isPlaying = !refusesPlay
        return isPlaying
    }

    func pause() { pauseCount += 1; isPlaying = false; onPause?() }
    func stop() { isPlaying = false }

    func finish(successfully: Bool) {
        isPlaying = false
        completionHandler?(loadedGeneration, successfully)
    }

    func resetCounts() { playCount = 0; pauseCount = 0; loadCount = 0 }
}

/// Holds the first command it is armed for until released.
@MainActor
final class WiltedMacCommandGate {
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var didHold = false

    func arm() {
        armed = true
        didHold = false
    }

    func hold(_ command: WiltedMacPlaybackCommand) async {
        guard armed else { return }
        armed = false
        didHold = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { held = $0 }
    }

    func waitUntilHeld() async {
        guard !didHold else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
