import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

#if canImport(WiltedProducer)
@MainActor
final class WiltedFixturePlaybackBackend: PlaybackBackend {
    var duration: TimeInterval = 120
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var rate: Float = 1
    var volume: Float = 1
    var failNextLoad = false
    private(set) var loadedGeneration: UInt64 = 0
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
    func load(url: URL) throws {
        if failNextLoad {
            failNextLoad = false
            throw CocoaError(.fileReadCorruptFile)
        }
        loadedGeneration += 1
        isPlaying = false
        duration = url.lastPathComponent.contains("podcast") ? 1_482 : 120
    }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    func finish(successfully: Bool) {
        isPlaying = false
        completionHandler?(loadedGeneration, successfully)
    }
}

/// The real audio backend with its output pinned to silence.
///
/// A test that plays an episode plays it out of the machine's speakers: a tone
/// during a gate run with nothing on screen to say where it came from. The
/// scripted fixture backend above is not a substitute, because it invents its
/// duration from the file name and the tests that play do so to assert on real
/// durations and on completion firing off the audio clock. So the real backend
/// does the work and only its output is taken away.
///
/// The mute is applied twice on purpose. `AVAudioPlayerBackend.load` copies its
/// own stored volume onto each new player, so the inner backend has to start at
/// zero; and the model pushes the owner's saved volume through
/// `PlaybackController.setVolume` on every load, so the setter here is answered
/// rather than obeyed.
@MainActor
final class WiltedSilentPlaybackBackend: PlaybackBackend {
    private let inner = AVAudioPlayerBackend()

    init() { inner.volume = 0 }

    var duration: TimeInterval { inner.duration }
    var currentTime: TimeInterval {
        get { inner.currentTime }
        set { inner.currentTime = newValue }
    }
    var isPlaying: Bool { inner.isPlaying }
    var rate: Float {
        get { inner.rate }
        set { inner.rate = newValue }
    }
    var volume: Float {
        get { inner.volume }
        set { _ = newValue }
    }
    var loadedGeneration: UInt64 { inner.loadedGeneration }
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)? {
        get { inner.completionHandler }
        set { inner.completionHandler = newValue }
    }

    func load(url: URL) throws { try inner.load(url: url) }
    @discardableResult func play() -> Bool { inner.play() }
    func pause() { inner.pause() }
    func stop() { inner.stop() }
}

/// Feeds the real download coordinator scripted bytes so
/// `--wilted-ui-fixture-download-failure` exercises production code instead
/// of a separate in-memory simulation. Failing `failuresRemaining` times
/// before succeeding reproduces what the deleted branch did by hand.
final class WiltedFixturePodcastDownloadTransport: PodcastDownloadTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresRemaining: Int

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        lock.lock()
        let shouldFail = failuresRemaining > 0
        if shouldFail { failuresRemaining -= 1 }
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(PodcastDownloadHTTPResponse(
                url: url, statusCode: 200, mediaType: "audio/mpeg", expectedByteCount: nil
            )))
            if shouldFail {
                continuation.finish(throwing: PodcastDownloadCoordinatorError.transport("fixture"))
                return
            }
            continuation.yield(.data(Data([0, 1, 2, 3, 4, 5])))
            continuation.finish()
        }
    }
}

struct WiltedFixturePodcastMediaValidator: PodcastMediaValidating {
    func duration(of url: URL, onStatus: @escaping @Sendable (String) -> Void) async throws -> Double {
        onStatus("stage=fixture-validation")
        return 1_482
    }
}
#endif
