import Foundation
import Testing
import WiltedDomain
@testable import WiltedLibrary

struct InterruptionReducerPersistenceTests {
    @Test func aSeededSpokenHeadlineIsNotScheduledAgain() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let headline = try Bulletin(
            id: "headline-1", kind: .headline, text: "A headline", severity: .minor,
            issuedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(3_600))
        let snapshot = PlaybackSnapshot(
            entryID: try ItemID(rawValue: "episode-1"), revisionID: try RevisionID(rawValue: "revision-1"),
            positionSeconds: 30, commandGeneration: 1, isPlaying: true, now: now)
        var reducer = InterruptionReducer(alreadySpoken: [headline.id: now.addingTimeInterval(86_400)])

        let effects = reducer.handle(.bulletinArrived(headline, snapshot))

        #expect(effects.isEmpty)
        #expect(reducer.state == .idle)
        #expect(reducer.pending.isEmpty)
    }
}
