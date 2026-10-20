import SwiftUI
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// A Larder row's three info lines, as on the Mac: the title on one line, "Show - duration" on the
/// second, and the publication date alone on the third.
@MainActor
final class LibraryRowInfoLinesTests: XCTestCase {
    override func setUp() async throws { await HostedAccessibility.prepare() }

    private let published = Date(timeIntervalSince1970: 1_790_942_400)
    private var dateText: String { LibraryDateFormat.day(published) }

    private func row(
        _ raw: String = "a", title: String = "A title", show: String = "The Show", duration: Double? = 600,
        kind: LibraryKind = .podcastEpisode
    ) -> LibraryRow {
        LibraryRow(
            id: try! ItemID(rawValue: raw), title: title, showTitle: show,
            durationText: duration.map(LibraryClockFormat.duration), durationSeconds: duration,
            removal: .none, publishedAt: published, removalText: nil, checkpointText: nil, kind: kind)
    }

    // MARK: the text of lines two and three

    func testLineTwoNamesTheShowAndTheDurationAndLineThreeTheDate() {
        let episode = row()
        XCTAssertEqual(episode.showAndDurationText(), "The Show - 10:00")
        XCTAssertEqual(episode.publicationDateText, dateText)
        XCTAssertTrue(dateText.range(of: #"^[A-Z][a-z]{2} \d{1,2}, \d{4}$"#, options: .regularExpression) != nil, dateText)
    }

    func testARowUnderAFeedSectionHeaderLeavesTheShowOutOfLineTwo() {
        let episode = row()
        XCTAssertEqual(episode.showAndDurationText(namesShow: false), "10:00")
        XCTAssertEqual(episode.publicationDateText, dateText, "the date is unchanged under a section header")
    }

    func testAnUnknownShowAndAnUnknownDurationAreNamedAsSuch() {
        XCTAssertEqual(row(show: "").showAndDurationText(), "Show unknown - 10:00")
        XCTAssertEqual(row(show: " \n ").showAndDurationText(), "Show unknown - 10:00")
        XCTAssertEqual(row(duration: nil).showAndDurationText(), "The Show - Unknown")
        XCTAssertEqual(row(show: "", duration: nil).showAndDurationText(), "Show unknown - Unknown")
        XCTAssertEqual(row(duration: nil).showAndDurationText(namesShow: false), "Unknown")
        XCTAssertEqual(row(show: "  Padded  ").showAndDurationText(), "Padded - 10:00", "padding is trimmed")
    }

    func testTheOneLineDetailOtherCallersUseIsUnchanged() {
        XCTAssertEqual(row().detailText(), "The Show - 10:00 - \(dateText)")
        XCTAssertEqual(row().detailText(namesShow: false), "10:00 - \(dateText)")
        XCTAssertEqual(row(show: "", duration: nil).detailText(), "Show unknown - Unknown - \(dateText)")
    }

    // MARK: what the row paints and VoiceOver reads

    private func hosted(_ episode: LibraryRow, namesShow: Bool = true, width: CGFloat = 390) -> HostedView<some View> {
        HostedView(
            LibraryRowView(row: episode, media: .onPhone, onPlay: {}, deviceKind: "iPhone", showsShowName: namesShow).padding(16),
            size: CGSize(width: width, height: 400))
    }

    func testTheRowCarriesTheShowAndDurationLineAndTheDateLineAsTwoElements() throws {
        let view = hosted(row())
        let meta = try XCTUnwrap(view.element("wilted-library-meta-a"))
        let date = try XCTUnwrap(view.element("wilted-library-date-a"))
        XCTAssertEqual(meta.label, "The Show - 10:00")
        XCTAssertEqual(date.label, dateText)
        let spoken = [meta.label, date.label].compactMap { $0 }.joined(separator: " ")
        for part in ["The Show", "10:00", dateText] {
            XCTAssertEqual(spoken.components(separatedBy: part).count - 1, 1, "\(part) is read exactly once: \(spoken)")
        }
    }

    func testTheDateSitsOnItsOwnLineBelowTheShowAndDuration() throws {
        let view = hosted(row())
        let title = try XCTUnwrap(view.element("wilted-library-title-a"))
        let meta = try XCTUnwrap(view.element("wilted-library-meta-a"))
        let date = try XCTUnwrap(view.element("wilted-library-date-a"))
        XCTAssertLessThanOrEqual(title.frame.maxY, meta.frame.minY + 1, "title, then show and duration")
        XCTAssertLessThanOrEqual(meta.frame.maxY, date.frame.minY + 1, "the date is below, not beside")
        XCTAssertEqual(date.frame.minX, meta.frame.minX, accuracy: 1, "both lines start at the same edge")
    }

    func testAFeedSectionRowDropsTheShowFromTheSecondLine() throws {
        let view = hosted(row(), namesShow: false)
        XCTAssertEqual(try XCTUnwrap(view.element("wilted-library-meta-a")).label, "10:00")
        XCTAssertEqual(try XCTUnwrap(view.element("wilted-library-date-a")).label, dateText)
    }

    func testAnUnknownShowAndDurationAreReadOnTheSecondLine() throws {
        let view = hosted(row(show: "", duration: nil))
        XCTAssertEqual(try XCTUnwrap(view.element("wilted-library-meta-a")).label, "Show unknown - Unknown")
        XCTAssertEqual(try XCTUnwrap(view.element("wilted-library-date-a")).label, dateText)
    }

    func testAReportKeepsItsIconAndTheSameTwoLines() throws {
        let view = hosted(row(kind: .report))
        XCTAssertEqual(try XCTUnwrap(view.element("wilted-library-meta-a")).label, "The Show - 10:00",
                       "the newspaper icon is decoration, not part of what is read")
        XCTAssertEqual(try XCTUnwrap(view.element("wilted-library-date-a")).label, dateText)
    }

    func testALongTitleStaysOnOneLine() throws {
        let short = hosted(row(title: "Short"))
        let long = hosted(row(title: String(repeating: "A much longer title than one line holds ", count: 6)))
        let shortTitle = try XCTUnwrap(short.element("wilted-library-title-a"))
        let longTitle = try XCTUnwrap(long.element("wilted-library-title-a"))
        XCTAssertEqual(longTitle.frame.height, shortTitle.frame.height, accuracy: 0.5, "one line, cut with an ellipsis")
    }

    func testALongShowYieldsToTheWholeDurationAndDateAtPhoneWidths() throws {
        let longShow = "An exceptionally long program name that keeps going across the entire metadata line"
        for width: CGFloat in [320, 390] {
            let capture = try PhoneLayoutCapture(
                LibraryRowView(row: row(show: longShow), media: .onPhone, onPlay: {}, deviceKind: "iPhone"), width: width, scheme: .light)
            let dateLine = try XCTUnwrap(capture.paintedLine(containing: dateText), "the date is whole: \(capture.text)")
            let durationLine = try XCTUnwrap(capture.paintedLine(containing: "10:00"), "the duration is whole: \(capture.text)")
            XCTAssertLessThan(dateLine.box.midY, durationLine.box.midY, "the date is under the show and duration at \(width)")
            XCTAssertFalse(dateLine.text.contains("10:00"), "the date has a line to itself: \(dateLine.text)")
            XCTAssertFalse(durationLine.text.contains(dateText), "the duration's line holds no date: \(durationLine.text)")
        }
    }

    /// On an iPad the checkpoint line names the iPad, never "this iPhone".
    func testCheckpointLineOnAnIPadNamesTheIPad() {
        XCTAssertEqual(LibraryCheckpointLine.localText(isPlaying: true, position: 252, deviceKind: "iPad"),
                       "Playing on this iPad at 04:12")
        XCTAssertEqual(LibraryCheckpointLine.localText(isPlaying: false, position: 3_725, deviceKind: "iPad"),
                       "Paused on this iPad at 1:02:05")
    }
}
