import Foundation
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer
import WiltedWeather

@MainActor
private final class HubFakeLocationManager: WiltedLocationManaging {
    var authorization: WiltedLocationAuthorization = .denied
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double) -> Void)?
    var onFailure: (() -> Void)?
    func requestPermission() {}
    func requestOneFix() {}
}

@MainActor
private final class HubFakeWiFi: WiltedWiFiPowerReading {
    var isPoweredOn = true
}

/// A speaker that never makes a sound.
@MainActor
private final class HubSilentSpeaker: BulletinSpeaking {
    func speak(_ text: String, finished: @escaping @MainActor () -> Void) -> Bool { false }
    func stop() {}
}

/// Counts requests and fails each one, so a running monitor shows up as calls and a stopped one as none.
private final class HubCountingSource: NWSAlertSource, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var value = 0
    var calls: Int { lock.withLock { value } }

    func activeAlerts(lat: Double, lon: Double) async throws -> NWSAlertsResponse {
        lock.withLock { value += 1 }
        throw Failure()
    }
}

/// The hub that turns on spoken interruptions and runs the alert monitor, against a real
/// non-fixture model with scripted playback, a fake location and a source that counts calls.
@MainActor
final class WiltedMacBulletinHubTests: XCTestCase {
    private struct Rig {
        let library: AccountingLibrary
        let model: WiltedMacModel
        let hub: WiltedMacBulletinHub
        let source: HubCountingSource
    }

    private func makeRig() async throws -> Rig {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("bulletin-hub"))
        let model = library.model
        _ = library.installScriptedPlayback(on: model)
        let source = HubCountingSource()
        let provider = WiltedLocationProvider(manager: HubFakeLocationManager(), wifi: HubFakeWiFi())
        let hub = WiltedMacBulletinHub(
            model: model, location: provider, makeSpeaker: { HubSilentSpeaker() }, makeAlertSource: { _ in source })
        model.installBulletinHubForTesting(hub)
        return Rig(library: library, model: model, hub: hub, source: source)
    }

    private func set(_ model: WiltedMacModel, interruptions: Bool, alerts: Bool = true) {
        model.updateAutomationSettings { current in
            current.updatingReports {
                $0.interruptionsEnabled = interruptions
                $0.alertsEnabled = alerts
                $0.typedLatitude = 38.9
                $0.typedLongitude = -77.0
            }
        }
    }

    func testInterruptionsOffAttachNothingAndStartNoMonitor() async throws {
        let rig = try await makeRig()
        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        rig.hub.reconcile()
        XCTAssertTrue(rig.model.isPlaying)
        XCTAssertFalse(rig.hub.interruptionsAreAttached)
        XCTAssertFalse(rig.hub.alertMonitorIsRunning)
        XCTAssertEqual(rig.source.calls, 0)
    }

    func testAlertMonitorRunsOnlyWhilePlayingWithAlertsOnAndStopsWhenPaused() async throws {
        let rig = try await makeRig()
        set(rig.model, interruptions: true)
        XCTAssertTrue(rig.hub.interruptionsAreAttached, "turning interruptions on attaches the player")
        XCTAssertFalse(rig.model.isPlaying)
        XCTAssertFalse(rig.hub.alertMonitorIsRunning, "no monitor while paused")
        XCTAssertEqual(rig.source.calls, 0, "no request while paused")

        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        await WiltedMacHeadless.eventually("the monitor starts once playing") { rig.hub.alertMonitorIsRunning }
        await WiltedMacHeadless.eventually("the monitor asks for alerts at the Mac's location") { rig.source.calls > 0 }

        rig.model.pausePlayback()
        await rig.model.waitForPlaybackOperationForTesting()
        await WiltedMacHeadless.eventually("the monitor stops when paused") { !rig.hub.alertMonitorIsRunning }
        XCTAssertTrue(rig.hub.interruptionsAreAttached, "the player stays attached while paused")
        set(rig.model, interruptions: false)
    }

    func testTurningAlertsOffStopsTheMonitorAndTurningInterruptionsOffDetaches() async throws {
        let rig = try await makeRig()
        set(rig.model, interruptions: true)
        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        await WiltedMacHeadless.eventually("the monitor starts") { rig.hub.alertMonitorIsRunning }

        set(rig.model, interruptions: true, alerts: false)
        XCTAssertFalse(rig.hub.alertMonitorIsRunning, "alerts off stops the monitor")
        XCTAssertTrue(rig.hub.interruptionsAreAttached, "headlines still speak")

        set(rig.model, interruptions: true, alerts: true)
        await WiltedMacHeadless.eventually("alerts on again restarts it") { rig.hub.alertMonitorIsRunning }

        set(rig.model, interruptions: false)
        XCTAssertFalse(rig.hub.interruptionsAreAttached)
        XCTAssertFalse(rig.hub.alertMonitorIsRunning)
        XCTAssertFalse(rig.model.playback?.interruptionsEnabled ?? true)
    }

    func testAMorningReportShowsUnderAllOnlyInTheLarderKindFilter() {
        var report = WiltedMacEpisode(
            id: "report-1", title: "Morning report", feedTitle: "Morning report", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_900), durationSeconds: 360,
            playbackSeconds: 0, downloadState: .completed, preparationState: .prepared(summary: "Report"))
        report.audiobook = WiltedMacAudiobookDetails(
            author: nil, chapters: [], sourceFormat: "report", volumeIndex: 0, volumeCount: 1)
        XCTAssertTrue(report.isReport)
        XCTAssertTrue(WiltedMacLarderKind.all.includes(report))
        XCTAssertFalse(WiltedMacLarderKind.podcasts.includes(report))
        XCTAssertFalse(WiltedMacLarderKind.audiobooks.includes(report))
        XCTAssertFalse(WiltedMacLarderKind.articles.includes(report))
        var book = report
        book.audiobook?.sourceFormat = "audio"
        XCTAssertTrue(WiltedMacLarderKind.audiobooks.includes(book), "a real book still shows under Audiobooks")
    }
}
