import XCTest
@testable import WiltedMac

@MainActor
private final class FakeLocationManager: WiltedLocationManaging {
    var authorization: WiltedLocationAuthorization
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double) -> Void)?
    var onFailure: (() -> Void)?
    private(set) var fixRequests = 0
    private(set) var permissionRequests = 0

    init(_ authorization: WiltedLocationAuthorization) { self.authorization = authorization }

    func requestPermission() { permissionRequests += 1 }
    func requestOneFix() { fixRequests += 1 }
}

@MainActor
private final class FakeWiFi: WiltedWiFiPowerReading {
    var isPoweredOn: Bool
    init(_ on: Bool) { isPoweredOn = on }
}

@MainActor
final class WiltedLocationProviderTests: XCTestCase {
    private let typed = WiltedCoordinates(latitude: 38.9, longitude: -77.0)

    private func make(_ auth: WiltedLocationAuthorization, wifi: Bool = true, typed: Bool = false,
                      clock: @escaping () -> Date = Date.init)
        -> (WiltedLocationProvider, FakeLocationManager, FakeWiFi) {
        let manager = FakeLocationManager(auth)
        let radio = FakeWiFi(wifi)
        let provider = WiltedLocationProvider(manager: manager, wifi: radio,
                                              typedCoordinates: typed ? self.typed : nil, now: clock)
        return (provider, manager, radio)
    }

    func testDeniedPermissionWithTypedCoordinatesReportsTyped() {
        let (provider, manager, _) = make(.denied, typed: true)
        provider.start(notificationCenter: NotificationCenter())
        XCTAssertEqual(provider.status, .typed)
        XCTAssertEqual(provider.coordinates, typed)
        XCTAssertEqual(manager.fixRequests, 0)
        provider.stop()
    }

    func testDeniedWithoutTypedReportsDenied() {
        let (provider, _, _) = make(.denied)
        provider.refresh()
        XCTAssertEqual(provider.status, .denied)
        XCTAssertNil(provider.coordinates)
    }

    func testFixReceivedWhileWiFiOffIsDiscardedAndTypedUsed() {
        let (provider, manager, radio) = make(.authorized, typed: true)
        provider.refresh()
        XCTAssertEqual(manager.fixRequests, 1)
        radio.isPoweredOn = false
        manager.onFix?(40.7128, -74.0060)
        XCTAssertEqual(provider.status, .typed)
        XCTAssertEqual(provider.coordinates, typed)
    }

    func testFixWhileWiFiOffWithoutTypedIsNoFix() {
        let (provider, manager, radio) = make(.authorized)
        provider.refresh()
        radio.isPoweredOn = false
        manager.onFix?(40.7128, -74.0060)
        XCTAssertEqual(provider.status, .noFix)
        XCTAssertEqual(provider.detail, .fixDiscardedWifiOff)
        XCTAssertNil(provider.coordinates)
    }

    func testWiFiOffAtRequestTimeNeverAsksForAFix() {
        let (provider, manager, _) = make(.authorized, wifi: false)
        provider.refresh()
        XCTAssertEqual(manager.fixRequests, 0)
        XCTAssertEqual(provider.status, .noFix)
        XCTAssertEqual(provider.detail, .wifiOff)
    }

    func testAcceptedFixIsRoundedToTwoDecimals() {
        let (provider, manager, _) = make(.authorized, typed: true)
        provider.refresh()
        manager.onFix?(40.71284, -74.00606)
        XCTAssertEqual(provider.status, .located)
        XCTAssertEqual(provider.coordinates, WiltedCoordinates(latitude: 40.71, longitude: -74.01))
    }

    func testUnsolicitedAndInvalidFixesAreIgnored() {
        let (provider, manager, _) = make(.authorized)
        manager.onFix?(40.0, -74.0)
        XCTAssertEqual(provider.status, .noFix)
        provider.refresh()
        manager.onFix?(.nan, -74.0)
        XCTAssertEqual(provider.status, .noFix)
        XCTAssertNil(provider.coordinates)
    }

    func testFailureFallsBackToTypedOrNoFix() {
        let (provider, manager, _) = make(.authorized)
        provider.refresh()
        manager.onFailure?()
        XCTAssertEqual(provider.status, .noFix)
        provider.typedCoordinates = typed
        XCTAssertEqual(provider.status, .typed)
    }

    func testNotDeterminedNeverPromptsOnLaunchAndIsNone() {
        let (provider, manager, _) = make(.notDetermined)
        provider.start(notificationCenter: NotificationCenter())
        XCTAssertEqual(manager.permissionRequests, 0)
        XCTAssertEqual(provider.status, .none)
        provider.requestPermission()
        XCTAssertEqual(manager.permissionRequests, 1)
        provider.stop()
    }

    func testGrantingPermissionTriggersOneFix() {
        let (provider, manager, _) = make(.notDetermined)
        provider.requestPermission()
        manager.authorization = .authorized
        manager.onAuthorizationChange?()
        XCTAssertEqual(manager.fixRequests, 1)
    }

    func testWakeRefreshesAtMostHourly() {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let (provider, manager, _) = make(.authorized, clock: { current })
        provider.start(notificationCenter: NotificationCenter())
        XCTAssertEqual(manager.fixRequests, 1)
        current += 1_800
        provider.refreshOnWake()
        XCTAssertEqual(manager.fixRequests, 1)
        current += 1_800
        provider.refreshOnWake()
        XCTAssertEqual(manager.fixRequests, 2)
        provider.stop()
    }

    func testWakeNotificationTriggersRefreshAfterAnHour() async {
        var current = Date(timeIntervalSince1970: 2_000_000)
        let center = NotificationCenter()
        let (provider, manager, _) = make(.authorized, clock: { current })
        provider.start(notificationCenter: center)
        current += 3_700
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<50 where manager.fixRequests < 2 { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(manager.fixRequests, 2)
        provider.stop()
    }

    func testCoordinatesRejectOutOfRangeValues() {
        XCTAssertNil(WiltedCoordinates(latitude: 91, longitude: 0))
        XCTAssertNil(WiltedCoordinates(latitude: 0, longitude: 181))
    }

    func testInfoPlistCarriesLocationUsageKey() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        XCTAssertFalse((dict["NSLocationUsageDescription"] as? String ?? "").isEmpty)
    }
}
