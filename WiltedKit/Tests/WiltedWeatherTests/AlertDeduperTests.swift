import Foundation
import Testing
@testable import WiltedWeather

private func alert(_ id: String, event: String = "Severe Thunderstorm Warning", area: String = "Washington",
                   severity: String, type: String = "Alert", sent: TimeInterval = 100) -> NWSAlert {
    NWSAlert(id: id, event: event, areaDesc: area, severity: severity, messageType: type,
             sent: Date(timeIntervalSince1970: sent))
}

@Suite("Alert deduper")
struct AlertDeduperTests {
    @Test func exactRepeatIsSuppressed() {
        var deduper = AlertDeduper()
        let a = alert("a1", severity: "Severe")
        #expect(deduper.qualifying([a]).map(\.id) == ["a1"])
        #expect(deduper.qualifying([a]).isEmpty)
        #expect(deduper.qualifying([a]).isEmpty)
    }

    @Test func reissueAtSameOrLowerSeverityIsSuppressedButEscalationIsAnnounced() {
        var deduper = AlertDeduper()
        #expect(deduper.qualifying([alert("a1", severity: "Moderate")]).count == 1)
        #expect(deduper.qualifying([alert("a2", severity: "Moderate", type: "Update", sent: 200)]).isEmpty)
        #expect(deduper.qualifying([alert("a3", severity: "Minor", type: "Update", sent: 300)]).isEmpty)
        #expect(deduper.qualifying([alert("a4", severity: "Severe", type: "Update", sent: 400)]).map(\.id) == ["a4"])
        #expect(deduper.qualifying([alert("a5", severity: "Severe", type: "Update", sent: 500)]).isEmpty)
        #expect(deduper.qualifying([alert("a6", severity: "Extreme", type: "Update", sent: 600)]).map(\.id) == ["a6"])
    }

    @Test func barResetsWhenTheAreaClears() {
        var deduper = AlertDeduper()
        #expect(deduper.qualifying([alert("a1", severity: "Extreme")]).count == 1)
        #expect(deduper.qualifying([alert("b1", area: "Marshall", severity: "Minor")]).count == 1)
        // Washington is absent from this poll, so its high-water mark is dropped.
        #expect(deduper.qualifying([alert("b1", area: "Marshall", severity: "Minor")]).isEmpty)
        #expect(deduper.qualifying([alert("a9", severity: "Minor", sent: 900)]).map(\.id) == ["a9"])
    }

    @Test func differentEventInTheSameAreaIsAnnounced() {
        var deduper = AlertDeduper()
        #expect(deduper.qualifying([alert("a1", severity: "Severe")]).count == 1)
        let wind = alert("w1", event: "Wind Advisory", severity: "Minor")
        #expect(deduper.qualifying([alert("a1", severity: "Severe"), wind]).map(\.id) == ["w1"])
    }

    @Test func cancelAckAndErrorAreNeverAnnounced() {
        var deduper = AlertDeduper()
        for type in ["Cancel", "Ack", "Error"] {
            #expect(deduper.qualifying([alert("x-\(type)", severity: "Extreme", type: type)]).isEmpty)
        }
    }

    @Test func unknownSeverityRanksLowest() {
        #expect(AlertDeduper.rank("garbage") == 0)
        #expect(AlertDeduper.rank(" SEVERE ") == 3)
    }
}
