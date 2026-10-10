import Foundation
import Testing
import WiltedLibrary
@testable import WiltedWeather

private final class StubSource: NWSAlertSource, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var responses: [NWSAlertsResponse]
    init(_ responses: [NWSAlertsResponse]) { self.responses = responses }
    var callCount: Int { lock.withLock { calls } }

    func activeAlerts(lat: Double, lon: Double) async throws -> NWSAlertsResponse {
        lock.withLock {
            calls += 1
            return responses.count > 1 ? responses.removeFirst() : responses[0]
        }
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bulletin] = []
    func add(_ bulletin: Bulletin) { lock.withLock { items.append(bulletin) } }
    var bulletins: [Bulletin] { lock.withLock { items } }
}

private let nowDate = Date(timeIntervalSince1970: 1_000_000)

private func warning(_ id: String, severity: String = "Severe", expiresIn: TimeInterval = 1800) -> NWSAlert {
    NWSAlert(id: id, event: "Tornado Warning", areaDesc: "Washington", severity: severity, messageType: "Alert",
             headline: "Tornado Warning for Washington", sent: nowDate, expires: nowDate.addingTimeInterval(expiresIn))
}

private func response(_ alerts: [NWSAlert]) -> NWSAlertsResponse { NWSAlertsResponse(alerts: alerts, pollInterval: 60) }

private func monitor(_ source: StubSource, _ sink: Collector,
                     sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) })
    -> AlertMonitor {
    AlertMonitor(source: source, deliver: { sink.add($0) }, sleep: sleep, now: { nowDate })
}

@Suite("Alert monitor")
struct AlertMonitorTests {
    @Test func stoppedMonitorMakesNoRequest() async throws {
        let source = StubSource([response([warning("a1")])])
        let monitor = monitor(source, Collector())
        await monitor.setCoordinates(lat: 39.74, lon: -97.09)
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.callCount == 0)
        await monitor.start()
        await monitor.stop()
        await monitor.setCoordinates(lat: 40, lon: -97)
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.callCount == 0)
        let after = source.callCount
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.callCount == after)
    }

    @Test func startedMonitorWithoutCoordinatesMakesNoRequest() async throws {
        let source = StubSource([response([warning("a1")])])
        let monitor = monitor(source, Collector())
        await monitor.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.callCount == 0)
        await monitor.stop()
    }

    @Test func stopAfterStartHaltsPolling() async throws {
        let source = StubSource([response([])])
        let ticks = Ticker()
        let monitor = monitor(source, Collector()) { _ in await ticks.wait() }
        await monitor.setCoordinates(lat: 39.74, lon: -97.09)
        await monitor.start()
        try await waitUntil { source.callCount == 1 }
        await monitor.stop()
        await ticks.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.callCount == 1)
    }

    @Test func stopWhileARequestIsInFlightDeliversNothing() async throws {
        final class Gated: NWSAlertSource, @unchecked Sendable {
            private let lock = NSLock()
            private var started = 0
            private var gate: CheckedContinuation<Void, Never>?
            var requests: Int { lock.withLock { started } }
            func activeAlerts(lat: Double, lon: Double) async throws -> NWSAlertsResponse {
                await withCheckedContinuation { continuation in lock.withLock { started += 1; gate = continuation } }
                return response([warning("a1")])
            }
            func release() { lock.withLock { let held = gate; gate = nil; return held }?.resume() }
        }
        let sink = Collector()
        let source = Gated()
        let monitor = AlertMonitor(source: source, deliver: { sink.add($0) }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                                   now: { nowDate })
        await monitor.setCoordinates(lat: 39.74, lon: -97.09)
        await monitor.start()
        try await waitUntil { source.requests == 1 }
        await monitor.stop()
        source.release()
        try await Task.sleep(for: .milliseconds(150))
        #expect(sink.bulletins.isEmpty)
        #expect(await monitor.activeAlertIDs.isEmpty)
        #expect(await monitor.status.lastPollAt == nil)
    }

    @Test func pollEmitsAlertBulletinsOnceAndDedupes() async throws {
        let sink = Collector()
        let source = StubSource([response([warning("a1")])])
        let monitor = monitor(source, sink)
        await monitor.setCoordinates(lat: 39.74, lon: -97.09)
        await monitor.pollOnce()
        await monitor.pollOnce()
        let bulletin = try #require(sink.bulletins.first)
        #expect(sink.bulletins.count == 1)
        #expect(bulletin.kind == .alert)
        #expect(bulletin.id == "a1")
        #expect(bulletin.severity == .severe)
        #expect(bulletin.text == "Tornado Warning for Washington")
        #expect(bulletin.expiresAt == nowDate.addingTimeInterval(1800))
        #expect(await monitor.activeAlertIDs == ["a1"])
    }

    @Test func updateCarriesSupersedesAndExpiredAlertsAreDropped() async throws {
        let sink = Collector()
        var update = warning("a2", severity: "Extreme")
        update = NWSAlert(id: "a2", event: update.event, areaDesc: "Washington", severity: "Extreme", messageType: "Update",
                          headline: nil, sent: nowDate, expires: nowDate.addingTimeInterval(600), references: ["a1"])
        let source = StubSource([response([warning("old", expiresIn: -5), update])])
        let monitor = monitor(source, sink)
        await monitor.setCoordinates(lat: 39.74, lon: -97.09)
        await monitor.pollOnce()
        #expect(sink.bulletins.map(\.id) == ["a2"])
        #expect(sink.bulletins.first?.supersedes == "a1")
        #expect(sink.bulletins.first?.text == "Tornado Warning for Washington.")
    }

    @Test func failureBacksOffAndRecovers() async throws {
        struct Down: Error {}
        final class Failing: NWSAlertSource, @unchecked Sendable {
            func activeAlerts(lat: Double, lon: Double) async throws -> NWSAlertsResponse { throw Down() }
        }
        let monitor = AlertMonitor(source: Failing(), deliver: { _ in }, now: { nowDate })
        await monitor.setCoordinates(lat: 39.74, lon: -97.09)
        #expect(await monitor.pollOnce() == 60)
        #expect(await monitor.pollOnce() == 120)
        #expect(await monitor.status.consecutiveFailures == 2)
    }
}

private actor Ticker {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func release() { waiting.forEach { $0.resume() }; waiting = [] }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}
