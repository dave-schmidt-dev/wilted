import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The iPhone lists only what the Mac reports ready (W-INV-016). An entry the Mac has not prepared,
/// or has just said it has no ready audio for, is absent from the Larder, CarPlay, Siri and the play
/// order, and appears once the Mac offers it.
@MainActor
final class LibraryReadyOnlyTests: XCTestCase {
    private var fixture: LibraryViewFixture!

    override func setUp() async throws { fixture = try LibraryViewFixture() }
    override func tearDown() async throws { fixture.tearDown() }

    private func ids(_ rows: [LibraryRow]) -> [String] { rows.map(\.id.rawValue) }

    /// a: ready and on the phone, b: listed before upload, c: Mac says not ready, d: no offer at all.
    private func seedMixedLarder() async throws {
        try await fixture.queue(["a", "b", "c", "d"])
        try await fixture.offer("a")
        try await fixture.cacheAudio("a")
        try await fixture.offer("b", .available)
        try await fixture.offer("c", .notReady)
        await fixture.model.refresh()
    }

    func testAnEntryTheMacHasNotPreparedIsHiddenFromEveryListeningSurface() async throws {
        try await seedMixedLarder()
        let model = fixture.model

        XCTAssertEqual(ids(model.queued), ["a", "b", "c", "d"], "the snapshot still carries every queued entry")
        XCTAssertEqual(ids(model.visibleRows), ["a", "b"], "the Larder lists the ready and the available only")
        XCTAssertEqual(model.preparedCount, 2)
        XCTAssertEqual(ids(model.playOrderRows), ["a"], "the play order is what is on the phone")
        guard case let .episodes(car) = CarEpisodeList.make(model: model, playingID: nil).content else {
            return XCTFail("the car list has the ready episode")
        }
        XCTAssertEqual(car.map(\.id.rawValue), ["a"])
        let player = LibraryPlayer(
            engine: VoiceFakeEngine(), session: VoiceFakeSession(), nowPlaying: VoiceFakeNowPlaying(),
            remoteCommands: VoiceFakeRemote(), sessionEvents: VoiceFakeEvents(), tickInterval: .seconds(3600))
        let snapshot = await LibraryVoiceTarget(model: model, player: player).voiceSnapshot()
        XCTAssertEqual(snapshot.downloaded.map(\.id.rawValue), ["a"], "Siri and Spotlight see the same episodes")
    }

    func testAnEpisodeLeavesTheLarderAtOnceWhenGetAudioFindsItNotReadyAndReturnsWhenTheMacOffersIt() async throws {
        try await seedMixedLarder()
        let model = fixture.model
        let b = fixture.id("b")
        try await fixture.offer("b", .notReady)  // the Mac's answer to the request below
        model.performMediaAction(.request, entryID: b)
        await model.waitForMedia(entryID: b)

        XCTAssertEqual(ids(model.visibleRows), ["a"], "not ready: gone, not a row saying so")
        XCTAssertEqual(model.mediaState(for: b), .notPrepared)

        try await fixture.offer("b", .available)
        await model.refresh()
        XCTAssertEqual(ids(model.visibleRows), ["a", "b"], "listed again once the Mac offers it")
        XCTAssertEqual(model.mediaState(for: b), .available, "no stale \"Not prepared on Mac\" on the way back")
    }
}
