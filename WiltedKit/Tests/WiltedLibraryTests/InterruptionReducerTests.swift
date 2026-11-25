import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class InterruptionReducerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func snap(_ offset: TimeInterval = 0, playing: Bool = true, generation: UInt64 = 1,
                      entry: String = "e1", revision: String = "r1", position: Double = 30) throws -> PlaybackSnapshot {
        PlaybackSnapshot(entryID: try ItemID(rawValue: entry), revisionID: try RevisionID(rawValue: revision),
                         positionSeconds: position, commandGeneration: generation, isPlaying: playing,
                         now: t0.addingTimeInterval(offset))
    }

    private func bulletin(_ id: String, _ kind: BulletinKind = .headline, severity: BulletinSeverity = .minor,
                          issued: TimeInterval = 0, ttl: TimeInterval = 3_600, supersedes: String? = nil) throws -> Bulletin {
        try Bulletin(id: id, kind: kind, text: "text \(id)", severity: severity, issuedAt: t0.addingTimeInterval(issued),
                     expiresAt: t0.addingTimeInterval(issued + ttl), supersedes: supersedes)
    }

    /// Queues a bulletin, then starts a batch at an explicit ad break.
    private func speaking(_ id: String = "h1", severity: BulletinSeverity = .minor) throws
        -> (InterruptionReducer, SpeechCheckpoint) {
        var reducer = InterruptionReducer()
        let b = try bulletin(id, severity: severity)
        _ = reducer.handle(.bulletinArrived(b, try snap()))
        let effects = reducer.handle(.adBreakReached(try snap(5)))
        let checkpoint = try snap(5).checkpoint
        XCTAssertEqual(effects, [.speak(b, checkpoint)])
        return (reducer, checkpoint)
    }

    func testSpeechFinishedAndSkipRestoreThenResume() throws {
        var (finished, checkpoint) = try speaking()
        XCTAssertEqual(finished.handle(.speechFinished(try snap(9))), [.restore(checkpoint), .resume])
        XCTAssertEqual(finished.state, .idle)
        var (skipped, same) = try speaking()
        XCTAssertEqual(skipped.handle(.skip(try snap(9))), [.stopSpeech, .restore(same), .resume])
        XCTAssertEqual(skipped.state, .idle)
    }

    func testUserPauseStopAndRouteLossRestoreWithoutResume() throws {
        let events: [(PlaybackSnapshot) -> InterruptionEvent] = [
            { .userPaused($0) }, { .playbackStopped($0) }, { .routeLost($0) },
        ]
        for make in events {
            var (reducer, checkpoint) = try speaking()
            // The pause is itself a newer command, so the generation has moved on.
            XCTAssertEqual(reducer.handle(make(try snap(7, generation: 2))), [.stopSpeech, .restore(checkpoint)])
            XCTAssertEqual(reducer.state, .idle)
            XCTAssertEqual(reducer.handle(.speechFinished(try snap(8, generation: 2))), [], "late completion is dropped")
        }
    }

    func testSystemInterruptionResumesOnlyWhenTheHintSaysSo() throws {
        var (yes, checkpoint) = try speaking()
        XCTAssertEqual(yes.handle(.systemInterruption(shouldResume: true, try snap(7))), [.stopSpeech, .restore(checkpoint), .resume])
        var (no, same) = try speaking()
        XCTAssertEqual(no.handle(.systemInterruption(shouldResume: false, try snap(7))), [.stopSpeech, .restore(same)])
    }

    func testSpeechCompletionAfterItemChangedEmitsNeitherRestoreNorResume() throws {
        var (reducer, _) = try speaking()
        XCTAssertEqual(reducer.handle(.itemChanged), [.stopSpeech])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(9, entry: "e2", revision: "r2"))), [])
        // A completion that still names the old item, arriving after the change, is dropped too.
        var (other, _) = try speaking()
        XCTAssertEqual(other.handle(.speechFinished(try snap(9, entry: "e2"))), [])
        XCTAssertEqual(other.state, .idle)
    }

    func testSpeechCompletionAfterASeekEmitsNeitherRestoreNorResume() throws {
        var (finished, _) = try speaking()
        XCTAssertEqual(finished.handle(.speechFinished(try snap(9, generation: 2, position: 500))), [])
        XCTAssertEqual(finished.state, .idle)
        var (skipped, _) = try speaking()
        let effects = skipped.handle(.skip(try snap(9, generation: 2, position: 500)))
        XCTAssertFalse(effects.contains { if case .restore = $0 { true } else if $0 == .resume { true } else { false } })
    }

    func testExpiredBulletinsAreDroppedBeforeAnAdBreakBatchStarts() throws {
        var reducer = InterruptionReducer()
        let stale = try bulletin("old", ttl: 10)
        XCTAssertEqual(reducer.handle(.bulletinArrived(stale, try snap(20))), [])
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertTrue(reducer.pending.isEmpty)
        // A bulletin can expire after arrival but before its next break.
        let brief = try bulletin("brief", ttl: 30)
        XCTAssertEqual(reducer.handle(.bulletinArrived(brief, try snap())), [])
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(40))), [])
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertTrue(reducer.pending.isEmpty)
    }

    func testAllSeveritiesWaitForTheNextBreakAndBatchBySeverity() throws {
        var reducer = InterruptionReducer()
        let headline = try bulletin("h1")
        let alert = try bulletin("a1", .alert, severity: .extreme, issued: 1)
        _ = reducer.handle(.bulletinArrived(headline, try snap()))
        XCTAssertEqual(reducer.state, .idle)
        let effects = reducer.handle(.bulletinArrived(alert, try snap(1)))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(reducer.pending.map(\.id), ["a1", "h1"])
        XCTAssertEqual(reducer.handle(.tick(try snap(61))), [], "time passing never speaks a bulletin")
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(62))), [.speak(alert, try snap(62).checkpoint)])
        XCTAssertEqual(reducer.remainingInBatch, [headline])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(64))), [.speak(headline, try snap(62).checkpoint)])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(66))), [.restore(try snap(62).checkpoint), .resume])
    }

    func testEveryWeatherSeverityWaitsForAndDrainsAtTheAdBreak() throws {
        var reducer = InterruptionReducer()
        let alerts = try BulletinSeverity.allCases.enumerated().map { index, severity in
            try bulletin("alert-\(severity.rawValue)", .alert, severity: severity, issued: TimeInterval(index))
        }
        for alert in alerts {
            XCTAssertEqual(reducer.handle(.bulletinArrived(alert, try snap())), [])
        }
        XCTAssertEqual(reducer.pending.count, alerts.count)
        XCTAssertEqual(reducer.state, .idle, "no severity starts speech before a marked break")

        let ordered = alerts.sorted { $0.severity > $1.severity }
        let checkpoint = try snap(20).checkpoint
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(20))), [.speak(ordered[0], checkpoint)])
        for alert in ordered.dropFirst() {
            XCTAssertEqual(reducer.handle(.speechFinished(try snap(21))), [.speak(alert, checkpoint)])
        }
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(22))), [.restore(checkpoint), .resume])
    }

    func testItemsArrivingDuringASnapshotBatchWaitForTheNextBreak() throws {
        var (reducer, checkpoint) = try speaking()
        let arrival = try bulletin("a1", .alert, severity: .extreme, issued: 6)
        XCTAssertEqual(reducer.handle(.bulletinArrived(arrival, try snap(6))), [])
        XCTAssertEqual(reducer.pending, [arrival])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(8))), [.restore(checkpoint), .resume])
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(12))), [.speak(arrival, try snap(12).checkpoint)])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(15))), [.restore(try snap(12).checkpoint), .resume])
    }

    func testFailedSpeechStartRequeuesTheCurrentAndUnreadBulletins() throws {
        var reducer = InterruptionReducer()
        let current = try bulletin("current", .alert, severity: .severe)
        let queued = try bulletin("queued", .headline, severity: .minor, issued: 1)
        _ = reducer.handle(.bulletinArrived(current, try snap()))
        _ = reducer.handle(.bulletinArrived(queued, try snap(1)))
        let checkpoint = try snap(2).checkpoint
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(2))), [.speak(current, checkpoint)])

        XCTAssertEqual(reducer.handle(.speechStartFailed(try snap(2))),
                       [.stopSpeech, .restore(checkpoint), .resume])
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertEqual(reducer.pending.map(\.id), ["current", "queued"])
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(3))), [.speak(current, try snap(3).checkpoint)])
    }

    func testChannelRefreshDoesNotDiscardAccumulatedValidHeadlines() throws {
        var reducer = InterruptionReducer()
        let queued = try bulletin("h2", issued: 1)
        _ = reducer.handle(.bulletinArrived(try bulletin("h1"), try snap()))
        _ = reducer.handle(.bulletinArrived(queued, try snap(1)))
        XCTAssertEqual(reducer.pending, [try bulletin("h1"), queued])
        XCTAssertEqual(reducer.handle(.channelReplaced([], try snap(2))), [])
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertEqual(reducer.pending, [try bulletin("h1"), queued])
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(3))), [.speak(try bulletin("h1"), try snap(3).checkpoint)])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(4))), [.speak(queued, try snap(3).checkpoint)])
    }

    func testAWeatherAlertRemovedFromTheActiveChannelIsDroppedBeforeTheBreak() throws {
        var reducer = InterruptionReducer()
        let alert = try bulletin("alert-1", .alert, severity: .severe)
        _ = reducer.handle(.bulletinArrived(alert, try snap()))

        XCTAssertEqual(reducer.handle(.channelReplaced([], try snap(1))), [])
        XCTAssertTrue(reducer.pending.isEmpty)
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(2))), [])
    }

    func testTheSameBulletinIdArrivingTwiceIsSpokenOnce() throws {
        var reducer = InterruptionReducer()
        let b = try bulletin("h1")
        _ = reducer.handle(.bulletinArrived(b, try snap()))
        XCTAssertEqual(reducer.handle(.bulletinArrived(b, try snap(1))), [], "duplicate queued id")
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(2))), [.speak(b, try snap(2).checkpoint)])
        XCTAssertEqual(reducer.handle(.bulletinArrived(b, try snap(3))), [], "already speaking")
        _ = reducer.handle(.speechFinished(try snap(4)))
        XCTAssertEqual(reducer.handle(.bulletinArrived(b, try snap(5))), [], "already spoken")
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertTrue(reducer.pending.isEmpty)
    }

    func testAReachedBreakWhilePausedKeepsBulletinsForTheNextBreak() throws {
        var reducer = InterruptionReducer()
        let extreme = try bulletin("a1", .alert, severity: .extreme)
        XCTAssertEqual(reducer.handle(.bulletinArrived(extreme, try snap(playing: false))), [])
        XCTAssertEqual(reducer.handle(.tick(try snap(100, playing: false))), [])
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(101, playing: false))), [])
        XCTAssertEqual(reducer.handle(.tick(try snap(102))), [])
        XCTAssertEqual(reducer.pending, [extreme])
    }

    func testPausePointAndItemBoundaryNeverStartAutomaticBulletins() throws {
        var reducer = InterruptionReducer()
        let b = try bulletin("a1", .alert, severity: .severe)
        _ = reducer.handle(.bulletinArrived(b, try snap()))
        XCTAssertEqual(reducer.handle(.tick(try snap(10))), [])
        XCTAssertEqual(reducer.handle(.itemChanged), [])
        XCTAssertEqual(reducer.handle(.tick(try snap(61, entry: "e2", position: 0))), [])
        XCTAssertEqual(reducer.pending, [b])
        XCTAssertEqual(reducer.handle(.adBreakReached(try snap(62, entry: "e2", position: 10))),
                       [.speak(b, try snap(62, entry: "e2", position: 10).checkpoint)])
    }

    func testAHeadlineDoesNotSpeakFromTicksOrSpeechPausePoints() throws {
        var reducer = InterruptionReducer()
        let b = try bulletin("h1")
        _ = reducer.handle(.bulletinArrived(b, try snap()))
        XCTAssertEqual(reducer.handle(.tick(try snap(61))), [], "the deadline passing is not a pause")
        XCTAssertEqual(reducer.handle(.tick(try snap(3_600 - 1))), [])
        XCTAssertEqual(reducer.handle(.tick(try snap(90))), [])
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertEqual(reducer.pending, [b])
    }

    func testAHeadlineDoesNotSpeakWhenTheNextEpisodeStartsPlaying() throws {
        var reducer = InterruptionReducer()
        let b = try bulletin("h1")
        _ = reducer.handle(.bulletinArrived(b, try snap()))
        XCTAssertEqual(reducer.handle(.tick(try snap(61))), [])
        XCTAssertEqual(reducer.handle(.itemChanged), [])
        XCTAssertEqual(reducer.handle(.tick(try snap(62, playing: false, entry: "e2", position: 0))), [],
                       "nothing speaks before the next item plays")
        let start = try snap(63, entry: "e2", position: 0)
        XCTAssertEqual(reducer.handle(.tick(start)), [])
        XCTAssertEqual(reducer.pending, [b])
    }

    func testAnItemBoundaryLeavesAccumulatedHeadlinesForAnAdBreak() throws {
        var reducer = InterruptionReducer()
        let b = try bulletin("h1")
        _ = reducer.handle(.bulletinArrived(b, try snap(playing: false)))
        XCTAssertEqual(reducer.pending, [b])
        _ = reducer.handle(.itemChanged)
        let start = try snap(1, entry: "e2", position: 0)
        XCTAssertEqual(reducer.handle(.tick(start)), [])
        XCTAssertEqual(reducer.pending, [b])
        let later = try bulletin("h2", issued: 5)
        XCTAssertEqual(reducer.handle(.bulletinArrived(later, try snap(5, entry: "e2", position: 3))), [])
        XCTAssertEqual(reducer.pending.map(\.id), ["h1", "h2"])
    }

    func testSupersededBulletinsAreRemovedAndOrderIsSeverityThenIssueTime() throws {
        var reducer = InterruptionReducer()
        let first = try bulletin("h1", severity: .minor, issued: 0)
        let second = try bulletin("h2", severity: .severe, issued: 1)
        let third = try bulletin("h3", severity: .severe, issued: 2)
        _ = reducer.handle(.bulletinArrived(first, try snap(playing: false)))
        _ = reducer.handle(.bulletinArrived(third, try snap(playing: false)))
        _ = reducer.handle(.bulletinArrived(second, try snap(playing: false)))
        XCTAssertEqual(reducer.pending.map(\.id), ["h2", "h3", "h1"])
        let replacement = try bulletin("h4", severity: .minor, issued: 3, supersedes: "h3")
        _ = reducer.handle(.bulletinArrived(replacement, try snap(playing: false)))
        XCTAssertEqual(reducer.pending.map(\.id), ["h2", "h1", "h4"])
        // The superseded id arriving late is not resurrected.
        _ = reducer.handle(.bulletinArrived(third, try snap(playing: false)))
        XCTAssertEqual(reducer.pending.map(\.id), ["h2", "h1", "h4"])
        let effects = reducer.handle(.adBreakReached(try snap()))
        XCTAssertEqual(effects, [.speak(second, try snap().checkpoint)])
        XCTAssertEqual(reducer.pending, [])
        XCTAssertEqual(reducer.remainingInBatch.map(\.id), ["h1", "h4"])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(1))), [.speak(first, try snap().checkpoint)])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(2))), [.speak(replacement, try snap().checkpoint)])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(3))), [.restore(try snap().checkpoint), .resume])
    }
}
