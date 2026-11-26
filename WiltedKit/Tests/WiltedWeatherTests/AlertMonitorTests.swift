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

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
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

    @Test func pollOnceOnANeverStartedOrStoppedMonitorDeliversNothing() async throws {
        let source = StubSource([response([warning("a1")])])
        let sink = Collector()
        let statuses = Counter()
        let monitor = AlertMonitor(source: source, deliver: { sink.add($0) }, onStatus: { _ in statuses.bump() },
                                   sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, now: { nowDate })
        await monitor.setCoordinates(lat: 39.74, lon: -97.09)
        await monitor.pollOnce()
        #expect(source.callCount == 0)
        await monitor.start()
        try await waitForFirstPoll(monitor)
        await monitor.stop()
        let before = await monitor.status
        let delivered = sink.bulletins.count
        let statusReports = statuses.value
        let requests = source.callCount
        await monitor.pollOnce()
        #expect(source.callCount == requests)
        #expect(sink.bulletins.count == delivered)
        #expect(statuses.value == statusReports)
        #expect(await monitor.status == before)
    }

    @Test func pollEmitsAlertBulletinsOnceAndDedupes() async throws {
        let sink = Collector()
        let source = StubSource([response([warning("a1")])])
        let monitor = monitor(source, sink)
        await monitor.setCoordinates(lat: 39.74, lon: -97.09)
        await monitor.start()
        try await waitForFirstPoll(monitor)
        await monitor.pollOnce()
        let bulletin = try #require(sink.bulletins.first)
        #expect(sink.bulletins.count == 1)
        #expect(bulletin.kind == .alert)
        #expect(bulletin.id == "a1")
        #expect(bulletin.severity == .severe)
        #expect(bulletin.text == "Severe Tornado Warning for Washington. The alert expires Monday, January 12 at 2:16 PM UTC.")
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
        await monitor.start()
        try await waitForFirstPoll(monitor)
        #expect(sink.bulletins.map(\.id) == ["a2"])
        #expect(sink.bulletins.first?.supersedes == "a1")
        #expect(sink.bulletins.first?.text == "Extreme Tornado Warning for Washington. The alert expires Monday, January 12 at 1:56 PM UTC.")
    }

    @Test func sharedBulletinConversionKeepsPlainNarrationAndRejectsWithdrawnAlerts() throws {
        let initial = try #require(AlertMonitor.bulletin(for: warning("a1"), now: nowDate))
        #expect(initial.text == "Severe Tornado Warning for Washington. The alert expires Monday, January 12 at 2:16 PM UTC.")

        let update = NWSAlert(
            id: "a2", event: "Tornado Warning", areaDesc: "Washington", severity: "Extreme",
            messageType: "Update", headline: nil, sent: nowDate,
            expires: nowDate.addingTimeInterval(600), references: ["a1"])
        let updated = try #require(AlertMonitor.bulletin(for: update, now: nowDate))
        #expect(updated.text == "Extreme Tornado Warning for Washington. The alert expires Monday, January 12 at 1:56 PM UTC.")
        #expect(updated.supersedes == "a1")

        for messageType in ["Cancel", "Ack", "Error"] {
            let withdrawn = NWSAlert(
                id: "withdrawn-\(messageType)", event: "Tornado Warning", areaDesc: "Washington",
                severity: "Severe", messageType: messageType, headline: "Do not narrate",
                sent: nowDate, expires: nowDate.addingTimeInterval(600))
            #expect(AlertMonitor.bulletin(for: withdrawn, now: nowDate) == nil)
        }
        #expect(AlertMonitor.bulletin(for: warning("expired", expiresIn: -1), now: nowDate) == nil)
    }

    @Test func alertUsesCAPTimesAndAvoidsRepeatingTheHeadline() throws {
        let alert = NWSAlert(
            id: "urn:oid:2.49.0.1.840.0.12345", event: "Special Marine Warning",
            areaDesc: "Hawk Channel from Ocean Reef to Craig Key out to the reef; Straits of Florida from Ocean Reef to Craig Key out 20 NM",
            severity: "Severe", messageType: "Update",
            headline: "Special Marine Warning issued November 25 at 9:25PM EST until November 25 at 10:00PM EST by NWS Key West FL",
            urgency: "Immediate", certainty: "Likely",
            description: "Hazard details retained in the source.",
            instruction: "Stay low or go below, and make sure all on board are wearing life jackets.\nIf caught on the open water, stay low or go below.",
            sent: iso("2026-11-25T20:00:00-05:00"),
            effective: iso("2026-11-25T21:20:00-05:00"), onset: iso("2026-11-25T21:25:00-05:00"),
            expires: iso("2026-11-25T22:05:00-05:00"), ends: iso("2026-11-25T22:00:00-05:00"))

        let first = try #require(AlertMonitor.bulletin(for: alert, now: nowDate))
        let later = try #require(AlertMonitor.bulletin(for: alert, now: nowDate.addingTimeInterval(10)))

        #expect(first.text == """
        Severe Special Marine Warning for Hawk Channel from Ocean Reef to Craig Key out to the reef; Straits of Florida from Ocean Reef to Craig Key out 20 NM. The hazard is expected from Wednesday, November 25 at 9:25 PM EST until 10:00 PM EST. The alert takes effect earlier, at 9:20 PM EST.
        Stay low or go below, and make sure all on board are wearing life jackets.
        If caught on the open water, stay low or go below.
        """)
        #expect(first.text.utf8.elementsEqual(later.text.utf8))
        #expect(first.originalText?.contains(alert.headline!) == true)
        #expect(first.originalText?.contains("Hazard details retained in the source.") == true)
        #expect(first.originalText?.contains("Affected areas: \(alert.areaDesc)") == true)
        #expect(first.originalText?.contains("Severity: Severe") == true)
        #expect(first.originalText?.contains("Effective (UTC): 2026-11-26T02:20:00Z") == true)
        #expect(first.originalText?.contains("Hazard starts (UTC): 2026-11-26T02:25:00Z") == true)
        #expect(first.link?.host == "api.weather.gov")
        #expect(!first.text.contains("issued November"), "the source headline stays in the original, not the spoken copy")
        #expect(!first.text.contains("20:00"), "sent time is not the event start")
    }

    @Test func publicWindAndMarineExamplesHaveFriendlyGoldenSpeechAndFullOriginals() throws {
        let windInstruction = "Consider postponing travel to the summits until conditions improve.\nIf you must travel to the summits, use extra caution walking and\ndriving. Be careful opening or closing doors."
        let windDescription = "* WHAT...West winds 35 to 45 mph with gusts up to 60 mph expected.\n\n* WHERE...Haleakala Summit.\n\n* WHEN...Until 3 PM HST Thursday.\n\n* IMPACTS...Winds this strong can make driving and walking dangerous.\nThe winds can forcefully open doors and damage hinges or slam doors\nshut, possibly causing injuries."
        let wind = NWSAlert(
            id: "wind-advisory-sample", event: "Wind Advisory", areaDesc: "Haleakala Summit",
            severity: "Moderate", messageType: "Update",
            headline: "Wind Advisory issued November 25 at 4:15PM HST until November 26 at 3:00PM HST by NWS Honolulu HI",
            urgency: "Expected", certainty: "Likely", description: windDescription, instruction: windInstruction,
            sent: iso("2026-11-25T16:15:00-10:00"), effective: iso("2026-11-25T16:15:00-10:00"),
            onset: iso("2026-11-25T18:00:00-10:00"), expires: iso("2026-11-26T05:15:00-10:00"),
            ends: iso("2026-11-26T15:00:00-10:00"), rawSent: "2026-11-25T16:15:00-10:00",
            rawEffective: "2026-11-25T16:15:00-10:00", rawOnset: "2026-11-25T18:00:00-10:00",
            rawExpires: "2026-11-26T05:15:00-10:00", rawEnds: "2026-11-26T15:00:00-10:00")
        let windBulletin = try #require(AlertMonitor.bulletin(for: wind, now: nowDate))

        #expect(windBulletin.text == """
        Moderate Wind Advisory for Haleakala Summit. The hazard is expected from Wednesday, November 25 at 6:00 PM HST until Thursday, November 26 at 3:00 PM HST. The alert takes effect earlier, at 4:15 PM HST. The alert expires at 5:15 AM HST, before the hazard ends.
        \(windInstruction)
        """)
        #expect(windBulletin.originalText?.contains("Effective (CAP): 2026-11-25T16:15:00-10:00") == true)
        #expect(windBulletin.originalText?.contains("Alert expires (CAP): 2026-11-26T05:15:00-10:00") == true)
        #expect(windBulletin.originalText?.contains(windDescription) == true)

        let marineInstruction = "Prepare for wind gusts in excess of 34 knots, steep and fast-building\nseas, frequent lightning strikes, and blinding downpours. Stay low or\ngo below, and make sure all on board are wearing life jackets.\n\nIntense and continuous lightning is occurring with this storm. If\ncaught on the open water, stay low or go below."
        let marineDescription = "For the following areas...\nHawk Channel and Straits of Florida from Ocean Reef to Craig Key out\n20 nm...\n\nAt 925 PM EST, a strong thunderstorm was located near Conch Reef,\nmoving northeast at 35 knots.\n\nHAZARD...Wind gusts 34 knots or greater.\n\nSOURCE...Radar indicated.\n\nIMPACT...Expect wind gusts in excess of 34 knots, suddenly higher\nwaves, frequent lightning, and heavy downpours.\n\nLocations in the warning include...\nKey Largo Dry Rocks, Mosquito Bank Light, French Ref, Spiegel Grove,\nGrecian Rocks, Conch Reef, and The Elbow Light."
        let marine = NWSAlert(
            id: "marine-warning-sample", event: "Special Marine Warning",
            areaDesc: "Hawk Channel from Ocean Reef to Craig Key out to the reef; Straits of Florida from Ocean Reef to Craig Key out 20 NM",
            severity: "Severe", messageType: "Update",
            headline: "Special Marine Warning issued November 25 at 9:25PM EST until November 25 at 10:00PM EST by NWS Key West FL",
            urgency: "Immediate", certainty: "Likely", description: marineDescription, instruction: marineInstruction,
            sent: iso("2026-11-25T21:25:00-05:00"), effective: iso("2026-11-25T21:25:00-05:00"),
            onset: iso("2026-11-25T21:25:00-05:00"), expires: iso("2026-11-25T22:00:00-05:00"),
            ends: iso("2026-11-25T22:00:00-05:00"), rawSent: "2026-11-25T21:25:00-05:00",
            rawEffective: "2026-11-25T21:25:00-05:00", rawOnset: "2026-11-25T21:25:00-05:00",
            rawExpires: "2026-11-25T22:00:00-05:00", rawEnds: "2026-11-25T22:00:00-05:00")
        let marineBulletin = try #require(AlertMonitor.bulletin(for: marine, now: nowDate))

        #expect(marineBulletin.text == """
        Severe Special Marine Warning for Hawk Channel from Ocean Reef to Craig Key out to the reef; Straits of Florida from Ocean Reef to Craig Key out 20 NM. The alert and hazard are in effect from Wednesday, November 25 at 9:25 PM EST until 10:00 PM EST.
        \(marineInstruction)
        """)
        #expect(marineBulletin.originalText?.contains("Affected areas: \(marine.areaDesc)") == true)
        #expect(marineBulletin.originalText?.contains("Hazard ends (CAP): 2026-11-25T22:00:00-05:00") == true)
        #expect(marineBulletin.originalText?.contains(marineDescription) == true)
        #expect(!marineBulletin.text.contains("Severe Severe"))
    }

    @Test func descriptionIsSpokenWhenInstructionIsMissing() throws {
        let description = "Motorists should be prepared for rapidly changing conditions. Use low beams and extra caution at intersections and railroad crossings."
        let alert = NWSAlert(
            id: "fog-statement", event: "Special Weather Statement", areaDesc: "Grant County",
            severity: "Moderate", messageType: "Alert",
            headline: "Special Weather Statement issued November 25 at 7:36PM CST by NWS Bismarck ND",
            description: description, sent: nowDate, expires: nil)

        let bulletin = try #require(AlertMonitor.bulletin(for: alert, now: nowDate))

        #expect(bulletin.text == "Moderate Special Weather Statement for Grant County.\n\(description)")
        #expect(bulletin.originalText?.contains(description.trimmingCharacters(in: .whitespacesAndNewlines)) == true)
    }

    @Test func onsetAndEndAcrossDaylightTransitionUseExplicitUTCWhenHeadlineHasNoZone() throws {
        let alert = NWSAlert(
            id: "dst-alert", event: "Flood Watch", areaDesc: "Example County", severity: "Moderate",
            onset: iso("2026-11-01T01:30:00-04:00"),
            expires: iso("2026-11-01T01:30:00-05:00"),
            ends: iso("2026-11-01T01:30:00-05:00"))

        let bulletin = try #require(AlertMonitor.bulletin(for: alert, now: nowDate))

        #expect(bulletin.text == "Moderate Flood Watch for Example County. The hazard is expected from Sunday, November 1 at 5:30 AM UTC until 6:30 AM UTC.")
    }

    @Test func CAPTimesWinWhenHeadlineIsMissingOrUnparseable() throws {
        for headline in [nil, "URGENT: conditions are changing quickly"] {
            let alert = NWSAlert(
                id: "cap-time-\(headline ?? "missing")", event: "Flood Warning", areaDesc: "Example County",
                severity: "Severe", headline: headline,
                sent: iso("2026-05-01T08:00:00-04:00"), onset: iso("2026-05-01T08:30:00-04:00"),
                expires: iso("2026-05-01T10:15:00-04:00"), ends: iso("2026-05-01T10:00:00-04:00"))

            let bulletin = try #require(AlertMonitor.bulletin(for: alert, now: nowDate))
            #expect(bulletin.text.contains("The hazard is expected from Friday, May 1 at 12:30 PM UTC until 2:00 PM UTC."))
            #expect(!bulletin.text.contains("2:15 PM UTC"), "expiration after hazard end does not extend the spoken hazard")
            #expect(!bulletin.text.contains("08:00"), "sent time is not hazard onset")
        }
    }

    @Test func alertDeliveryStopsAtEarlierKnownHazardEndOrExpiration() throws {
        let endsBeforeExpiry = NWSAlert(
            id: "ended-hazard", event: "Flood Warning", areaDesc: "Example County", severity: "Severe",
            expires: nowDate.addingTimeInterval(600), ends: nowDate.addingTimeInterval(-1))
        let expiresBeforeEnd = NWSAlert(
            id: "expired-message", event: "Flood Warning", areaDesc: "Example County", severity: "Severe",
            expires: nowDate.addingTimeInterval(-1), ends: nowDate.addingTimeInterval(600))
        #expect(AlertMonitor.bulletin(for: endsBeforeExpiry, now: nowDate) == nil)
        #expect(AlertMonitor.bulletin(for: expiresBeforeEnd, now: nowDate) == nil)

        let active = NWSAlert(
            id: "ends-before-expiry", event: "Flood Warning", areaDesc: "Example County", severity: "Severe",
            expires: nowDate.addingTimeInterval(600), ends: nowDate.addingTimeInterval(300))
        let bulletin = try #require(AlertMonitor.bulletin(for: active, now: nowDate))
        #expect(bulletin.expiresAt == active.ends)
        #expect(bulletin.text.contains("hazard is expected to end"))
        #expect(!bulletin.text.contains("alert expires"), "later alert expiry does not extend the hazard")

        let alertExpiresFirst = NWSAlert(
            id: "alert-expires-first", event: "Flood Warning", areaDesc: "Example County", severity: "Severe",
            expires: nowDate.addingTimeInterval(300), ends: nowDate.addingTimeInterval(600))
        let expiringBulletin = try #require(AlertMonitor.bulletin(for: alertExpiresFirst, now: nowDate))
        #expect(expiringBulletin.expiresAt == alertExpiresFirst.expires)
        #expect(expiringBulletin.text.contains("before the hazard ends"))
    }

    @Test func oversizedOfficialTextUsesWholeOriginalAndNeverCutsAnInstruction() throws {
        let instruction = String(repeating: "Be careful opening or closing doors. ", count: 700)
        let description = String(repeating: "Hazard details remain available in the official alert. ", count: 400)
        let alert = NWSAlert(
            id: "urn:oid:2.49.0.1.840.0.12346", event: "Wind Advisory", areaDesc: "Haleakala Summit",
            severity: "Moderate", headline: "Wind Advisory issued until 3 PM HST by NWS Honolulu HI",
            description: description, instruction: instruction,
            sent: nowDate, expires: nowDate.addingTimeInterval(3_600))

        let bulletin = try #require(AlertMonitor.bulletin(for: alert, now: nowDate))

        #expect(bulletin.text.count <= Bulletin.maximumTextCharacters)
        #expect(bulletin.text.utf8.count <= Bulletin.maximumTextUTF8Bytes)
        #expect(bulletin.text.contains("full official safety instructions"))
        #expect(!bulletin.text.contains(instruction))
        #expect(bulletin.originalText?.contains(instruction.trimmingCharacters(in: .whitespacesAndNewlines)) == true)
        #expect(bulletin.originalText?.contains(description.trimmingCharacters(in: .whitespacesAndNewlines)) == true)
        #expect(bulletin.link?.absoluteString == "https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.12346")
    }

    @Test func longButBoundedInstructionsUseACompleteNoticeAndRemainReadableOffline() throws {
        let instruction = String(repeating: "Keep away from the shoreline. ", count: 80)
        let alert = NWSAlert(
            id: "urn:oid:2.49.0.1.840.0.12347", event: "Coastal Flood Advisory", areaDesc: "Example County",
            severity: "Moderate", instruction: instruction,
            expires: nowDate.addingTimeInterval(3_600))

        let bulletin = try #require(AlertMonitor.bulletin(for: alert, now: nowDate))

        #expect(bulletin.text.utf8.count <= 2_000)
        #expect(bulletin.text.contains("full official safety instructions"))
        #expect(!bulletin.text.contains("Keep away from the shoreline"))
        #expect(bulletin.originalText?.contains(instruction.trimmingCharacters(in: .whitespacesAndNewlines)) == true)
        #expect(bulletin.link?.host == "api.weather.gov")
    }

    @Test func failureBacksOffAndRecovers() async throws {
        struct Down: Error {}
        final class Failing: NWSAlertSource, @unchecked Sendable {
            func activeAlerts(lat: Double, lon: Double) async throws -> NWSAlertsResponse { throw Down() }
        }
        let monitor = AlertMonitor(source: Failing(), deliver: { _ in }, now: { nowDate })
        await monitor.setCoordinates(lat: 39.74, lon: -97.09)
        await monitor.start()
        try await waitForFirstPoll(monitor)
        #expect(await monitor.status.consecutiveFailures == 1)
        #expect(await monitor.pollOnce() == 120)
        #expect(await monitor.status.consecutiveFailures == 2)
    }
}

private actor Ticker {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func release() { waiting.forEach { $0.resume() }; waiting = [] }
}

private func waitForFirstPoll(_ monitor: AlertMonitor) async throws {
    for _ in 0..<300 {
        if await monitor.status.lastPollAt != nil { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the monitor never completed a poll")
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

private func iso(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) }
