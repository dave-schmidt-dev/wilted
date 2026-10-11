import AppKit
import SwiftUI
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

extension WiltedPixelSnapshotTests {
    /// Real waiting/download counts at the minimum and full detail widths.
    func testRealSizeLarderHeaderPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            for (kind, width) in [("minimum", 520.0), ("full", 1000.0)] {
                let model = WiltedMacRealSizeLarderFixture.make(self, "real-header-pixel-\(kind)-\(appearance)")
                XCTAssertEqual(model.podcastQueueIDs.count, 64)
                XCTAssertEqual(model.larderDownloadableEpisodes.count, 43)
                let image = render(
                    WiltedMacLarderView(model: model, paneMode: .bottom),
                    variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                    size: CGSize(width: width, height: 560))
                assertSnapshot(
                    image,
                    named: WiltedSnapshotContract.shellName(kind: "larder-real-size-\(kind)", appearance: appearance),
                    testName: "testRealSizeLarderHeaderPixelBaselines")
            }
        }
    }

    // MARK: Larder kinds and audiobooks

    /// A book as the Larder queues it: one single-file volume with chapter marks.
    private func fixtureBook() -> WiltedMacEpisode {
        var book = WiltedMacEpisode(
            id: "book-dune-0", title: "Dune", feedTitle: "Audiobook", summary: "Frank Herbert", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_700_000_900), durationSeconds: 21 * 3_600 + 35 * 60,
            playbackSeconds: 5_400, downloadState: .completed, preparationState: .prepared(summary: "Audiobook"))
        book.audiobook = WiltedMacAudiobookDetails(
            author: "Frank Herbert",
            chapters: [
                WiltedMacChapter(title: "Book One: Dune", startSeconds: 0),
                WiltedMacChapter(title: "Book Two: Muad'Dib", startSeconds: 4_800),
                WiltedMacChapter(title: "Book Three: The Prophet", startSeconds: 9_600),
            ],
            sourceFormat: "audio", volumeIndex: 0, volumeCount: 1)
        return book
    }

    private func larderModel(_ name: String) -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            preferences: WiltedMacTestPreferences.ephemeral())
        let book = fixtureBook()
        model.installEpisodeForTesting(book)
        model.podcastQueueIDs.append(book.id)
        return model
    }

    /// The whole Larder under the All filter: the kind menu beside Group and Sort, and articles,
    /// episodes and a book as rows in the one grouped list.
    func testLarderKindFilterPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let model = larderModel("larder-kind-filter")
            XCTAssertEqual(model.larderKind, .all)
            let image = render(
                WiltedMacLarderView(model: model, paneMode: .side),
                variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 760, height: 560))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the Larder drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "larder-kind-filter", appearance: appearance),
                testName: "testLarderKindFilterPixelBaselines")
        }
    }

    /// A book row follows the same title, feed–length and date geometry as episodes.
    func testLarderBookRowPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let model = larderModel("larder-book-row")
            let book = try XCTUnwrap(model.episodes.first { $0.id == "book-dune-0" })
            let larder = WiltedMacLarderView(model: model, paneMode: .side)
            let content = larder.larderRow(book, position: 1, count: 1, showsGroupName: false)
                .padding(WiltedTheme.Spacing.large)
                .environment(\.wiltedTextScale, model.textScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(WiltedTheme.color(.card, scheme: appearance == .dark ? .dark : .light))
            let image = render(
                content, variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 760, height: 110))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the book row drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "larder-book-row", appearance: appearance),
                testName: "testLarderBookRowPixelBaselines")
        }
        let model = larderModel("larder-book-row-text")
        let book = try XCTUnwrap(model.episodes.first { $0.id == "book-dune-0" })
        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacLarderView(model: model, paneMode: .side).larderRow(book, position: 1, count: 1, showsGroupName: false),
            size: CGSize(width: 760, height: 110)).joined(separator: " ")
        XCTAssertTrue(shown.contains("Audiobook"), shown)
        XCTAssertTrue(shown.contains("21h 35m"), shown)
        XCTAssertTrue(shown.contains(book.presentation.publicationLabel), shown)
    }

    /// The player while a book plays: the chapter under the playhead and the previous and next steps.
    func testPlayerChaptersPixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let model = larderModel("player-chapters")
            let book = try XCTUnwrap(model.episodes.first { $0.id == "book-dune-0" })
            model.installPlaybackStateForTesting(
                episode: book, isPlaying: false, position: 5_400, duration: book.durationSeconds ?? 0,
                queue: model.podcastQueueIDs)
            XCTAssertEqual(model.currentChapterTitle, "Book Two: Muad'Dib")
            let image = render(
                WiltedMacFullWindowPlayer(
                    model: model, presentation: .constant(nil), onSelect: { _ in }, onCollapse: { _ in }),
                variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 900, height: 480))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the player drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "player-chapters", appearance: appearance),
                testName: "testPlayerChaptersPixelBaselines")
        }
    }
}
