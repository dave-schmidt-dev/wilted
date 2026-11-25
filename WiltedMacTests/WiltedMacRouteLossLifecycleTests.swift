import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import WiltedWeather

@MainActor
private final class LifecycleLocation: WiltedLocationManaging {
    var authorization: WiltedLocationAuthorization = .denied
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double) -> Void)?
    var onFailure: (() -> Void)?
    func requestPermission() {}
    func requestOneFix() {}
}

@MainActor
private final class LifecycleWiFi: WiltedWiFiPowerReading {
    var isPoweredOn = false
}

@MainActor
private final class LifecycleRoute: MacAudioRouteSource {
    var canRegister = true
    var monitoringAvailable = true
    var changed: (@MainActor () -> Void)?
    var listeners = 0
    var starts = 0
    var stops = 0
    func start(changed: @escaping @MainActor () -> Void) -> Bool {
        starts += 1
        self.changed = changed
        listeners = canRegister ? 1 : 0
        return canRegister
    }
    func currentRoute() -> MacAudioRoute? { monitoringAvailable ? MacAudioRoute(device: 10) : nil }
    func stop() { stops += 1; listeners = 0; changed = nil }
}

private struct LifecycleAlerts: NWSAlertSource {
    struct Failure: Error {}
    func activeAlerts(lat: Double, lon: Double) async throws -> NWSAlertsResponse { throw Failure() }
}

@MainActor
private final class LifecycleRetryClock {
    private struct PendingSleep {
        let continuation: CheckedContinuation<Void, Error>
    }

    private var pending: [PendingSleep] = []
    private(set) var requested: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingSleep(continuation: continuation))
        }
    }

    func advanceNext() {
        guard !pending.isEmpty else { XCTFail("expected a scheduled retry"); return }
        pending.removeFirst().continuation.resume()
    }

    func waitForRequestCount(_ count: Int) async {
        for _ in 0..<100 where requested.count < count { await Task.yield() }
        XCTAssertEqual(requested.count, count)
    }

    func resumePending() {
        let sleeps = pending
        pending = []
        for sleep in sleeps { sleep.continuation.resume() }
    }
}

@MainActor
private final class LifecycleSpeaker: BulletinSpeaking {
    var completion: (@MainActor () -> Void)?
    var stops = 0
    func speak(_ text: String, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        completion = finished
        return true
    }
    func stop() { stops += 1; completion?(); completion = nil }
}

@MainActor
final class WiltedMacRouteLossLifecycleTests: XCTestCase {
    @MainActor
    private struct Rig {
        let library: AccountingLibrary
        let backend: WiltedMacScriptedBackend
        let route: LifecycleRoute
        let speaker: LifecycleSpeaker
        let hub: WiltedMacBulletinHub
        let retryClock: LifecycleRetryClock
        var model: WiltedMacModel { library.model }
    }

    private func rig(registers: Bool = true) async throws -> Rig {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("route-loss-lifecycle"))
        let (backend, _) = library.installScriptedPlayback(on: library.model)
        let route = LifecycleRoute()
        route.canRegister = registers
        let speaker = LifecycleSpeaker()
        let location = WiltedLocationProvider(manager: LifecycleLocation(), wifi: LifecycleWiFi())
        let retryClock = LifecycleRetryClock()
        let hub = WiltedMacBulletinHub(model: library.model, location: location,
                                      makeSpeaker: { speaker }, makeRouteSource: { route },
                                      makeAlertSource: { _ in LifecycleAlerts() },
                                      retrySleep: { duration in try await retryClock.sleep(duration) })
        library.model.installBulletinHubForTesting(hub)
        return Rig(library: library, backend: backend, route: route, speaker: speaker, hub: hub,
                   retryClock: retryClock)
    }

    private func enabled(_ rig: Rig, _ enabled: Bool) {
        rig.model.updateAutomationSettings { settings in
            settings.updatingReports {
                $0.interruptionsEnabled = enabled
                $0.alertsEnabled = false
                $0.headlinesEnabled = false
            }
        }
    }

    private func hold(_ rig: Rig) async throws {
        enabled(rig, true)
        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        rig.hub.reconcile()
        rig.backend.currentTime = 8
        let now = Date()
        let bulletin = try Bulletin(id: "lifecycle", kind: .alert, text: "Synthetic bulletin", severity: .extreme,
                                    issuedAt: now, expiresAt: now.addingTimeInterval(3600))
        rig.model.playback?.deliverBulletin(bulletin)
        XCTAssertNil(rig.model.playback?.speakingBulletin, "alerts wait for a removed-ad seam too")
        XCTAssertTrue(rig.model.playback?.adBreakReached() == true)
        XCTAssertNotNil(rig.model.playback?.speakingBulletin)
        XCTAssertEqual(rig.route.listeners, 1)
        rig.backend.resetCounts()
    }

    func testCloseRemovesListenersAndNeverResumesHeldAudio() async throws {
        let rig = try await rig()
        try await hold(rig)
        let late = rig.speaker.completion
        await rig.model.close()
        late?()
        XCTAssertEqual(rig.route.listeners, 0)
        XCTAssertFalse(rig.hub.interruptionsAreAttached)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertEqual(rig.backend.playCount, 0)
        XCTAssertEqual(rig.backend.currentTime, 8)
        XCTAssertGreaterThan(rig.speaker.stops, 0)
    }

    func testTerminationRemovesListenersAndNeverResumesHeldAudio() async throws {
        let rig = try await rig()
        try await hold(rig)
        rig.model.stopAdmittingWorkForTermination()
        rig.speaker.completion?()
        XCTAssertEqual(rig.route.listeners, 0)
        XCTAssertEqual(rig.backend.playCount, 0)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertEqual(rig.backend.currentTime, 8)
        rig.hub.reconcile()
        XCTAssertEqual(rig.route.listeners, 0, "queued reconciliation cannot attach during quit")
        await rig.model.close()
    }

    func testSettingsDisablePreservesResumeAndBalancesListeners() async throws {
        let rig = try await rig()
        try await hold(rig)
        enabled(rig, false)
        XCTAssertEqual(rig.route.listeners, 0)
        XCTAssertEqual(rig.backend.playCount, 1)
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertNil(rig.hub.routeProtectionStatus)
        await rig.model.close()
    }

    func testRegistrationFailureRetriesWhenPlaybackStartsAndClearsStatus() async throws {
        let rig = try await rig(registers: false)
        defer { rig.retryClock.resumePending() }
        enabled(rig, true)
        XCTAssertEqual(rig.route.listeners, 0)
        XCTAssertFalse(rig.hub.interruptionsAreAttached)
        XCTAssertFalse(rig.model.playback?.interruptionsEnabled ?? true)
        XCTAssertEqual(rig.hub.routeProtectionStatus, WiltedMacBulletinHub.unavailableRouteMessage)
        XCTAssertEqual(rig.hub.routeProtectionStatus,
                       "Bulletins are paused because Wilted couldn’t check the sound output.")
        await rig.retryClock.waitForRequestCount(1)
        XCTAssertEqual(rig.retryClock.requested.first, .seconds(5))

        rig.route.canRegister = true
        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        for _ in 0..<20 where !rig.hub.interruptionsAreAttached { await Task.yield() }

        XCTAssertEqual(rig.route.listeners, 1)
        XCTAssertTrue(rig.hub.interruptionsAreAttached)
        XCTAssertNil(rig.hub.routeProtectionStatus)
        XCTAssertTrue(rig.model.playback?.interruptionsEnabled ?? false)
        await rig.model.close()
        XCTAssertEqual(rig.route.listeners, 0)
    }

    func testRegistrationFailureRetriesWhenPlayerChangesAndClearsStatus() async throws {
        let rig = try await rig(registers: false)
        defer { rig.retryClock.resumePending() }
        enabled(rig, true)
        XCTAssertFalse(rig.hub.interruptionsAreAttached)
        XCTAssertEqual(rig.hub.routeProtectionStatus, WiltedMacBulletinHub.unavailableRouteMessage)
        await rig.retryClock.waitForRequestCount(1)

        rig.route.canRegister = true
        let store = try XCTUnwrap(rig.model.store)
        let replacement = PlaybackController(
            store: store, backend: WiltedMacScriptedBackend(), deviceID: "replacement")
        rig.model.playback = replacement
        for _ in 0..<20 where !rig.hub.interruptionsAreAttached { await Task.yield() }

        XCTAssertTrue(rig.hub.interruptionsAreAttached)
        XCTAssertTrue(replacement.interruptionsEnabled)
        XCTAssertEqual(rig.route.listeners, 1)
        XCTAssertNil(rig.hub.routeProtectionStatus)
        await rig.model.close()
        XCTAssertEqual(rig.route.listeners, 0)
    }

    func testRuntimeMonitoringFailureStopsHeldAudioAndRecoversOnRetry() async throws {
        let rig = try await rig()
        defer { rig.retryClock.resumePending() }
        try await hold(rig)
        rig.model.updateAutomationSettings { settings in
            settings.updatingReports {
                $0.alertsEnabled = true
                $0.typedLatitude = 38.9
                $0.typedLongitude = -77.0
            }
        }
        XCTAssertTrue(rig.hub.alertMonitorIsRunning)
        rig.route.monitoringAvailable = false
        rig.route.changed?()
        XCTAssertEqual(rig.hub.routeProtectionStatus, WiltedMacBulletinHub.unavailableRouteMessage)
        XCTAssertEqual(rig.hub.routeProtectionStatus,
                       "Bulletins are paused because Wilted couldn’t check the sound output.")
        XCTAssertFalse(rig.hub.alertMonitorIsRunning)
        XCTAssertFalse(rig.hub.interruptionsAreAttached)
        XCTAssertFalse(rig.model.playback?.interruptionsEnabled ?? true)
        XCTAssertEqual(rig.route.listeners, 0)
        XCTAssertNil(rig.route.changed)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertEqual(rig.backend.playCount, 0)
        XCTAssertEqual(rig.backend.currentTime, 8)
        for scheme in [ColorScheme.light, .dark] {
            let bitmap = try WiltedMacHeadless.render(
                WiltedMacReportsCard(model: rig.model, location: rig.hub.location)
                    .environment(\.colorScheme, scheme)
                    .padding(16),
                size: CGSize(width: 480, height: 220))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "route-monitoring-\(scheme == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        await rig.retryClock.waitForRequestCount(1)
        XCTAssertEqual(rig.retryClock.requested.first, .seconds(5))

        for attempt in 1...3 {
            rig.retryClock.advanceNext()
            await rig.retryClock.waitForRequestCount(attempt + 1)
            XCTAssertFalse(rig.hub.interruptionsAreAttached)
            XCTAssertFalse(rig.model.playback?.interruptionsEnabled ?? true)
            XCTAssertFalse(rig.backend.isPlaying)
            XCTAssertEqual(rig.backend.playCount, 0)
            XCTAssertEqual(rig.backend.currentTime, 8)
        }
        XCTAssertEqual(Array(rig.retryClock.requested.prefix(4)),
                       [.seconds(5), .seconds(30), .seconds(120), .seconds(120)])

        rig.route.monitoringAvailable = true
        rig.retryClock.advanceNext()
        for _ in 0..<20 where !rig.hub.interruptionsAreAttached { await Task.yield() }
        XCTAssertTrue(rig.hub.interruptionsAreAttached)
        XCTAssertTrue(rig.model.playback?.interruptionsEnabled ?? false)
        XCTAssertNil(rig.hub.routeProtectionStatus)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertEqual(rig.backend.playCount, 0)
        XCTAssertEqual(rig.backend.currentTime, 8)

        await rig.model.close()
    }
}
