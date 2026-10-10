import XCTest
@testable import WiltediOS

@MainActor
private final class FakeLocationManager: LibraryLocationManaging {
    var authorization: LibraryLocationAuthorization = .notDetermined
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double, Date) -> Void)?
    var onFailure: (() -> Void)?
    private(set) var authorizationRequests = 0
    private(set) var fixRequests = 0

    func requestWhenInUseAuthorization() { authorizationRequests += 1 }
    func requestOneShotFix() { fixRequests += 1 }

    func grant() { authorization = .authorized; onAuthorizationChange?() }
}

@MainActor
final class LibraryLocationProviderTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var manager: FakeLocationManager!
    private var provider: LibraryLocationProvider!

    override func setUp() async throws {
        manager = FakeLocationManager()
        provider = LibraryLocationProvider(manager: manager, now: { [unowned self] in clock })
    }

    func testAuthorizationIsNotRequestedBeforeAlertsAreTurnedOn() {
        provider.appBecameActive()
        provider.playbackStarted(inForeground: true)
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(manager.fixRequests, 0)
        XCTAssertEqual(provider.status, .none)
        provider.setAlertsEnabled(true)
        XCTAssertEqual(manager.authorizationRequests, 1)
    }

    func testGrantTakesOneFixAndRoundsToTwoDecimals() {
        provider.setAlertsEnabled(true)
        manager.grant()
        XCTAssertEqual(manager.fixRequests, 1)
        manager.onFix?(39.74561, -97.08921, clock)
        XCTAssertEqual(provider.status, .located)
        XCTAssertEqual(provider.currentFix, LibraryLocationFix(latitude: 39.75, longitude: -97.09, fixedAt: clock))
    }

    func testFixOlderThan24HoursIsStaleWithNoCoordinates() {
        provider.setAlertsEnabled(true)
        manager.grant()
        manager.onFix?(39.7, -97.1, clock)
        clock = clock.addingTimeInterval(24 * 3600 + 1)
        XCTAssertEqual(provider.status, .stale)
        XCTAssertNil(provider.currentFix)
    }

    func testFixJustInsideTwentyFourHoursIsStillUsed() {
        provider.setAlertsEnabled(true)
        manager.grant()
        manager.onFix?(39.7, -97.1, clock)
        clock = clock.addingTimeInterval(24 * 3600 - 1)
        XCTAssertEqual(provider.status, .located)
        XCTAssertNotNil(provider.currentFix)
    }

    func testBackgroundPlaybackUsesTheCacheAndTakesNoFix() {
        provider.setAlertsEnabled(true)
        manager.grant()
        manager.onFix?(39.7, -97.1, clock)
        let before = manager.fixRequests
        provider.playbackStarted(inForeground: false)
        XCTAssertEqual(manager.fixRequests, before)
        XCTAssertNotNil(provider.currentFix)
    }

    func testForegroundEventsRefreshOnceWhileOneIsInFlight() {
        provider.setAlertsEnabled(true)
        manager.grant()
        provider.appBecameActive()
        provider.playbackStarted(inForeground: true)
        XCTAssertEqual(manager.fixRequests, 1)
        manager.onFix?(1, 2, clock)
        provider.appBecameActive()
        XCTAssertEqual(manager.fixRequests, 2)
    }

    func testFailedFixAllowsARetry() {
        provider.setAlertsEnabled(true)
        manager.grant()
        manager.onFailure?()
        provider.appBecameActive()
        XCTAssertEqual(manager.fixRequests, 2)
    }

    func testDeniedPausesWithDeniedStatusAndNoRequests() {
        manager.authorization = .denied
        provider.setAlertsEnabled(true)
        provider.appBecameActive()
        XCTAssertEqual(provider.status, .denied)
        XCTAssertEqual(manager.authorizationRequests, 0)
        XCTAssertEqual(manager.fixRequests, 0)
        XCTAssertNil(provider.currentFix)
    }

    func testTurningAlertsOffDropsTheFix() {
        provider.setAlertsEnabled(true)
        manager.grant()
        manager.onFix?(39.7, -97.1, clock)
        provider.setAlertsEnabled(false)
        XCTAssertEqual(provider.status, .none)
        XCTAssertNil(provider.currentFix)
    }

    func testInfoPlistHasWhenInUseKeyAndNoLocationBackgroundMode() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltediOS/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertFalse((plist["NSLocationWhenInUseUsageDescription"] as? String ?? "").isEmpty)
        XCTAssertEqual(plist["NSLocationDefaultAccuracyReduced"] as? Bool, true)
        let modes = plist["UIBackgroundModes"] as? [String] ?? []
        XCTAssertFalse(modes.contains("location"))
    }
}
