import Foundation

/// Failures of the NWS client. None carries a response body.
public enum NWSError: Error, Equatable, Sendable {
    case invalidURL(String)
    case invalidCoordinates
    case invalidZone(String)
    case redirectRejected
    case notFound
    case http(Int)
    case bodyTooLarge
    case malformed(String)
    case transport(String)
}

/// Sends one prepared request. The default implementation is `URLSessionNWSTransport`; tests
/// inject a stub so no automated test reaches api.weather.gov.
public protocol NWSTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` transport that refuses every redirect and stops reading past the byte cap.
public struct URLSessionNWSTransport: NWSTransport {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse else { throw NWSError.transport("not an HTTP response") }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > maximumBytes {
            throw NWSError.bodyTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw NWSError.bodyTooLarge }
        }
        return (data, http)
    }
}

/// The URLs and zone codes `/points` resolves for a location.
public struct NWSPoint: Equatable, Sendable {
    public let forecastURL: URL
    public let forecastZone: String
    public let county: String
    public let fetchedAt: Date

    /// Zone codes for `activeAlerts(zones:)`: forecast zone first, then county.
    public var zones: [String] { [forecastZone, county] }
}

public struct NWSForecastPeriod: Equatable, Sendable {
    public let name: String
    public let temperature: Int?
    public let temperatureUnit: String?
    public let shortForecast: String
    public let detailedForecast: String
    public let isDaytime: Bool
}

public struct NWSAlert: Equatable, Sendable {
    public let id: String
    public let event: String
    public let areaDesc: String
    public let severity: String
    public let messageType: String
    public let headline: String?
    public let sent: Date?
    public let expires: Date?
    public let ends: Date?
    /// Identifiers of earlier alerts this one replaces (`references[].identifier`).
    public let references: [String]

    public init(id: String, event: String, areaDesc: String, severity: String, messageType: String = "Alert",
                headline: String? = nil, sent: Date? = nil, expires: Date? = nil, ends: Date? = nil,
                references: [String] = []) {
        self.id = id
        self.event = event
        self.areaDesc = areaDesc
        self.severity = severity
        self.messageType = messageType
        self.headline = headline
        self.sent = sent
        self.expires = expires
        self.ends = ends
        self.references = references
    }
}

public struct NWSAlertsResponse: Equatable, Sendable {
    public let alerts: [NWSAlert]
    /// The longer of 60 s and the response's Cache-Control max-age.
    public let pollInterval: TimeInterval
}

/// Client for api.weather.gov. Facts (zone as a comma list of forecast and county codes, no
/// other query parameters, `/points` cacheable 24 h, observed alerts max-age 5 s) come from
/// `.logs/b6-2026-10-10-b64/b64-api-facts.json` items 3 to 5.
public actor NWSClient {
    public static let host = "api.weather.gov"
    public static let minimumPollInterval: TimeInterval = 60
    public static let pointRevalidationInterval: TimeInterval = 24 * 3600
    public static let maximumBodyBytes = 1_048_576

    private let transport: any NWSTransport
    private let userAgent: String
    private let now: @Sendable () -> Date
    private var points: [String: NWSPoint] = [:]

    /// - Parameters:
    ///   - appVersion: marketing version for the User-Agent.
    ///   - repositoryURL: project URL for the User-Agent.
    ///   - contact: the optional Settings contact; appended only when it has visible text.
    public init(transport: any NWSTransport = URLSessionNWSTransport(), appVersion: String, repositoryURL: String,
                contact: String? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.userAgent = Self.userAgent(appVersion: appVersion, repositoryURL: repositoryURL, contact: contact)
        self.now = now
    }

    nonisolated static func userAgent(appVersion: String, repositoryURL: String, contact: String?) -> String {
        func clean(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
                .trimmingCharacters(in: .whitespaces)
        }
        var agent = "Wilted/\(clean(appVersion)) (\(clean(repositoryURL)))"
        if let contact = contact.map(clean), !contact.isEmpty { agent += " \(contact)" }
        return agent
    }

    /// Coordinates rounded to 2 decimals; the API accepts at most 4 (facts item 4).
    nonisolated static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 + 0 }

    // MARK: Public calls

    /// Forecast URL, forecast zone and county for a location. Served from memory for 24 h.
    public func point(lat: Double, lon: Double) async throws -> NWSPoint {
        let key = try Self.key(lat: lat, lon: lon)
        if let cached = points[key], now().timeIntervalSince(cached.fetchedAt) < Self.pointRevalidationInterval {
            return cached
        }
        return try await fetchPoint(key: key)
    }

    public func forecast(url: URL) async throws -> [NWSForecastPeriod] {
        let (data, _) = try await get(url)
        return try Self.decodeForecast(data)
    }

    /// Active alerts for forecast-zone and county codes in one request.
    public func activeAlerts(zones: [String]) async throws -> NWSAlertsResponse {
        guard !zones.isEmpty else { throw NWSError.invalidZone("") }
        for zone in zones where zone.range(of: #"^[A-Z]{2}[CZ][0-9]{3}$"#, options: .regularExpression) == nil {
            throw NWSError.invalidZone(zone)
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = "/alerts/active"
        components.percentEncodedQuery = "zone=" + zones.joined(separator: ",")
        guard let url = components.url else { throw NWSError.invalidURL("alerts") }
        let (data, response) = try await get(url)
        let maxAge = Self.maxAge(from: response.value(forHTTPHeaderField: "Cache-Control"))
        return NWSAlertsResponse(alerts: try Self.decodeAlerts(data),
                                 pollInterval: max(Self.minimumPollInterval, maxAge))
    }

    /// Forecast for a location. A 404 means the office or grid mapping moved, so the point is
    /// looked up again once before giving up.
    public func forecast(lat: Double, lon: Double) async throws -> [NWSForecastPeriod] {
        try await withRepoint(lat: lat, lon: lon) { try await self.forecast(url: $0.forecastURL) }
    }

    /// Active alerts for a location, with the same one-time re-lookup on 404.
    public func activeAlerts(lat: Double, lon: Double) async throws -> NWSAlertsResponse {
        try await withRepoint(lat: lat, lon: lon) { try await self.activeAlerts(zones: $0.zones) }
    }

    // MARK: Internals

    private func withRepoint<T: Sendable>(lat: Double, lon: Double,
                                          _ body: (NWSPoint) async throws -> T) async throws -> T {
        let current = try await point(lat: lat, lon: lon)
        do {
            return try await body(current)
        } catch NWSError.notFound {
            points[try Self.key(lat: lat, lon: lon)] = nil
            return try await body(try await point(lat: lat, lon: lon))
        }
    }

    private static func key(lat: Double, lon: Double) throws -> String {
        guard lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else {
            throw NWSError.invalidCoordinates
        }
        return String(format: "%.2f,%.2f", rounded(lat), rounded(lon))
    }

    private func fetchPoint(key: String) async throws -> NWSPoint {
        guard let url = URL(string: "https://\(Self.host)/points/\(key)") else { throw NWSError.invalidURL("points") }
        let (data, _) = try await get(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = root["properties"] as? [String: Any],
              let forecast = (properties["forecast"] as? String).flatMap(URL.init(string:)),
              let zone = (properties["forecastZone"] as? String).flatMap(Self.lastSegment),
              let county = (properties["county"] as? String).flatMap(Self.lastSegment)
        else { throw NWSError.malformed("points") }
        try Self.validate(forecast)
        let point = NWSPoint(forecastURL: forecast, forecastZone: zone, county: county, fetchedAt: now())
        points[key] = point
        return point
    }

    private static func lastSegment(_ text: String) -> String? {
        guard let last = URL(string: text)?.lastPathComponent, !last.isEmpty, last != "/" else { return nil }
        return last
    }

    /// HTTPS, host api.weather.gov, no credentials or custom port.
    private static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == host,
              url.user == nil, url.password == nil, url.port == nil else {
            throw NWSError.invalidURL(url.host ?? "")
        }
    }

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try Self.validate(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request, maximumBytes: Self.maximumBodyBytes)
        } catch let error as NWSError {
            throw error
        } catch {
            throw NWSError.transport(String(describing: type(of: error)))
        }
        switch response.statusCode {
        case 200..<300: break
        case 300..<400: throw NWSError.redirectRejected
        case 404: throw NWSError.notFound
        default: throw NWSError.http(response.statusCode)
        }
        if let finalURL = response.url, (try? Self.validate(finalURL)) == nil { throw NWSError.redirectRejected }
        guard data.count <= Self.maximumBodyBytes else { throw NWSError.bodyTooLarge }
        return (data, response)
    }

    /// `max-age` (or `s-maxage`) seconds, 0 when absent.
    nonisolated static func maxAge(from header: String?) -> TimeInterval {
        guard let header else { return 0 }
        var best: TimeInterval = 0
        for part in header.split(separator: ",") {
            let pair = part.trimmingCharacters(in: .whitespaces).lowercased().split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == "max-age" || pair[0] == "s-maxage", let seconds = TimeInterval(pair[1]) {
                best = max(best, seconds)
            }
        }
        return best
    }

    private static func decodeForecast(_ data: Data) throws -> [NWSForecastPeriod] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let periods = (root["properties"] as? [String: Any])?["periods"] as? [[String: Any]]
        else { throw NWSError.malformed("forecast") }
        return periods.compactMap { period in
            guard let name = period["name"] as? String else { return nil }
            return NWSForecastPeriod(
                name: name, temperature: period["temperature"] as? Int,
                temperatureUnit: period["temperatureUnit"] as? String,
                shortForecast: period["shortForecast"] as? String ?? "",
                detailedForecast: period["detailedForecast"] as? String ?? "",
                isDaytime: period["isDaytime"] as? Bool ?? true)
        }
    }

    private static func decodeAlerts(_ data: Data) throws -> [NWSAlert] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw NWSError.malformed("alerts") }
        let formatter = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? { (value as? String).flatMap { formatter.date(from: $0) } }
        return features.compactMap { feature in
            guard let props = feature["properties"] as? [String: Any],
                  let id = (props["id"] as? String) ?? (feature["id"] as? String),
                  let event = props["event"] as? String else { return nil }
            let references = (props["references"] as? [[String: Any]])?.compactMap { $0["identifier"] as? String } ?? []
            return NWSAlert(
                id: id, event: event, areaDesc: props["areaDesc"] as? String ?? "",
                severity: props["severity"] as? String ?? "Unknown",
                messageType: props["messageType"] as? String ?? "Alert",
                headline: props["headline"] as? String, sent: date(props["sent"]),
                expires: date(props["expires"]), ends: date(props["ends"]), references: references)
        }
    }
}
