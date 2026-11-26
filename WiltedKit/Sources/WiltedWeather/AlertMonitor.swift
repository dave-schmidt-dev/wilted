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
    /// Leaves ample time below the producer's 15-minute clip ceiling, even at slow narration rates.
    private static let maximumSpokenAlertUTF8Bytes = 2_000

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
        guard started, let location = coordinates else { return NWSClient.minimumPollInterval }
        let token = generation
        do {
            let response = try await source.activeAlerts(lat: location.lat, lon: location.lon)
            // Stopping, restarting or moving the monitor bumps the generation; a poll that began
            // under an earlier one must not update state or deliver.
            guard token == generation, started, coordinates?.lat == location.lat, coordinates?.lon == location.lon else {
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
            guard token == generation, started else { return NWSClient.minimumPollInterval }
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
        // `ends` is the hazard's forecast end; `expires` controls how long the CAP alert itself
        // remains active. Delivery eligibility uses the earlier known boundary so a hazard that
        // already ended is not announced even when the bulletin expires later.
        [alert.ends, alert.expires].compactMap { $0 }.min()
            ?? issuedAt.addingTimeInterval(defaultAlertLifetime)
    }

    /// Converts an eligible alert into the same plain bulletin used for local narration.
    /// Updates remain eligible and retain their `references` relation. Cancel, Ack, Error and
    /// expired alerts are excluded so a remote request cannot revive withdrawn content.
    public static func bulletin(for alert: NWSAlert, now: Date) -> Bulletin? {
        guard !["cancel", "ack", "error"].contains(alert.messageType.lowercased()),
              expiry(of: alert, issuedAt: now) > now else { return nil }
        let issued = alert.sent ?? now
        let text = spokenText(for: alert)
        let originalText = originalText(for: alert)
        return try? Bulletin(
            id: alert.id, kind: .alert, text: text,
            severity: BulletinSeverity(rawValue: alert.severity.lowercased()) ?? .unknown,
            issuedAt: issued, expiresAt: expiry(of: alert, issuedAt: now), supersedes: alert.references.first,
            link: NWSClient.publicAlertURL(for: alert.id), originalText: originalText)
    }

    /// Builds one locale-independent narration from NWS fields and preserves every official
    /// instruction verbatim when it fits the narration bound. Longer notices are announced whole
    /// with a link to the uncut original; they are never clipped mid-instruction.
    private static func spokenText(for alert: NWSAlert) -> String {
        let event = alert.event.trimmingCharacters(in: .whitespacesAndNewlines)
        let severity = alert.severity.trimmingCharacters(in: .whitespacesAndNewlines)
        let area = alert.areaDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        let timing = timingText(for: alert)
        var title = severityAndEvent(severity, event)

        if event.isEmpty, timing.isEmpty,
           let headline = alert.headline?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty {
            title = startsWithSeverity(headline, severity: severity) ? headline : severityAndEvent(severity, headline)
        }
        if !area.isEmpty, !title.contains(area) {
            title += " for \(area)"
        }
        if timing.isEmpty {
            title += "."
        } else {
            title += ". \(timing)"
        }

        let directions = [alert.instruction, alert.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let directions else {
            if fitsSpokenAlert(title) { return title }
            return boundedAnnouncement(title, alert: alert, mentionInstructions: false)
        }
        let full = "\(title)\n\(directions)"
        guard fitsSpokenAlert(full) else {
            return boundedAnnouncement(title, alert: alert)
        }
        return full
    }

    private static func severityAndEvent(_ severity: String, _ event: String) -> String {
        guard !severity.isEmpty, severity.lowercased() != "unknown",
              !startsWithSeverity(event, severity: severity) else { return event }
        return "\(severity) \(event)"
    }

    private static func startsWithSeverity(_ text: String, severity: String) -> Bool {
        guard !severity.isEmpty, severity.lowercased() != "unknown" else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let severity = severity.lowercased()
        return text == severity || text.hasPrefix(severity + " ")
    }

    private static func fitsSpokenAlert(_ text: String) -> Bool {
        text.count <= maximumSpokenAlertUTF8Bytes
            && text.utf8.count <= maximumSpokenAlertUTF8Bytes
            && text.count <= Bulletin.maximumTextCharacters
            && text.utf8.count <= Bulletin.maximumTextUTF8Bytes
    }

    private static func boundedAnnouncement(
        _ title: String, alert: NWSAlert, mentionInstructions: Bool = true
    ) -> String {
        let notice = mentionInstructions
            ? "The full official safety instructions are in the original NWS alert."
            : "Open the original NWS alert for the affected area and timing."
        let full = fitsSpokenAlert(title)
            ? (mentionInstructions ? "\(title) \(notice)" : title)
            : "\(title) \(notice)"
        if fitsSpokenAlert(full) {
            return full
        }
        let event = alert.event.trimmingCharacters(in: .whitespacesAndNewlines)
        let severity = alert.severity.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortTitle = severityAndEvent(severity, event)
        let fallback = mentionInstructions
            ? "Open the original NWS alert for the affected area, timing, and safety instructions."
            : "Open the original NWS alert for the affected area and timing."
        let safe = "\(shortTitle). \(fallback)"
        if fitsSpokenAlert(safe) { return safe }
        let minimal = "\(severityAndEvent(severity, event)). Open the original NWS alert."
        return fitsSpokenAlert(minimal)
            ? minimal
            : "A weather alert is active. Open the original NWS alert."
    }

    private static func originalText(for alert: NWSAlert) -> String? {
        var lines = [
            "Event: \(alert.event)",
            "Severity: \(alert.severity)",
            "Urgency: \(alert.urgency ?? "Not supplied")",
            "Certainty: \(alert.certainty ?? "Not supplied")",
            "Message type: \(alert.messageType)",
            "Affected areas: \(alert.areaDesc.isEmpty ? "Not supplied" : alert.areaDesc)"
        ]
        let times: [(String, String?, Date?)] = [
            ("Sent", alert.rawSent, alert.sent),
            ("Effective", alert.rawEffective, alert.effective),
            ("Hazard starts", alert.rawOnset, alert.onset),
            ("Hazard ends", alert.rawEnds, alert.ends),
            ("Alert expires", alert.rawExpires, alert.expires)
        ]
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        for (label, raw, date) in times {
            if let raw {
                lines.append("\(label) (CAP): \(raw)")
            } else if let date {
                lines.append("\(label) (UTC): \(isoFormatter.string(from: date))")
            }
        }
        for (label, value) in [("Headline", alert.headline), ("Description", alert.description),
                               ("Official instructions", alert.instruction)] {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                lines.append("\(label):\n\(value)")
            }
        }
        let original = lines.joined(separator: "\n\n")
        guard original.count <= Bulletin.maximumOriginalTextCharacters,
              original.utf8.count <= Bulletin.maximumOriginalTextUTF8Bytes else { return nil }
        return original
    }

    private static func timingText(for alert: NWSAlert) -> String {
        let sourceZone = officialHeadlineTimeZone(for: alert)
        let zoneOffset = sourceZone?.offset ?? 0
        let zoneName = sourceZone?.abbreviation ?? "UTC"
        let timeZone = TimeZone(secondsFromGMT: zoneOffset) ?? TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let years = [alert.sent, alert.effective, alert.onset, alert.ends, alert.expires]
            .compactMap { $0 }.map { calendar.component(.year, from: $0) }
        let includeYear = Set(years).count > 1
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = includeYear
            ? "EEEE, MMMM d, yyyy 'at' h:mm a"
            : "EEEE, MMMM d 'at' h:mm a"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "h:mm a"

        func spokenDate(_ date: Date, relativeTo reference: Date? = nil) -> String {
            let value = if let reference, calendar.isDate(date, inSameDayAs: reference) {
                timeFormatter.string(from: date)
            } else {
                dateFormatter.string(from: date)
            }
            return "\(value) \(zoneName)"
        }

        var phrases: [String] = []
        if let onset = alert.onset, let ends = alert.ends {
            let start = spokenDate(onset)
            let finish = spokenDate(ends, relativeTo: onset)
            if alert.effective == onset, alert.expires == ends {
                phrases.append("The alert and hazard are in effect from \(start) until \(finish).")
            } else if alert.effective == onset {
                phrases.append("The alert and hazard begin \(start). The hazard is expected until \(finish).")
            } else {
                phrases.append("The hazard is expected from \(start) until \(finish).")
            }
        } else if let onset = alert.onset {
            if alert.effective == onset {
                phrases.append("The alert and hazard begin \(spokenDate(onset)).")
            } else {
                phrases.append("The hazard starts \(spokenDate(onset)).")
            }
        } else if let ends = alert.ends {
            phrases.append("The hazard is expected to end \(spokenDate(ends)).")
        }

        if let effective = alert.effective, effective != alert.onset,
           alert.onset != nil || effective != alert.sent {
            let reference = alert.onset ?? alert.ends
            let relation: String
            if let reference, effective < reference {
                relation = "earlier, at \(spokenDate(effective, relativeTo: reference))"
            } else if let reference, effective > reference {
                relation = "later, at \(spokenDate(effective, relativeTo: reference))"
            } else {
                relation = "at \(spokenDate(effective))"
            }
            phrases.append("The alert takes effect \(relation).")
        }

        if let expires = alert.expires {
            if let ends = alert.ends, expires < ends {
                phrases.append("The alert expires at \(spokenDate(expires, relativeTo: ends)), before the hazard ends.")
            } else if alert.ends == nil {
                phrases.append("The alert expires \(spokenDate(expires, relativeTo: alert.onset)).")
            }
        }

        return phrases.joined(separator: " ")
    }

    /// Uses the headline's local zone only when its NWS shape and CAP offsets agree.
    private static func officialHeadlineTimeZone(for alert: NWSAlert) -> (abbreviation: String, offset: Int)? {
        let offsets: [String: Int] = [
            "UTC": 0, "GMT": 0,
            "HST": -10 * 3_600, "HDT": -9 * 3_600,
            "AKST": -9 * 3_600, "AKDT": -8 * 3_600,
            "PST": -8 * 3_600, "PDT": -7 * 3_600,
            "MST": -7 * 3_600, "MDT": -6 * 3_600,
            "CST": -6 * 3_600, "CDT": -5 * 3_600,
            "EST": -5 * 3_600, "EDT": -4 * 3_600,
            "AST": -4 * 3_600, "ADT": -3 * 3_600,
            "SST": -11 * 3_600, "CHST": 10 * 3_600
        ]
        guard let headline = alert.headline,
              !alert.event.isEmpty,
              let expression = try? NSRegularExpression(
                pattern: "^\(NSRegularExpression.escapedPattern(for: alert.event)) issued .+ ([A-Z]{2,5}) until .+ ([A-Z]{2,5}) by NWS .+$"),
              let match = expression.firstMatch(in: headline, range: NSRange(headline.startIndex..., in: headline)),
              let firstRange = Range(match.range(at: 1), in: headline),
              let secondRange = Range(match.range(at: 2), in: headline) else { return nil }
        let firstZone = String(headline[firstRange])
        let secondZone = String(headline[secondRange])
        guard firstZone == secondZone, let offset = offsets[firstZone] else { return nil }

        let timestamps: [(Date?, String?)] = [
            (alert.sent, alert.rawSent), (alert.effective, alert.rawEffective),
            (alert.onset, alert.rawOnset), (alert.ends, alert.rawEnds),
            (alert.expires, alert.rawExpires)
        ]
        for (date, raw) in timestamps where date != nil {
            if let raw {
                guard let actualOffset = explicitUTCOffset(raw), actualOffset == offset else { return nil }
            }
        }
        return (firstZone, offset)
    }

    private static func explicitUTCOffset(_ rawTimestamp: String) -> Int? {
        if rawTimestamp.hasSuffix("Z") { return 0 }
        guard let expression = try? NSRegularExpression(pattern: #"([+-])(\d{2}):(\d{2})$"#),
              let match = expression.firstMatch(
                in: rawTimestamp, range: NSRange(rawTimestamp.startIndex..., in: rawTimestamp)),
              let signRange = Range(match.range(at: 1), in: rawTimestamp),
              let hourRange = Range(match.range(at: 2), in: rawTimestamp),
              let minuteRange = Range(match.range(at: 3), in: rawTimestamp),
              let hours = Int(rawTimestamp[hourRange]), let minutes = Int(rawTimestamp[minuteRange]),
              hours <= 23, minutes <= 59 else { return nil }
        let sign = rawTimestamp[signRange] == "+" ? 1 : -1
        return sign * (hours * 3_600 + minutes * 60)
    }
}
