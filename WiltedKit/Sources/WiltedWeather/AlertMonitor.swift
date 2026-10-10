import Foundation
import WiltedLibrary

/// Where the monitor gets alerts. `NWSClient` is the production source.
public protocol NWSAlertSource: Sendable {
    func activeAlerts(lat: Double, lon: Double) async throws -> NWSAlertsResponse
}

extension NWSClient: NWSAlertSource {}

public struct AlertMonitorStatus: Equatable, Sendable {
    public var lastPollAt: Date?
    public var lastError: String?
    public var consecutiveFailures = 0
}

/// Polls active alerts for the coordinates it is given while started, filters them through
/// `AlertDeduper` and hands alert `Bulletin`s to its owner. Each device runs its own monitor
/// for its own location. It makes no request while stopped or without coordinates.
public actor AlertMonitor {
    public static let defaultAlertLifetime: TimeInterval = 3600
    public static let maximumBackoff: TimeInterval = 900

    private let source: any NWSAlertSource
    private let deliver: @Sendable (Bulletin) -> Void
    private let onStatus: @Sendable (AlertMonitorStatus) -> Void
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    private var coordinates: (lat: Double, lon: Double)?
    private var started = false
    private var task: Task<Void, Never>?
    private var generation = 0
    private var deduper = AlertDeduper()
    private var current: Set<String> = []
    public private(set) var status = AlertMonitorStatus()

    /// - Parameters:
    ///   - deliver: receives each new alert bulletin, in order.
    ///   - onStatus: reports every poll outcome so the owner can show monitor health.
    public init(source: any NWSAlertSource,
                deliver: @escaping @Sendable (Bulletin) -> Void,
                onStatus: @escaping @Sendable (AlertMonitorStatus) -> Void = { _ in },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.deliver = deliver
        self.onStatus = onStatus
        self.sleep = sleep
        self.now = now
    }

    /// Ids of unexpired alerts in the latest successful poll, for the owner's `channelReplaced`.
    public var activeAlertIDs: Set<String> { current }

    public func start() {
        started = true
        reconcile()
    }

    public func stop() {
        started = false
        reconcile()
    }

    /// Sets or clears the location. A different location forgets dedup state and polls again.
    public func setCoordinates(lat: Double, lon: Double) {
        if let coordinates, coordinates.lat == lat, coordinates.lon == lon { return }
        coordinates = (lat, lon)
        deduper.reset()
        current = []
        reconcile()
    }

    public func clearCoordinates() {
        coordinates = nil
        deduper.reset()
        current = []
        reconcile()
    }

    /// One poll now, for the owner and tests. Returns the interval to wait before the next.
    @discardableResult
    public func pollOnce() async -> TimeInterval {
        guard let location = coordinates else { return NWSClient.minimumPollInterval }
        let token = generation
        do {
            let response = try await source.activeAlerts(lat: location.lat, lon: location.lon)
            // Stopping, restarting or moving the monitor bumps the generation; a poll that began
            // under an earlier one must not update state or deliver.
            guard token == generation, coordinates?.lat == location.lat, coordinates?.lon == location.lon else {
                return NWSClient.minimumPollInterval
            }
            let at = now()
            status = AlertMonitorStatus(lastPollAt: at, lastError: nil, consecutiveFailures: 0)
            onStatus(status)
            let live = response.alerts.filter { Self.expiry(of: $0, issuedAt: at) > at }
            current = Set(live.filter { !["cancel", "ack", "error"].contains($0.messageType.lowercased()) }.map(\.id))
            for alert in deduper.qualifying(live) {
                if let bulletin = Self.bulletin(for: alert, now: at) { deliver(bulletin) }
            }
            return response.pollInterval
        } catch {
            guard token == generation else { return NWSClient.minimumPollInterval }
            status.lastPollAt = now()
            status.lastError = (error as? NWSError).map { String(describing: $0) } ?? String(describing: type(of: error))
            status.consecutiveFailures += 1
            onStatus(status)
            let backoff = NWSClient.minimumPollInterval * pow(2, Double(min(status.consecutiveFailures - 1, 4)))
            return min(backoff, Self.maximumBackoff)
        }
    }

    private func reconcile() {
        task?.cancel()
        task = nil
        generation += 1
        guard started, coordinates != nil else { return }
        let mine = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let interval = await self.pollIfCurrent(mine) else { return }
                do { try await self.sleep(interval) } catch { return }
            }
        }
    }

    private func pollIfCurrent(_ token: Int) async -> TimeInterval? {
        guard token == generation, started else { return nil }
        return await pollOnce()
    }

    private static func expiry(of alert: NWSAlert, issuedAt: Date) -> Date {
        alert.ends ?? alert.expires ?? issuedAt.addingTimeInterval(defaultAlertLifetime)
    }

    static func bulletin(for alert: NWSAlert, now: Date) -> Bulletin? {
        let issued = alert.sent ?? now
        let area = alert.areaDesc.isEmpty ? "" : " for \(alert.areaDesc)"
        var text = alert.headline.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? "\(alert.event)\(area)."
        if text.count > Bulletin.maximumTextCharacters { text = String(text.prefix(Bulletin.maximumTextCharacters)) }
        return try? Bulletin(
            id: alert.id, kind: .alert, text: text,
            severity: BulletinSeverity(rawValue: alert.severity.lowercased()) ?? .unknown,
            issuedAt: issued, expiresAt: expiry(of: alert, issuedAt: now), supersedes: alert.references.first)
    }
}
