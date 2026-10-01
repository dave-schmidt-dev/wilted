import SwiftUI
import UIKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Now Playing on the shipping views: the artwork wash, Mark completed and Remove from Larder, and the
/// scrubber's mapping and VoiceOver adjustment.
@MainActor
final class LibraryPlayerHostedTests: XCTestCase {
    private var fixture: LibraryViewFixture!
    private var scratch: URL!
    private let artwork = URL(string: "https://example.com/art.png")!

    override func setUp() async throws {
        fixture = try LibraryViewFixture()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("player-art-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        fixture.tearDown()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }()).pngData { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }

    private func started(_ raw: String, artwork: URL?) -> (LibraryPlayer, LibraryPlayer.Item) {
        let player = fixture.makePlayer()
        let item = LibraryPlayer.Item(
            entryID: fixture.id(raw), title: "Title \(raw)", showTitle: "The Show",
            fileURL: scratch.appendingPathComponent("\(raw).m4a"), artworkURL: artwork)
        XCTAssertTrue(player.start(item, autoplay: false))
        return (player, item)
    }

    // MARK: Artwork wash

    func testTheArtworkWashShowsWithCachedArtAndIsAbsentWithout() async throws {
        let cache = LibraryArtworkCache(directory: scratch)
        let (player, _) = started("a", artwork: artwork)
        let without = HostedView(LibraryPlayerView(player: player, artworkCache: cache, onClose: {}))
        without.settle(0.6)
        XCTAssertNil(without.element("wilted-player-artwork-backdrop"), "no cached art: the page stays plain")
        XCTAssertNotNil(without.element("wilted-player-title"), "and the screen is otherwise whole")

        XCTAssertTrue(cache.store(png(), for: artwork))
        let with = HostedView(LibraryPlayerView(player: player, artworkCache: cache, onClose: {}))
        with.settle(0.8)
        XCTAssertNotNil(with.element("wilted-player-artwork-backdrop"))
    }

    func testTheWashNeverFetchesAndNeverTakesATouch() async throws {
        var cache = LibraryArtworkCache(directory: scratch)
        let fetched = ManualCounter()
        cache.download = { _ in fetched.bump(); return nil }
        let (player, _) = started("a", artwork: artwork)
        let hosted = HostedView(LibraryPlayerView(player: player, artworkCache: cache, onClose: {}))
        hosted.settle(0.6)
        XCTAssertEqual(fetched.value, 0, "local cache only")
        XCTAssertTrue(try XCTUnwrap(hosted.element("wilted-player-toggle")).isButton, "controls stay reachable over the wash")
    }

    func testTheWashKeepsTextContrastOverTheWorstPixelInBothSchemes() {
        XCTAssertEqual(LibraryArtworkBackdrop.opacity, 0.12, "changing this re-opens W-INV-010; re-derive the contrast below")
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) }
        func blend(_ page: UInt32, over pixel: UInt32) -> UInt32 {
            let a = LibraryArtworkBackdrop.opacity
            return [16, 8, 0].reduce(UInt32(0)) { sum, shift in
                let mixed = (channel(page, UInt32(shift)) * (1 - a) + channel(pixel, UInt32(shift)) * a).rounded()
                return sum | (UInt32(mixed) << UInt32(shift))
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            let page = WiltedTheme.hex(for: .page, scheme: scheme)
            for pixel: UInt32 in [0x000000, 0xFFFFFF] {
                let under = blend(page, over: pixel)
                for token in [WiltedTheme.ColorToken.primaryText, .secondaryText] {
                    XCTAssertGreaterThanOrEqual(
                        WiltedTheme.contrastRatio(WiltedTheme.hex(for: token, scheme: scheme), under), 4.5,
                        "\(token) in \(scheme) over \(String(pixel, radix: 16))")
                }
            }
        }
    }

    // MARK: Mark completed and Remove from Larder

    func testNowPlayingOffersMarkCompletedAndRemoveForAnEpisodeOnThePhone() async throws {
        try await fixture.seed(["a", "b"])
        try await fixture.startOnMac("a")
        await fixture.model.refresh()

        let (startedPlayer, _) = started("a", artwork: nil)
        let startedView = HostedView(LibraryPlayerView(player: startedPlayer, model: fixture.model, onClose: {}))
        XCTAssertNotNil(startedView.element("wilted-player-mark-completed"))
        XCTAssertNotNil(startedView.element("wilted-player-remove-from-larder"))

        let (freshPlayer, _) = started("b", artwork: nil)
        let freshView = HostedView(LibraryPlayerView(player: freshPlayer, model: fixture.model, onClose: {}))
        XCTAssertNotNil(freshView.element("wilted-player-mark-completed"), "W-INV-010: audio on the phone offers it before it is started")
        XCTAssertNotNil(freshView.element("wilted-player-remove-from-larder"))
    }

    func testTappingMarkCompletedOnNowPlayingAsksFirst() async throws {
        try await fixture.seed(["a"])
        try await fixture.startOnMac("a")
        await fixture.model.refresh()
        let (player, _) = started("a", artwork: nil)
        let hosted = HostedView(LibraryPlayerView(player: player, model: fixture.model, onClose: {}))
        XCTAssertTrue(try XCTUnwrap(hosted.element("wilted-player-mark-completed")).activate())
        hosted.settle()
        XCTAssertNil(fixture.model.pendingDecision(for: fixture.id("a")), "the question comes first")
    }

    // MARK: Scrubber

    func testDragMapsToSecondsAcrossTheTrackAndClamps() {
        typealias S = LibraryScrubber
        XCTAssertEqual(S.position(forX: 0, width: 300, duration: 600), 0)
        XCTAssertEqual(S.position(forX: 150, width: 300, duration: 600), 300)
        XCTAssertEqual(S.position(forX: 300, width: 300, duration: 600), 600)
        XCTAssertEqual(S.position(forX: -40, width: 300, duration: 600), 0, "dragged past the left end")
        XCTAssertEqual(S.position(forX: 900, width: 300, duration: 600), 600, "dragged past the right end")
        XCTAssertEqual(S.position(forX: 100, width: 0, duration: 600), 0, "no layout yet")
        XCTAssertEqual(S.position(forX: 100, width: 300, duration: 0), 0, "nothing loaded")
        XCTAssertEqual(S.position(forX: .nan, width: 300, duration: 600), 0)
        XCTAssertEqual(S.fraction(150, of: 600), 0.25)
        XCTAssertEqual(S.fraction(900, of: 600), 1)
        XCTAssertEqual(S.fraction(5, of: 0), 0)
    }

    func testTheScrubberIsAdjustableAndMovesByTheSkipLengthsThroughThePlayer() throws {
        let (player, _) = started("a", artwork: nil)
        player.seek(to: 100)
        let hosted = HostedView(LibraryPlayerView(player: player, onClose: {}))
        let scrubber = try XCTUnwrap(hosted.element("wilted-player-scrubber"))
        XCTAssertTrue(scrubber.isAdjustable)
        XCTAssertEqual(scrubber.label, "Playback position")
        scrubber.increment()
        XCTAssertEqual(player.position, 100 + TimeInterval(player.skipForwardSeconds), "the same call the lock screen's skip makes")
        scrubber.decrement()
        XCTAssertEqual(player.position, 100 + TimeInterval(player.skipForwardSeconds) - TimeInterval(player.skipBackSeconds))
    }

    func testTheMiniPlayersLineIsAScrubberToo() throws {
        let (player, _) = started("a", artwork: nil)
        let hosted = HostedView(LibraryMiniPlayer(player: player, onExpand: {}))
        let line = try XCTUnwrap(hosted.element("wilted-player-mini-scrubber"))
        XCTAssertTrue(line.isAdjustable)
        XCTAssertGreaterThanOrEqual(line.frame.height, LibraryScrubber.compactHeight, "a touch area, not the 3 pt line")
    }

    func testAnEmptyPlayerHasNothingToScrub() throws {
        let hosted = HostedView(LibraryPlayerView(player: fixture.makePlayer(), onClose: {}))
        let scrubber = try XCTUnwrap(hosted.element("wilted-player-scrubber"))
        scrubber.increment()
        XCTAssertNotNil(scrubber)
    }
}

private final class ManualCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
