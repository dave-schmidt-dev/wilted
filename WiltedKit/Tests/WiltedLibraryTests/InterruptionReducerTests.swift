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

    /// Arrives, waits, then speaks at the pause point; returns the reducer mid-speech.
    private func speaking(_ id: String = "h1", severity: BulletinSeverity = .minor) throws
        -> (InterruptionReducer, SpeechCheckpoint) {
        var reducer = InterruptionReducer(waitLimit: 60)
        let b = try bulletin(id, severity: severity)
        _ = reducer.handle(.bulletinArrived(b, try snap()))
        let effects = reducer.handle(.pausePointReached(try snap(5)))
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

    func testAnExpiredBulletinIsDroppedWithoutSpeaking() throws {
        var reducer = InterruptionReducer(waitLimit: 60)
        let stale = try bulletin("old", ttl: 10)
        XCTAssertEqual(reducer.handle(.bulletinArrived(stale, try snap(20))), [])
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertTrue(reducer.pending.isEmpty)
        // One that expires while waiting is dropped before it can speak.
        let brief = try bulletin("brief", ttl: 30)
        let effects = reducer.handle(.bulletinArrived(brief, try snap()))
        XCTAssertEqual(effects, [.awaitPausePoint(brief, deadline: t0.addingTimeInterval(60))])
        XCTAssertEqual(reducer.handle(.pausePointReached(try snap(40))), [])
        XCTAssertEqual(reducer.state, .idle)
    }

    func testAnExtremeAlertArrivingWhileAHeadlineWaitsIsSpokenFirst() throws {
        var reducer = InterruptionReducer(waitLimit: 60)
        let headline = try bulletin("h1")
        let alert = try bulletin("a1", .alert, severity: .extreme, issued: 1)
        _ = reducer.handle(.bulletinArrived(headline, try snap()))
        guard case .waiting = reducer.state else { return XCTFail("headline should wait") }
        let effects = reducer.handle(.bulletinArrived(alert, try snap(1)))
        XCTAssertEqual(effects, [.speak(alert, try snap(1).checkpoint)])
        // The headline is still pending and waits after the alert is done.
        XCTAssertEqual(reducer.pending, [headline])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(4))).suffix(2), [.restore(try snap(1).checkpoint), .resume])
        XCTAssertEqual(reducer.handle(.tick(try snap(5))), [.awaitPausePoint(headline, deadline: t0.addingTimeInterval(65))])
    }

    func testAnExtremeAlertDuringSpeechIsSpokenNextWithOneRestoreAtTheEnd() throws {
        var (reducer, checkpoint) = try speaking()
        let alert = try bulletin("a1", .alert, severity: .extreme, issued: 2)
        XCTAssertEqual(reducer.handle(.bulletinArrived(alert, try snap(6))), [], "never interrupts speech in progress")
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(8))), [.speak(alert, checkpoint)])
        XCTAssertEqual(reducer.handle(.speechFinished(try snap(12))), [.restore(checkpoint), .resume])
    }

    func testChannelReplacedWithAnEmptyListDropsAWaitingBulletin() throws {
        var reducer = InterruptionReducer(waitLimit: 60)
        let queued = try bulletin("h2", issued: 1)
        _ = reducer.handle(.bulletinArrived(try bulletin("h1"), try snap()))
        _ = reducer.handle(.bulletinArrived(queued, try snap(1)))
        XCTAssertEqual(reducer.pending, [queued])
        XCTAssertEqual(reducer.handle(.channelReplaced([], try snap(2))), [])
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertTrue(reducer.pending.isEmpty)
        XCTAssertEqual(reducer.handle(.pausePointReached(try snap(3))), [])
    }

    func testTheSameBulletinIdArrivingTwiceIsSpokenOnce() throws {
        var reducer = InterruptionReducer(waitLimit: 60)
        let b = try bulletin("h1")
        _ = reducer.handle(.bulletinArrived(b, try snap()))
        XCTAssertEqual(reducer.handle(.bulletinArrived(b, try snap(1))), [], "already waiting")
        XCTAssertEqual(reducer.handle(.pausePointReached(try snap(2))), [.speak(b, try snap(2).checkpoint)])
        XCTAssertEqual(reducer.handle(.bulletinArrived(b, try snap(3))), [], "already speaking")
        _ = reducer.handle(.speechFinished(try snap(4)))
        XCTAssertEqual(reducer.handle(.bulletinArrived(b, try snap(5))), [], "already spoken")
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertTrue(reducer.pending.isEmpty)
    }

    func testNeverSpeaksWhenNotPlayingAndWaitsAgainOnceItPlays() throws {
        var reducer = InterruptionReducer(waitLimit: 60)
        let extreme = try bulletin("a1", .alert, severity: .extreme)
        XCTAssertEqual(reducer.handle(.bulletinArrived(extreme, try snap(playing: false))), [])
        XCTAssertEqual(reducer.handle(.tick(try snap(100, playing: false))), [])
        XCTAssertEqual(reducer.handle(.pausePointReached(try snap(101, playing: false))), [])
        XCTAssertEqual(reducer.handle(.tick(try snap(102))), [.speak(extreme, try snap(102).checkpoint)])
    }

    func testAWaitingBulletinSpeaksAtItsDeadlineAndGoesBackToPendingWhenPaused() throws {
        var reducer = InterruptionReducer(waitLimit: 60)
        let b = try bulletin("h1")
        _ = reducer.handle(.bulletinArrived(b, try snap()))
        XCTAssertEqual(reducer.handle(.tick(try snap(59))), [])
        XCTAssertEqual(reducer.handle(.userPaused(try snap(60, generation: 2))), [])
        XCTAssertEqual(reducer.pending, [b])
        XCTAssertEqual(reducer.handle(.tick(try snap(61, generation: 3))), [.awaitPausePoint(b, deadline: t0.addingTimeInterval(121))])
        XCTAssertEqual(reducer.handle(.tick(try snap(121, generation: 3))), [.speak(b, try snap(121, generation: 3).checkpoint)])
    }

    func testSupersededBulletinsAreRemovedAndOrderIsSeverityThenIssueTime() throws {
        var reducer = InterruptionReducer(waitLimit: 60)
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
    }
}
