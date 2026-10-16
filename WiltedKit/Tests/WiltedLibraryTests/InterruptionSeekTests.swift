import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class InterruptionSeekTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func snapshot(generation: UInt64 = 1, entry: String = "one") throws -> PlaybackSnapshot {
        PlaybackSnapshot(entryID: try ItemID(rawValue: entry), revisionID: try RevisionID(rawValue: "revision"),
                         positionSeconds: 12, commandGeneration: generation, isPlaying: true, now: now)
    }

    private func bulletin(_ id: String, severity: BulletinSeverity = .extreme) throws -> Bulletin {
        try Bulletin(id: id, kind: .alert, text: "Alert", severity: severity,
                     issuedAt: now, expiresAt: now.addingTimeInterval(300))
    }

    func testSeekStopsAndRestoresWithoutResumeAndFencesLateCompletion() throws {
        var reducer = InterruptionReducer()
        let original = try snapshot()
        _ = reducer.handle(.bulletinArrived(try bulletin("first"), original))
        _ = reducer.handle(.bulletinArrived(try bulletin("pending"), original))
        XCTAssertEqual(reducer.handle(.seekStarted(try snapshot(generation: 2))),
                       [.stopSpeech, .restore(original.checkpoint)])
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertEqual(reducer.pending.map(\.id), ["pending"])
        XCTAssertEqual(reducer.handle(.speechFinished(original)), [])
    }

    func testSeekOnAnotherItemStopsWithoutRestoringTheOldItem() throws {
        var reducer = InterruptionReducer()
        _ = reducer.handle(.bulletinArrived(try bulletin("first"), try snapshot()))
        XCTAssertEqual(reducer.handle(.seekStarted(try snapshot(generation: 2, entry: "other"))), [.stopSpeech])
    }

    func testSeekDemotesWaitingBulletinWithoutCallingItAPause() throws {
        var reducer = InterruptionReducer()
        let headline = try bulletin("waiting", severity: .minor)
        _ = reducer.handle(.bulletinArrived(headline, try snapshot()))
        XCTAssertEqual(reducer.handle(.seekStarted(try snapshot(generation: 2))), [])
        XCTAssertEqual(reducer.state, .idle)
        XCTAssertEqual(reducer.pending, [headline])
    }
}
