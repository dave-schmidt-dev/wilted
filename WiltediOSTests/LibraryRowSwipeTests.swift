import SwiftUI
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The Larder row's swipe states and what they do. A real finger swipe cannot be injected headlessly, so
/// the states are checked as data, and the same actions are driven through VoiceOver's custom actions on
/// the hosted row, which run the swipe's own handler (and so its confirmation).
@MainActor
final class LibraryRowSwipeTests: XCTestCase {
    private var fixture: LibraryViewFixture!

    override func setUp() async throws { fixture = try LibraryViewFixture() }
    override func tearDown() async throws { fixture.tearDown() }

    // MARK: States

    func testNotDownloadedSwipesRightToRemoveAndLeftToDownload() {
        for media: LibraryMediaState in [.available, .failed("x"), .notPrepared] {
            XCTAssertEqual(LibrarySwipe.leading(media: media, canMarkCompleted: false), [.removeFromLarder], "\(media)")
            XCTAssertEqual(LibrarySwipe.trailing(media: media, isPlaying: false), [.download], "\(media)")
        }
        let running = LibraryMediaState.downloading(bytes: 4, total: 10, since: Date())
        XCTAssertEqual(LibrarySwipe.trailing(media: running, isPlaying: false), [], "a running transfer is cancelled by its ring")
        XCTAssertEqual(LibrarySwipe.leading(media: running, canMarkCompleted: false), [.removeFromLarder])
    }

    func testDownloadedSwipesRightToMarkCompletedAndLeftToPlay() {
        XCTAssertEqual(LibrarySwipe.leading(media: .onPhone, canMarkCompleted: true), [.markCompleted])
        XCTAssertEqual(LibrarySwipe.leading(media: .onPhone, canMarkCompleted: false), [], "W-INV-010: only a started row")
        XCTAssertEqual(LibrarySwipe.trailing(media: .onPhone, isPlaying: false), [.play])
        XCTAssertEqual(LibrarySwipe.trailing(media: .onPhone, isPlaying: true), [.pause])
    }

    func testTitlesSymbolsAndConfirmations() {
        XCTAssertEqual(LibrarySwipe.removeFromLarder.symbol, "minus.circle")
        XCTAssertEqual(LibrarySwipe.markCompleted.symbol, "checkmark.circle")
        XCTAssertEqual(LibrarySwipe.download.symbol, "arrow.down.circle")
        XCTAssertEqual(LibrarySwipe.play.symbol, "play.fill")
        XCTAssertEqual(LibrarySwipe.removeFromLarder.title, "Remove from Larder")
        XCTAssertEqual(LibrarySwipe.markCompleted.title, "Mark completed")
        let id = fixture.id("a")
        XCTAssertTrue(LibrarySwipe.Confirmation.removeFromLarder(id).isDestructive)
        XCTAssertFalse(LibrarySwipe.Confirmation.markCompleted(id).isDestructive)
        XCTAssertNotEqual(LibrarySwipe.Confirmation.removeFromLarder(id).id, LibrarySwipe.Confirmation.markCompleted(id).id)
    }

    // MARK: Hosted row

    /// a: downloaded and started, b: downloaded, c: not downloaded.
    private func host(onPlay: @escaping (LibraryRow) -> Void = { _ in }) async throws -> HostedView<some View> {
        try await fixture.queue(["a", "b", "c"])
        for raw in ["a", "b"] {
            try await fixture.offer(raw)
            try await fixture.cacheAudio(raw)
        }
        try await fixture.offer("c", .available)
        try await fixture.startOnMac("a")
        await fixture.model.refresh()
        return HostedView(NavigationStack { LibraryListView(model: fixture.model, onPlay: onPlay) })
    }

    private func intentCount() async throws -> Int {
        try await InMemoryLibraryTransport(deviceID: "mac", server: fixture.server).listIntents().count
    }

    func testVoiceOverGetsTheSwipeActionsByName() async throws {
        let hosted = try await host()
        XCTAssertEqual(hosted.element("wilted-library-title-a")?.customActionNames, ["Play", "Mark completed", "Open episode"])
        XCTAssertEqual(hosted.element("wilted-library-title-b")?.customActionNames, ["Play", "Open episode"])
        XCTAssertEqual(hosted.element("wilted-library-title-c")?.customActionNames, ["Download", "Remove from Larder", "Open episode"])
    }

    func testTheRowCarriesNoInlineCompletionTick() async throws {
        let hosted = try await host()
        XCTAssertNil(hosted.element("wilted-library-action-done-a"), "Mark completed moved to the swipe, the detail and Now Playing")
        XCTAssertNil(hosted.element("wilted-library-action-remove-a"))
    }

    func testRemoveAndMarkCompletedAskBeforeActing() async throws {
        let hosted = try await host()
        XCTAssertTrue(try XCTUnwrap(hosted.element("wilted-library-title-c")).perform(customAction: "Remove from Larder"))
        XCTAssertTrue(try XCTUnwrap(hosted.element("wilted-library-title-a")).perform(customAction: "Mark completed"))
        hosted.settle()
        let model = fixture.model
        XCTAssertNil(model.pendingDecision(for: fixture.id("c")), "a swipe, even a full one, only opens the question")
        XCTAssertNil(model.pendingDecision(for: fixture.id("a")))
        let sent = try await intentCount()
        XCTAssertEqual(sent, 0, "nothing reached the Mac")
    }

    func testConfirmingSendsTheDecisionDownTheSharedPath() async throws {
        _ = try await host()
        let model = fixture.model
        LibrarySwipe.Confirmation.removeFromLarder(fixture.id("c")).confirmed(on: model)
        LibrarySwipe.Confirmation.markCompleted(fixture.id("a")).confirmed(on: model)
        try await fixture.eventually("both decisions are in flight") {
            model.pendingDecision(for: self.fixture.id("c")) != nil && model.pendingDecision(for: self.fixture.id("a")) != nil
        }
        let sent = try await intentCount()
        XCTAssertEqual(sent, 2)
    }

    func testDownloadActsAtOnceAndPlayHandsTheRowToThePlayer() async throws {
        var played: [String] = []
        let hosted = try await host(onPlay: { played.append($0.id.rawValue) })
        let model = fixture.model
        XCTAssertTrue(try XCTUnwrap(hosted.element("wilted-library-title-c")).perform(customAction: "Download"))
        XCTAssertTrue(try XCTUnwrap(hosted.element("wilted-library-title-b")).perform(customAction: "Play"))
        try await fixture.eventually("the download was requested") { model.mediaState(for: self.fixture.id("c")) != .available }
        XCTAssertEqual(played, ["b"])
    }

    func testARowButtonActsOnItsOwnAndDoesNotAlsoOpenTheEpisode() async throws {
        var played: [String] = []
        let hosted = try await host(onPlay: { played.append($0.id.rawValue) })
        XCTAssertTrue(try XCTUnwrap(hosted.element("wilted-library-play-b")).activate())
        hosted.settle()
        XCTAssertEqual(played, ["b"], "the row's own button plays")
        XCTAssertNil(hosted.element("wilted-library-detail-title"), "and does not also open the episode")
    }
}
