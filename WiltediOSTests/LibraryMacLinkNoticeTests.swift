import SwiftUI
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// CLEAR rule 12: while the Mac has not linked this device, the Larder never offers a download it cannot
/// get. One notice says why; audio already on the phone still plays and can still be removed; and the
/// downloads return the moment the link arrives, with no relaunch.
@MainActor
final class LibraryMacLinkNoticeTests: XCTestCase {
    private var fixture: LibraryViewFixture!

    override func setUp() async throws { await HostedAccessibility.prepare() }
    override func tearDown() async throws { fixture?.tearDown() }

    /// a: on the phone, b: listed before upload, c: the Mac said not ready earlier, d: a failed download.
    private func hostedLarder(linked: Bool) async throws -> HostedView<some View> {
        fixture = try LibraryViewFixture(linked: linked)
        try await fixture.queue(["a", "b", "c", "d"])
        try await fixture.offer("a")
        try await fixture.cacheAudio("a")
        try await fixture.offer("b", .available)
        try await fixture.offer("d", .available)
        await fixture.model.refresh()
        fixture.model.media[fixture.id("d")] = .failed("The connection was lost.")
        fixture.model.deviceLinked = linked // a refresh must not have changed what the test set up
        return HostedView(NavigationStack { LibraryListView(model: fixture.model, onPlay: { _ in }) })
    }

    private let downloadIDs = ["wilted-library-media-get-b", "wilted-library-media-retry-d"]

    func testAnUnlinkedLarderShowsOneNoticeAndOffersNoDownload() async throws {
        let hosted = try await hostedLarder(linked: false)

        let notice = try XCTUnwrap(hosted.element("wilted-library-mac-link-notice"), "the notice is on screen")
        XCTAssertEqual(hosted.elements().filter { $0.identifier == "wilted-library-mac-link-notice" }.count, 1)
        let label = try XCTUnwrap(notice.label)
        XCTAssertTrue(label.contains(LibraryMacLinkNotice.title), label)
        XCTAssertTrue(label.contains(LibraryMacLinkNotice.detail(deviceKind: fixture.model.deviceKind)), label)
        for identifier in downloadIDs {
            XCTAssertNil(hosted.element(identifier), "\(identifier): no Get audio, Retry or Check again while unlinked")
        }
        XCTAssertNil(hosted.element("wilted-library-media-retry-c"))
    }

    func testAnUnlinkedRowsSwipeAndVoiceOverActionsOfferNoDownload() async throws {
        let hosted = try await hostedLarder(linked: false)
        let missing = try XCTUnwrap(hosted.element("wilted-library-title-b")).customActionNames
        XCTAssertFalse(missing.contains("Download"), "\(missing)")
        XCTAssertFalse(try XCTUnwrap(hosted.element("wilted-library-title-d")).customActionNames.contains("Download"))
        XCTAssertEqual(LibrarySwipe.trailing(media: .available, isPlaying: false, canRequest: false), [])
        XCTAssertEqual(LibrarySwipe.trailing(media: .failed("x"), isPlaying: false, canRequest: false), [])
        XCTAssertEqual(LibrarySwipe.trailing(media: .notPrepared, isPlaying: false, canRequest: false), [])
    }

    func testAudioAlreadyOnThePhoneStillPlaysAndCanBeRemoved() async throws {
        let hosted = try await hostedLarder(linked: false)
        XCTAssertNotNil(hosted.element("wilted-library-media-remove-a"), "Delete download stays")
        XCTAssertTrue(try XCTUnwrap(hosted.element("wilted-library-title-a")).customActionNames.contains("Play"))
        XCTAssertEqual(LibrarySwipe.trailing(media: .onPhone, isPlaying: false, canRequest: false), [.play])
    }

    func testALinkedLarderShowsNoNoticeAndOffersTheDownloads() async throws {
        let hosted = try await hostedLarder(linked: true)

        XCTAssertNil(hosted.element("wilted-library-mac-link-notice"))
        for identifier in downloadIDs { XCTAssertNotNil(hosted.element(identifier), identifier) }
        XCTAssertTrue(try XCTUnwrap(hosted.element("wilted-library-title-b")).customActionNames.contains("Download"))
    }

    func testTheDownloadsReturnAndTheNoticeGoesWhenTheLinkArrivesWithoutARelaunch() async throws {
        let before = try await hostedLarder(linked: false)
        XCTAssertNotNil(before.element("wilted-library-mac-link-notice"))
        XCTAssertNil(before.element("wilted-library-media-get-b"))

        // The Mac links the phone: the same model, no refresh and no relaunch, is all the Larder needs.
        fixture.model.deviceLinked = true
        let after = HostedView(NavigationStack { LibraryListView(model: fixture.model, onPlay: { _ in }) })

        XCTAssertNil(after.element("wilted-library-mac-link-notice"))
        XCTAssertNotNil(after.element("wilted-library-media-get-b"))
        XCTAssertNotNil(after.element("wilted-library-media-retry-d"))
        XCTAssertTrue(try XCTUnwrap(after.element("wilted-library-title-b")).customActionNames.contains("Download"))
    }

    func testTheEpisodeDetailOffersNoDownloadWhileUnlinked() async throws {
        _ = try await hostedLarder(linked: false)
        let unlinked = HostedView(NavigationStack { LibraryEpisodeDetailView(model: fixture.model, entryID: fixture.id("b")) })
        XCTAssertNil(unlinked.element("wilted-library-media-get-b"))
        fixture.model.deviceLinked = true
        let linked = HostedView(NavigationStack { LibraryEpisodeDetailView(model: fixture.model, entryID: fixture.id("b")) })
        XCTAssertNotNil(linked.element("wilted-library-media-get-b"))
    }

    func testTheNoticeNamesTheDeviceFamilyAndLeavesWithAnAccountReview() async throws {
        XCTAssertEqual(LibraryMacLinkNotice.detail(deviceKind: "iPad"),
                       "Downloads start once your Mac links this iPad. Keep Wilted open on your Mac.")
        XCTAssertEqual(LibraryMacLinkNotice.detail(deviceKind: "iPhone"),
                       "Downloads start once your Mac links this iPhone. Keep Wilted open on your Mac.")
        XCTAssertEqual(LibraryMacLinkNotice.title, "Connecting to your Mac")

        fixture = try LibraryViewFixture(linked: false)
        XCTAssertTrue(fixture.model.showsMacLinkNotice)
        fixture.model.deviceLinked = true
        XCTAssertFalse(fixture.model.showsMacLinkNotice)
    }
}
