import Foundation
import SwiftUI
import UIKit
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
extension LibraryLarderTests {
    // MARK: phone row progress

    func testPhoneRowShowsTimeLeftProgressAndPlayedLikeTheCarRows() {
        let r = row("a", show: "Alpha", published: 0, duration: 600)
        let date = r.publishedAt.formatted(.dateTime.month(.abbreviated).day().year())
        let started = EpisodeProgress(positionSeconds: 150, lastPlayedAt: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(r.showAndDurationText(), "Alpha - 10:00", "line two keeps only the show and the duration")
        XCTAssertEqual(r.publicationDateText, date, "line three is the date alone")
        XCTAssertEqual(LibraryRowView.listeningStatus(row: r, progress: nil, completed: false), "New")
        XCTAssertEqual(LibraryRowView.listeningStatus(row: r, progress: started, completed: false), "07:30 left")
        XCTAssertNil(LibraryRowView.listeningStatus(row: r, progress: started, completed: true),
                     "Played remains the separate completion label")
        XCTAssertEqual(CarEpisodeList.fraction(started, duration: 600), 0.25)
        // The car row carries the same time left for the same data.
        XCTAssertTrue(CarEpisodeList.detail(r, progress: started).hasSuffix("07:30 left"))
        let untimed = row("b", duration: nil)
        let untimedDate = untimed.publishedAt.formatted(.dateTime.month(.abbreviated).day().year())
        XCTAssertEqual(untimed.showAndDurationText(), "Show - Unknown")
        XCTAssertEqual(untimed.publicationDateText, untimedDate)
        XCTAssertNil(LibraryRowView.listeningStatus(row: untimed, progress: started, completed: false))
        XCTAssertNil(CarEpisodeList.fraction(started, duration: nil))

        XCTAssertEqual(LibraryRowView.listeningStatus(
            row: r, progress: EpisodeProgress(positionSeconds: 900, lastPlayedAt: started.lastPlayedAt), completed: false),
            "00:00 left", "remaining time clamps at the end")
        var invalid = r
        invalid.durationSeconds = .infinity
        XCTAssertNil(LibraryRowView.listeningStatus(row: invalid, progress: nil, completed: false))
        invalid.durationSeconds = .nan
        XCTAssertNil(LibraryRowView.listeningStatus(row: invalid, progress: nil, completed: false))
    }
    func testLongShowMetadataKeepsWholeDateAtPhoneWidths() throws {
        try assertFactualMetadata(showsShowName: true)
    }

    func testGroupedMetadataKeepsWholeDurationAndDate() throws {
        try assertFactualMetadata(showsShowName: false)
    }

    private func assertFactualMetadata(showsShowName: Bool) throws {
        let episode = row("long-show", title: "Metadata layout",
            show: "An exceptionally long program name that keeps going across the entire metadata line",
            published: 1_700_000_000, duration: 600)
        let expectedDate = LibraryDateFormat.day(episode.publishedAt)
        for width: CGFloat in [320, 390] {
            for scheme in [ColorScheme.light, .dark] {
                let capture = try PhoneLayoutCapture(
                    LibraryRowView(row: episode, media: .onPhone, onPlay: {}, deviceKind: "iPhone", showsShowName: showsShowName),
                    width: width, scheme: scheme)
                XCTAssertNotNil(capture.paintedLine(containing: expectedDate),
                    "The complete date must be rendered, not a clipped prefix: \(capture.text)")
                XCTAssertNotNil(capture.paintedLine(containing: "10:00"), "Total duration remains visible: \(capture.text)")
                let attachment = XCTAttachment(image: capture.image)
                attachment.name = "larder-date-\(showsShowName ? "ungrouped" : "grouped")-\(Int(width))-\(scheme == .dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testPodcastLarderRowsRenderAtPhoneWidthInLightAndDark() throws {
        let published = Date(timeIntervalSince1970: 1790942400)
        let episode = row("render-podcast", title: "A practical guide to everyday listening",
                          show: "Everyday Listening", published: published.timeIntervalSince1970,
                          duration: 600)
        let partial = EpisodeProgress(positionSeconds: 150, lastPlayedAt: published)
        for scheme in [ColorScheme.light, .dark] {
            for started in [false, true] {
                let content = LibraryRowView(row: episode, media: .onPhone, onPlay: {}, deviceKind: "iPhone",
                                             progress: started ? partial : nil)
                    .padding(16)
                    .frame(width: 390)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: scheme))
                    .background(WiltedTheme.color(.page, scheme: scheme))
                    .environment(\.colorScheme, scheme)
                    .environment(\.locale, Locale(identifier: "en_US"))
                let renderer = ImageRenderer(content: content)
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage, "the shipping podcast row must render")
                XCTAssertEqual(image.size.width, 390, accuracy: 0.1)
                XCTAssertGreaterThan(image.size.height, 44)
                XCTAssertNotNil(image.cgImage)
                let attachment = XCTAttachment(image: image)
                attachment.name = "larder-podcast-row-\(scheme == .dark ? "dark" : "light")-\(started ? "partial" : "new")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
