import CoreAudio
import XCTest
@testable import WiltedProducer

@MainActor
private final class RouteHardware: MacAudioRouteHardware {
    var output: UInt32 = 10
    var source: UInt32 = 1
    var alive: UInt32 = 1
    var jack: UInt32 = 1
    var failedRead: UInt32?
    var failRegistrationAt: Int?
    var additions = 0
    var removals = 0
    var active: [UUID: (MacAudioRouteProperty, @Sendable () -> Void)] = [:]
    var removedProperties: [MacAudioRouteProperty] = []

    func has(_ property: MacAudioRouteProperty) -> Bool { true }
    func read(_ property: MacAudioRouteProperty) -> UInt32? {
        if failedRead == property.selector { return nil }
        switch property.selector {
        case kAudioHardwarePropertyDefaultOutputDevice: return output
        case kAudioDevicePropertyDeviceIsAlive: return alive
        case kAudioDevicePropertyDataSource: return source
        case kAudioDevicePropertyJackIsConnected: return jack
        default: return nil
        }
    }
    func add(_ property: MacAudioRouteProperty, changed: @escaping @Sendable () -> Void) -> UUID? {
        additions += 1
        if additions == failRegistrationAt { return nil }
        let token = UUID()
        active[token] = (property, changed)
        return token
    }
    func remove(_ token: UUID) {
        guard let (property, _) = active.removeValue(forKey: token) else {
            XCTFail("listener removed without matching registration")
            return
        }
        removedProperties.append(property)
        removals += 1
    }
}

@MainActor
final class MacAudioRouteLossObserverTests: XCTestCase {
    func testRegistrationAndStopBalanceEveryMatchingListener() {
        let hardware = RouteHardware()
        let observer = MacAudioRouteLossObserver(hardware: hardware)
        for _ in 0..<3 {
            XCTAssertTrue(observer.start {})
            XCTAssertEqual(hardware.active.count, 5)
            XCTAssertEqual(observer.currentRoute(), MacAudioRoute(device: 10, source: 1, jackConnected: true))
            observer.stop()
            observer.stop()
            XCTAssertTrue(hardware.active.isEmpty)
        }
        XCTAssertEqual(hardware.additions, hardware.removals)
    }

    func testEveryPartialRegistrationFailureRemovesItsExactListeners() {
        for index in 1...5 {
            let hardware = RouteHardware()
            hardware.failRegistrationAt = index
            let observer = MacAudioRouteLossObserver(hardware: hardware)
            XCTAssertFalse(observer.start {})
            XCTAssertTrue(hardware.active.isEmpty)
            XCTAssertNil(observer.currentRoute())
            XCTAssertEqual(hardware.removals, index - 1)
        }
    }

    func testCurrentRouteQueriesHardwareWithoutWaitingForNotifications() {
        let hardware = RouteHardware()
        let observer = MacAudioRouteLossObserver(hardware: hardware)
        XCTAssertTrue(observer.start {})
        defer { observer.stop() }
        hardware.output = 20
        hardware.source = 2
        XCTAssertEqual(observer.currentRoute()?.device, 20)
        XCTAssertEqual(observer.currentRoute()?.source, 2)
        hardware.jack = 0
        XCTAssertEqual(observer.currentRoute()?.jackConnected, false)
        hardware.alive = 0
        XCTAssertFalse(observer.currentRoute()?.isAvailable ?? true)
        hardware.failedRead = kAudioDevicePropertyDataSource
        XCTAssertNil(observer.currentRoute())
    }

    func testRetargetRemovesOldDeviceAndLateCallbacksAreFenced() async {
        let hardware = RouteHardware()
        let observer = MacAudioRouteLossObserver(hardware: hardware)
        var changes = 0
        XCTAssertTrue(observer.start { changes += 1 })
        let callback = hardware.active.values.first!.1
        hardware.output = 20
        callback()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(hardware.active.count, 5)
        XCTAssertFalse(hardware.active.values.contains { $0.0.object == 10 })
        XCTAssertEqual(hardware.removedProperties.filter { $0.object == 10 }.count, 3)
        observer.stop()
        callback()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(hardware.active.isEmpty)
        XCTAssertEqual(hardware.additions, hardware.removals)
    }

    func testRetargetRegistrationFailureFailsClosedAndCleansUp() async {
        let hardware = RouteHardware()
        let observer = MacAudioRouteLossObserver(hardware: hardware)
        var changes = 0
        XCTAssertTrue(observer.start { changes += 1 })
        let callback = hardware.active.values.first!.1
        hardware.output = 20
        hardware.failRegistrationAt = hardware.additions + 2
        callback()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(observer.currentRoute())
        XCTAssertFalse(observer.monitoringAvailable)
        XCTAssertEqual(changes, 1, "the controller must hear that protection failed")
        observer.stop()
        XCTAssertTrue(hardware.active.isEmpty)
    }

    func testReleasedObserverRemovesItsRegistrations() async {
        let hardware = RouteHardware()
        var observer: MacAudioRouteLossObserver? = MacAudioRouteLossObserver(hardware: hardware)
        XCTAssertTrue(observer!.start {})
        weak var released = observer
        observer = nil
        XCTAssertNil(released)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(hardware.active.isEmpty)
        XCTAssertEqual(hardware.additions, hardware.removals)
    }

    func testDeviceAvailabilityTreatsDeadMissingAndUnreadableDevicesAsGone() {
        let hardware = RouteHardware()
        let observer = MacAudioRouteLossObserver(hardware: hardware)
        XCTAssertTrue(observer.start {})
        defer { observer.stop() }
        XCTAssertTrue(observer.isDeviceAvailable(10))
        hardware.alive = 0
        XCTAssertFalse(observer.isDeviceAvailable(10))
        XCTAssertFalse(observer.isDeviceAvailable(kAudioObjectUnknown))

        hardware.alive = 1
        hardware.failedRead = kAudioDevicePropertyDeviceIsAlive
        XCTAssertFalse(observer.isDeviceAvailable(10), "a failed read counts as gone")
    }
}
