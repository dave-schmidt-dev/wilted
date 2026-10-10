import Foundation

/// Decides which alerts in each poll are worth announcing. Ports the legacy rules from
/// `weather_monitor.py` at tag `legacy-python-app-2026-10-03`:
///
/// 1. An exact repeat of an alert already seen for the area is suppressed. NWS re-serves an
///    unchanged alert on every poll until it clears.
/// 2. A reissue of the same event is re-announced only when its severity is strictly higher
///    than the highest already announced for that event in the area.
/// 3. When a poll no longer contains any alert for an area, that area's state is dropped, so
///    a later alert there is judged fresh.
public struct AlertDeduper: Sendable {
    private struct AreaState: Sendable {
        var signatures: Set<String> = []
        /// Highest announced severity rank per event name.
        var announcedRank: [String: Int] = [:]
    }

    private var areas: [String: AreaState] = [:]

    public init() {}

    /// Severity rank, unknown or missing text counting as the lowest.
    public static func rank(_ severity: String) -> Int {
        switch severity.trimmingCharacters(in: .whitespaces).lowercased() {
        case "minor": 1
        case "moderate": 2
        case "severe": 3
        case "extreme": 4
        default: 0
        }
    }

    /// Feeds one poll's complete alert list and returns the alerts to announce, in input order.
    /// Cancel, Ack and Error messages are never announced and do not keep an area alive.
    public mutating func qualifying(_ alerts: [NWSAlert]) -> [NWSAlert] {
        var present: Set<String> = []
        var announce: [NWSAlert] = []
        for alert in alerts where Self.isAnnounceable(alert) {
            present.insert(alert.areaDesc)
            var state = areas[alert.areaDesc] ?? AreaState()
            defer { areas[alert.areaDesc] = state }
            guard state.signatures.insert(Self.signature(alert)).inserted else { continue }
            let rank = Self.rank(alert.severity)
            if let announced = state.announcedRank[alert.event], rank <= announced { continue }
            state.announcedRank[alert.event] = rank
            announce.append(alert)
        }
        areas = areas.filter { present.contains($0.key) }
        return announce
    }

    /// Forgets everything, for a location change.
    public mutating func reset() { areas = [:] }

    private static func isAnnounceable(_ alert: NWSAlert) -> Bool {
        !["cancel", "ack", "error"].contains(alert.messageType.lowercased())
    }

    private static func signature(_ alert: NWSAlert) -> String {
        [alert.id, alert.messageType, alert.severity, alert.event,
         alert.sent.map { String($0.timeIntervalSince1970) } ?? "", alert.headline ?? ""].joined(separator: "|")
    }
}
