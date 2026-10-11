import AppKit
import SwiftUI
import Vision
import XCTest
@testable import WiltedMac

/// The owner's real counts, projected without live downloads or the preview's extra article.
@MainActor
enum WiltedMacRealSizeLarderFixture {
    static func make(_ testCase: XCTestCase, _ name: String) -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: testCase.wiltedTemporaryDirectory(name),
            preferences: WiltedMacTestPreferences.ephemeral())
        model.articles = []
        model.selectedArticleID = nil
        model.currentPodcastEpisodeID = nil
        model.episodes = (0..<64).map { index in
            let download: WiltedMacEpisodeDownloadState
            let preparation: WiltedMacEpisodePreparationState
            switch index {
            case 0..<10: download = .completed; preparation = .prepared(summary: "Ready")
            case 10..<12: download = .completed; preparation = .notPrepared
            case 12..<21: download = .downloading(received: 25, expected: 100); preparation = .notPrepared
            default: download = .notDownloaded; preparation = .notPrepared
            }
            return WiltedMacEpisode(
                id: "real-header-\(index)",
                title: "A long episode title about the machines and people shaping tomorrow \(index)",
                feedTitle: "The Artificial Intelligence Daily Brief: Technology, Research and Practical News",
                summary: "", artworkURL: nil,
                releasedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400),
                durationSeconds: 1_800, playbackSeconds: 0,
                downloadState: download, preparationState: preparation)
        }
        model.podcastQueueIDs = model.episodes.map(\.id)
        model.selectedNavigation = .larder
        model.larderFilter = .available
        model.larderGrouping = .status
        return model
    }
}

@MainActor
final class WiltedMacLarderHeaderTests: XCTestCase {
    private func lines(in bitmap: NSBitmapImageRep) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func attach(_ bitmap: NSBitmapImageRep, named name: String) throws {
        let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: bitmap.size))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func matches(_ pattern: String, in text: String) throws -> Int {
        try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            .numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func testRealSizeLarderHeaderKeepsLabelsAndEachFactOnce() async throws {
        let model = WiltedMacRealSizeLarderFixture.make(self, "real-header-regression")
        XCTAssertTrue(model.articles.isEmpty, "the preview article must not become a 65th row")
        XCTAssertEqual(model.podcastQueueIDs.count, 64)
        XCTAssertEqual(model.larderUnfilteredEpisodes(in: .playable).count, 10)
        XCTAssertEqual(model.larderUnfilteredEpisodes(in: .downloaded).count, 2)
        XCTAssertEqual(model.larderUnfilteredEpisodes(in: .available).count, 52)
        XCTAssertEqual(model.larderDownloadsInFlight.count, 9)
        XCTAssertEqual(model.larderDownloadableEpisodes.count, 43)
        for scale in [WiltedTheme.TextScale.standard, .large] {
            model.setTextScale(scale)
            for width in [WiltedMacShellLayout.windowMinimumWidth(scale: scale), CGFloat(1400)] {
                model.isSidebarVisible = false
                let bitmap = try WiltedMacHeadless.render(
                    WiltedMacRootView(model: model), size: CGSize(width: width, height: 900))
                XCTAssertEqual(bitmap.pixelsWide, Int(width), "whole-window width has no external OCR padding")
                let text = try lines(in: bitmap).joined(separator: " ")
                XCTAssertEqual(try matches("Ready\\s*:?\\s*10(?![0-9])(?: episodes)?", in: text), 1,
                               "the Ready count is one fact at width\(width): \(text)")
                XCTAssertEqual(try matches("Downloading\\s+9(?![0-9])", in: text), 1,
                               "one download progress fact: \(text)")
                XCTAssertEqual(try matches("Download all new\\s*\\(43\\)", in: text), 1,
                               "the complete actionable label includes43 once: \(text)")
                XCTAssertTrue(text.contains("Not downloaded"), "the complete group label remains visible: \(text)")
                let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: bitmap.size))
                attachment.name = "real-header-\(Int(width))-\(scale.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let section = try XCTUnwrap(model.larderSections().first { $0.statusGroup == .available })
        model.setTextScale(.standard)
        for width in [CGFloat(520), CGFloat(1000)] {
            let larder = WiltedMacLarderView(model: model, paneMode: .bottom)
            let toolbar = try WiltedMacHeadless.render(
                larder.filterBar(colorScheme: .light).frame(width: width, height: 150, alignment: .topLeading)
                    .environment(\.wiltedTextScale, model.textScale)
                    .background(WiltedTheme.color(.page, scheme: .light)),
                size: CGSize(width: width, height: 150))
            try attach(toolbar, named: "actual-bulk-toolbar-\(Int(width))")
            let toolbarText = try lines(in: toolbar).joined(separator: " ")
            XCTAssertEqual(try matches("Download all new\\s*\\(43\\)", in: toolbarText), 1,
                           "the complete global action names all43 actionable rows: \(toolbarText)")
            let header = larder.groupHeader(section, colorScheme: .light)
            let bitmap = try WiltedMacHeadless.render(
                header.frame(width: width, height: 150, alignment: .topLeading)
                    .background(WiltedTheme.color(.page, scheme: .light)),
                size: CGSize(width: width, height: 150))
            try attach(bitmap, named: "available-group-header-\(Int(width))")
            let text = try lines(in: bitmap).joined(separator: " ")
            XCTAssertTrue(text.contains("Not downloaded"), "the actual group heading never truncates: \(text)")
            XCTAssertTrue(text.contains("Remove all 52 from Larder"),
                          "the actual group removal label is complete, including its52 rows: \(text)")
        }
        await model.close()
    }

    private func readerModel(_ name: String) -> WiltedMacModel {
        let model = WiltedMacRealSizeLarderFixture.make(self, name)
        let episode = WiltedMacEpisode(
            id: "reader-fixture", title: "Reader fixture", feedTitle: "Synthetic show", summary: "",
            notes: "Notes begin clearly.\n\n" + String(repeating: "More notes to keep this reader scrollable.\n", count: 30),
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 1_800, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        model.episodes = [episode]
        model.podcastQueueIDs = [episode.id]
        model.currentPodcastEpisodeID = episode.id
        return model
    }

    func testNotesFirstLineIsUnclippedAtMinimumReaderHeight() async throws {
        let model = readerModel("notes-first-line")
        for width in [CGFloat(420), CGFloat(480)] {
            let bitmap = try WiltedMacHeadless.render(
                WiltedMacNotesPanel(model: model)
                    .frame(width: width, height: 120, alignment: .topLeading)
                    .background(WiltedTheme.color(.page, scheme: .light)),
                size: CGSize(width: width, height: 120))
            XCTAssertEqual(bitmap.pixelsWide, Int(width))
            try attach(bitmap, named: "notes-direct-\(Int(width))-120")
            XCTAssertTrue(try lines(in: bitmap).contains { $0.contains("Notes begin clearly.") },
                          "the complete first feed-provided line remains visible")
            let pane = try WiltedMacHeadless.render(
                WiltedMacNowPlayingPane(model: model, state: .constant(.init(tab: .notes))),
                size: CGSize(width: width, height: 700))
            try attach(pane, named: "notes-shipping-\(Int(width))-700")
            XCTAssertTrue(try lines(in: pane).contains { $0.contains("Notes begin clearly.") },
                          "the shipping tabs do not clip the first Notes line")
            let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(pane.cgImage), size: pane.size))
            attachment.name = "notes-first-line-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        await model.close()
    }

    func testTranscriptReaderDoesNotRepeatItsOuterSectionTitle() async throws {
        let model = readerModel("transcript-heading")
        for synchronized in [false, true] {
            model.currentTranscript = WiltedMacTranscript(
                availability: .available, text: "Words from the episode remain readable.",
                cues: synchronized ? [.init(id: 0, startSeconds: 0, endSeconds: 10,
                    text: "Words from the episode remain readable.", speaker: nil)] : [])
            let view = VStack(alignment: .leading) {
                Text("Transcript")
                WiltedMacTranscriptPanel(model: model, viewportHeight: nil)
            }
            let bitmap = try WiltedMacHeadless.render(
                view.frame(width: 420, height: 200, alignment: .topLeading)
                    .background(WiltedTheme.color(.page, scheme: .light)),
                size: CGSize(width: 420, height: 200))
            try attach(bitmap, named: "transcript-\(synchronized ? "synced" : "untimed")-420-200")
            let text = try lines(in: bitmap).joined(separator: " ")
            XCTAssertEqual(try matches("Transcript", in: text), 1,
                           "the outer section names the reader once: \(text)")
            XCTAssertTrue(text.contains("Words from the episode remain readable"),
                          "the selected reader does not hide untimed prose inside another disclosure: \(text)")
        }
        await model.close()
    }
}
