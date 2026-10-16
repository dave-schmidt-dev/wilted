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
private final class LifecycleSpeaker: BulletinSpeaking {
    var completion: (@MainActor () -> Void)?
    var stops = 0
    func speak(_ text: String, finished: @escaping @MainActor () -> Void) -> Bool {
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
        var model: WiltedMacModel { library.model }
    }

    private func rig(registers: Bool = true) async throws -> Rig {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("route-loss-lifecycle"))
        let (backend, _) = library.installScriptedPlayback(on: library.model)
        let route = LifecycleRoute()
        route.canRegister = registers
        let speaker = LifecycleSpeaker()
        let location = WiltedLocationProvider(manager: LifecycleLocation(), wifi: LifecycleWiFi())
        let hub = WiltedMacBulletinHub(model: library.model, location: location,
                                      makeSpeaker: { speaker }, makeRouteSource: { route },
                                      makeAlertSource: { _ in LifecycleAlerts() })
        library.model.installBulletinHubForTesting(hub)
        return Rig(library: library, backend: backend, route: route, speaker: speaker, hub: hub)
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

    func testRegistrationFailureDisablesSpeechAndExposesCuratedReportsStatus() async throws {
        let rig = try await rig(registers: false)
        enabled(rig, true)
        XCTAssertEqual(rig.route.listeners, 0)
        XCTAssertFalse(rig.hub.interruptionsAreAttached)
        XCTAssertFalse(rig.model.playback?.interruptionsEnabled ?? true)
        XCTAssertEqual(rig.hub.routeProtectionStatus,
                       "Bulletins are paused because audio output monitoring is unavailable. Turn Read bulletins off and on to retry.")
        let attempts = rig.route.starts
        rig.hub.reconcile()
        XCTAssertEqual(rig.route.starts, attempts, "failure waits for an explicit toggle retry")
        enabled(rig, false)
        rig.route.canRegister = true
        enabled(rig, true)
        XCTAssertEqual(rig.route.listeners, 1)
        XCTAssertNil(rig.hub.routeProtectionStatus)
        await rig.model.close()
        XCTAssertEqual(rig.route.listeners, 0)
    }
    func testRuntimeMonitoringFailureShowsCuratedStatusAndStopsAlerts() async throws {
        let rig = try await rig()
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
        await rig.model.close()
    }
}
