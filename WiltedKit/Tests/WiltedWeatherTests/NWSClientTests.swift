import Foundation
import Testing
@testable import WiltedWeather

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Replays queued responses and records every request. No network is touched.
final class StubTransport: NWSTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var finalURL: URL?
    }

    private let lock = NSLock()
    private var queue: [Reply]
    private var seen: [URLRequest] = []

    init(_ replies: [Reply]) { queue = replies }

    var requests: [URLRequest] { lock.withLock { seen } }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = lock.withLock {
            seen.append(request)
            return queue.isEmpty ? Reply(status: 500) : queue.removeFirst()
        }
        let response = HTTPURLResponse(url: reply.finalURL ?? request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

private let forecastBody = Data("""
{"properties":{"periods":[{"name":"Tonight","temperature":48,"temperatureUnit":"F","isDaytime":false,
"shortForecast":"Clear","detailedForecast":"Clear, with a low around 48."}]}}
""".utf8)

private func makeClient(_ transport: StubTransport, contact: String? = nil,
                        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000_000) }) -> NWSClient {
    NWSClient(transport: transport, appVersion: "0.2.8", repositoryURL: "https://github.com/dave-schmidt-dev/wilted",
              contact: contact, now: now)
}

@Suite("NWS client")
struct NWSClientTests {
    @Test func pointRequestCarriesCoordinatesRoundedToTwoDecimals() async throws {
        let transport = StubTransport([.init(body: try fixture("nws-points"))])
        let point = try await makeClient(transport).point(lat: 39.74561, lon: -97.08921)
        #expect(transport.requests.first?.url?.absoluteString == "https://api.weather.gov/points/39.75,-97.09")
        #expect(point.forecastZone == "KSZ009")
        #expect(point.county == "KSC201")
        #expect(point.forecastURL.absoluteString == "https://api.weather.gov/gridpoints/TOP/32,81/forecast")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Accept") == "application/geo+json")
    }

    @Test func userAgentHasNoContactWhenSettingIsEmpty() async throws {
        let base = "Wilted/0.2.8 (https://github.com/dave-schmidt-dev/wilted)"
        for contact in [nil, "", "   ", "\n"] {
            let transport = StubTransport([.init(body: try fixture("nws-points"))])
            _ = try await makeClient(transport, contact: contact).point(lat: 39.74, lon: -97.09)
            #expect(transport.requests.first?.value(forHTTPHeaderField: "User-Agent") == base)
        }
        let transport = StubTransport([.init(body: try fixture("nws-points"))])
        _ = try await makeClient(transport, contact: "me@example.com\r\nX-Evil: 1").point(lat: 39.74, lon: -97.09)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "User-Agent") == base + " me@example.comX-Evil: 1")
    }

    @Test func redirectIsRejected() async throws {
        let moved = StubTransport([.init(status: 301, headers: ["Location": "https://api.weather.gov/points/39.7456,-97.0892"])])
        await #expect(throws: NWSError.redirectRejected) { try await makeClient(moved).point(lat: 39.74, lon: -97.09) }
        let offHost = StubTransport([.init(body: try fixture("nws-points"), finalURL: URL(string: "https://evil.example/points"))])
        await #expect(throws: NWSError.redirectRejected) { try await makeClient(offHost).point(lat: 39.74, lon: -97.09) }
    }

    @Test func nonNWSHostAndInsecureSchemeAreRejectedWithoutARequest() async throws {
        let transport = StubTransport([])
        let client = makeClient(transport)
        for text in ["https://evil.example/forecast", "http://api.weather.gov/forecast",
                     "https://api.weather.gov.evil.example/x", "https://user@api.weather.gov/x",
                     "https://api.weather.gov:8443/x"] {
            await #expect(throws: NWSError.self) { try await client.forecast(url: URL(string: text)!) }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func nonNWSForecastURLInPointsResponseIsRejected() async throws {
        let body = Data(String(decoding: try fixture("nws-points"), as: UTF8.self)
            .replacingOccurrences(of: "https://api.weather.gov/gridpoints", with: "https://evil.example/gridpoints").utf8)
        await #expect(throws: NWSError.self) {
            try await makeClient(StubTransport([.init(body: body)])).point(lat: 39.74, lon: -97.09)
        }
    }

    @Test func forecastNotFoundTriggersAFreshPointsLookup() async throws {
        let points = try fixture("nws-points")
        let transport = StubTransport([
            .init(body: points), .init(status: 404), .init(body: points), .init(body: forecastBody),
        ])
        let periods = try await makeClient(transport).forecast(lat: 39.74, lon: -97.09)
        #expect(periods.first?.shortForecast == "Clear")
        let paths = transport.requests.compactMap { $0.url?.path }
        #expect(paths == ["/points/39.74,-97.09", "/gridpoints/TOP/32,81/forecast",
                          "/points/39.74,-97.09", "/gridpoints/TOP/32,81/forecast"])
    }

    @Test func pointIsCachedForADayThenRevalidated() async throws {
        let points = try fixture("nws-points")
        let transport = StubTransport([.init(body: points), .init(body: points)])
        let clock = Clock(1_000_000)
        let client = makeClient(transport) { clock.date }
        _ = try await client.point(lat: 39.74, lon: -97.09)
        clock.advance(86_399)
        _ = try await client.point(lat: 39.741, lon: -97.089)
        #expect(transport.requests.count == 1)
        clock.advance(2)
        _ = try await client.point(lat: 39.74, lon: -97.09)
        #expect(transport.requests.count == 2)
    }

    @Test func alertsUseOneZoneRequestAndPollIntervalFloorsAtSixtySeconds() async throws {
        let transport = StubTransport([
            .init(body: try fixture("nws-alerts"), headers: ["Cache-Control": "public, max-age=5, s-maxage=5"]),
            .init(body: try fixture("nws-alerts"), headers: ["Cache-Control": "public, max-age=300"]),
        ])
        let client = makeClient(transport)
        let first = try await client.activeAlerts(zones: ["KSZ009", "KSC201"])
        #expect(transport.requests[0].url?.absoluteString == "https://api.weather.gov/alerts/active?zone=KSZ009,KSC201")
        #expect(first.pollInterval == 60)
        #expect(first.alerts.count == 2)
        #expect(first.alerts[0].references == ["urn:oid:2.49.0.1.840.0.b1"])
        #expect(first.alerts[1].headline == nil)
        #expect(try await client.activeAlerts(zones: ["KSZ009"]).pollInterval == 300)
    }

    @Test func badZonesAndCoordinatesAreRejected() async throws {
        let client = makeClient(StubTransport([]))
        await #expect(throws: NWSError.invalidZone("KS&x=1")) { try await client.activeAlerts(zones: ["KS&x=1"]) }
        await #expect(throws: NWSError.invalidCoordinates) { try await client.point(lat: 91, lon: 0) }
        await #expect(throws: NWSError.invalidCoordinates) { try await client.point(lat: .nan, lon: 0) }
    }

    @Test func httpErrorsAreReportedWithoutBody() async throws {
        let client = makeClient(StubTransport([.init(status: 503, body: Data("secret".utf8))]))
        await #expect(throws: NWSError.http(503)) { try await client.point(lat: 39.74, lon: -97.09) }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval
    init(_ seconds: TimeInterval) { self.seconds = seconds }
    var date: Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
    func advance(_ by: TimeInterval) { lock.withLock { seconds += by } }
}
