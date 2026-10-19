import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer

@MainActor
private final class OutputLossRoute: MacAudioRouteSource {
    var route: MacAudioRoute? = MacAudioRoute(device: 10, source: 1, jackConnected: true)
    var unavailableDevices: Set<UInt32> = []
    var changed: (@MainActor () -> Void)?
    var starts = 0
    var stops = 0
    var canRegister = true
    var monitoringAvailable = true
    func start(changed: @escaping @MainActor () -> Void) -> Bool {
        starts += 1
        self.changed = changed
        return canRegister
    }
    func currentRoute() -> MacAudioRoute? { monitoringAvailable ? route : nil }
    func stop() { stops += 1; changed = nil }
    func isDeviceAvailable(_ device: UInt32) -> Bool { !unavailableDevices.contains(device) }
}

@MainActor
private final class OutputLossBackend: PlaybackBackend {
    var duration: TimeInterval = 42
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var rate: Float = 1
    var volume: Float = 1
    private(set) var loadedGeneration: UInt64 = 0
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    func load(url: URL) throws { loadedGeneration += 1; currentTime = 0; isPlaying = false }
    func play() -> Bool { playCount += 1; isPlaying = true; return true }
    func pause() { pauseCount += 1; isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor
final class PlaybackControllerOutputLossTests: XCTestCase {
    private struct Rig {
        let controller: PlaybackController
        let backend: OutputLossBackend
        let route: OutputLossRoute
        let store: LocalLibraryStore
        let revision: AudioRevision
        let root: URL
    }

    private func rig(name: String = #function) async throws -> Rig {
        let root = OwnedTestTemp.root
            .appendingPathComponent("wilted-output-loss-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let url = URL(string: "https://example.test/output-loss")!
        let article = try Article(itemID: ItemID.derive(from: url), canonicalURL: url,
                                  title: "Output loss", source: "example.test",
                                  createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        try await store.save(article: article)
        let revision = try AudioRevision(
            itemID: article.itemID, revisionID: RevisionID(rawValue: "revision-output-loss"),
            durationSeconds: 42, byteCount: 1,
            contentHash: "sha256:\(String(repeating: "a", count: 64))",
            mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        let backend = OutputLossBackend()
        let controller = PlaybackController(store: store, backend: backend, deviceID: "test-device")
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/output-loss.m4a"))
        return Rig(controller: controller, backend: backend, route: OutputLossRoute(), store: store,
                   revision: revision, root: root)
    }

    private func bulletin(at now: Date) throws -> Bulletin {
        try Bulletin(id: "output-loss", kind: .alert, text: "Output loss.", severity: .extreme,
                     issuedAt: now, expiresAt: now.addingTimeInterval(3600))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !condition() { XCTFail("condition was not met within 5 seconds") }
    }

    func testDecisionTable() {
        let baseline = MacAudioRoute(device: 10, source: 1, jackConnected: true)
        let unplugged = MacAudioRoute(device: 10, source: 1, jackConnected: false)
        XCTAssertEqual(
            outputLossDecision(baseline: baseline, current: unplugged, baselineDeviceAvailable: true), .lost)

        let bluetooth = MacAudioRoute(device: 10)
        let speakers = MacAudioRoute(device: 20)
        XCTAssertEqual(
            outputLossDecision(baseline: bluetooth, current: speakers, baselineDeviceAvailable: false), .lost)
        XCTAssertEqual(
            outputLossDecision(baseline: bluetooth, current: speakers, baselineDeviceAvailable: true),
            .keep(speakers))

        let plugged = MacAudioRoute(device: 10, source: 2, jackConnected: true)
        XCTAssertEqual(
            outputLossDecision(baseline: MacAudioRoute(device: 10, source: 1, jackConnected: false),
                               current: plugged, baselineDeviceAvailable: true),
            .keep(plugged))
        XCTAssertEqual(
            outputLossDecision(baseline: baseline, current: MacAudioRoute(device: 10, source: 2, jackConnected: true),
                               baselineDeviceAvailable: true),
            .keep(MacAudioRoute(device: 10, source: 2, jackConnected: true)))

        XCTAssertEqual(
            outputLossDecision(baseline: baseline, current: nil, baselineDeviceAvailable: true), .lost)
        XCTAssertEqual(
            outputLossDecision(baseline: baseline,
                               current: MacAudioRoute(device: 10, source: 1, jackConnected: true, alive: false),
                               baselineDeviceAvailable: true),
            .lost)
    }

    func testDropPausesCheckpointsCallsBackOnceAndHoldsTheQueue() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        var callbacks = 0
        rig.controller.onOutputLostPause = { callbacks += 1 }
        rig.controller.enableOutputLossPause(source: rig.route)
        try rig.controller.play()
        rig.backend.currentTime = 12
        let hold = rig.controller.explicitHoldSerial

        rig.route.route = nil
        rig.route.changed?()

        await waitUntil { callbacks == 1 }
        XCTAssertEqual(rig.backend.pauseCount, 1)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertFalse(rig.controller.isPlaying)
        XCTAssertEqual(rig.controller.explicitHoldSerial, hold &+ 1)
        let stored = try await rig.store.playbackState(
            for: rig.revision.itemID, revisionID: rig.revision.revisionID)
        XCTAssertEqual(try XCTUnwrap(stored).positionSeconds, 12)
        XCTAssertEqual(callbacks, 1)
    }

    func testNoListenerIsRegisteredWhilePaused() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let controller = rig.controller
        controller.enableOutputLossPause(source: rig.route)
        XCTAssertEqual(rig.route.starts, 0)

        try controller.play()
        XCTAssertEqual(rig.route.starts, 1)
        try await controller.pause()
        XCTAssertEqual(rig.route.stops, 1)
        XCTAssertNil(rig.route.changed)

        try controller.play()
        XCTAssertEqual(rig.route.starts, 2)
        try await controller.load(revision: rig.revision, mediaURL: URL(fileURLWithPath: "/tmp/output-loss.m4a"))
        XCTAssertEqual(rig.route.stops, 2)
        XCTAssertFalse(controller.isPlaying)

        try controller.play()
        XCTAssertEqual(rig.route.starts, 3)
        try await controller.handlePauseOrQuit()
        XCTAssertEqual(rig.route.stops, 3)
    }

    func testDropDuringSpokenHoldPausesAndCheckpointsOnceWhenOutputListenerFiresFirst() async throws {
        try await assertDropDuringSpokenHold(outputListenerFirst: true)
    }

    func testDropDuringSpokenHoldPausesAndCheckpointsOnceWhenHoldListenerFiresFirst() async throws {
        try await assertDropDuringSpokenHold(outputListenerFirst: false)
    }

    /// Both listeners see the drop; CoreAudio does not order them.
    private func assertDropDuringSpokenHold(outputListenerFirst: Bool) async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let controller = rig.controller
        let holdRoute = OutputLossRoute()
        let speaker = StubSpeaker()
        let wall = TestWallClock()
        var callbacks = 0
        controller.onOutputLostPause = { callbacks += 1 }
        controller.enableOutputLossPause(source: rig.route)
        controller.enableInterruptions(
            speaker: speaker, waitLimit: 60, clock: wall.clock, cues: nil, routeSource: holdRoute)
        defer { controller.disableInterruptions(resuming: false) }

        try controller.play()
        rig.backend.currentTime = 12
        controller.deliverBulletin(try bulletin(at: wall.now))
        XCTAssertTrue(controller.isPlaying)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertNotNil(controller.speakingBulletin)
        let sequence = controller.sequence
        let pauses = rig.backend.pauseCount

        rig.route.route = nil
        holdRoute.route = nil
        let listeners = [rig.route.changed, holdRoute.changed]
        for changed in outputListenerFirst ? listeners : listeners.reversed() { changed?() }

        await waitUntil { callbacks == 1 }
        XCTAssertEqual(rig.backend.pauseCount, pauses + 1)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.speakingBulletin)
        XCTAssertEqual(controller.sequence, sequence + 1)
        let stored = try await rig.store.playbackState(
            for: rig.revision.itemID, revisionID: rig.revision.revisionID)
        XCTAssertEqual(try XCTUnwrap(stored).positionSeconds, 12)
        XCTAssertEqual(callbacks, 1)
    }

    func testFeatureOffIgnoresRouteChanges() async throws {
        let rig = try await rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let controller = rig.controller
        var callbacks = 0
        controller.onOutputLostPause = { callbacks += 1 }
        try controller.play()
        XCTAssertNil(rig.route.changed)

        rig.route.route = nil
        rig.route.changed?()
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(rig.route.starts, 0)

        controller.enableOutputLossPause(source: rig.route)
        XCTAssertEqual(rig.route.starts, 1)
        let stale = rig.route.changed
        controller.disableOutputLossPause()
        XCTAssertEqual(rig.route.stops, 1)
        stale?()
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(callbacks, 0)
    }
}
