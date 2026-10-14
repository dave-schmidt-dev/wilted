import AppKit
import SwiftUI
import Vision
import WiltedProducer
import XCTest
@testable import WiltedMac

/// The discoverability surfaces this change owns: a playlist's rename and delete beside its name,
/// Add to Playlist as a visible Larder row action, and the player's named Share options control.
/// Every assertion reads what a shipping view draws or what its action writes, never a source
/// spelling.
@MainActor
final class WiltedMacPlaylistDiscoverabilityTests: XCTestCase {
    // MARK: - Destination title accessory

    func testDestinationTitleAccessoryDrawsOnTheTitleLineWithoutRepeatingTheTitle() throws {
        let view = WiltedMacDestination(
            title: "Morning Walk", identifier: "discoverability-destination",
            titleAccessory: { Text("Rename playlist") }
        ) {
            Text("Playlist contents")
        }
        let lines = try WiltedMacHeadless.recognizedLines(view, size: CGSize(width: 600, height: 300))
        let title = try XCTUnwrap(lines.first { $0.text.contains("Morning Walk") }, "\(lines)")
        let accessory = try XCTUnwrap(lines.first { $0.text.contains("Rename playlist") }, "\(lines)")
        XCTAssertEqual(lines.filter { $0.text.contains("Morning Walk") }.count, 1, "the title renders once: \(lines)")
        XCTAssertEqual(accessory.top, title.top, accuracy: 0.05, "the accessory shares the title's line: \(lines)")
        let body = try XCTUnwrap(lines.first { $0.text.contains("Playlist contents") })
        XCTAssertGreaterThan(body.top, title.top, "the title stays above the content: \(lines)")
    }

    func testPlaylistRenameAndDeleteDrawBesideTheNameWhilePlayStaysInTheActionRow() async throws {
        let fixture = try await WiltedMacPlaylistTests.makeFixture(
            "discoverability-title", count: 2, directory: wiltedTemporaryDirectory("discoverability-title"))
        let model = fixture.model
        let created = await model.createPlaylist(kind: .manual, name: "Morning Walk")
        let playlist = try XCTUnwrap(created)
        let size = CGSize(width: 760, height: 520)
        let bitmap = try WiltedMacHeadless.render(
            WiltedMacPlaylistView(model: model, playlistID: playlist.id), size: size)
        let observations = try textObservations(in: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            let frame = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            frame.name = "Playlist title actions"
            frame.lifetime = .keepAlways
            add(frame)
        }
        let title = try XCTUnwrap(observations.first { $0.text.contains("Morning Walk") },
                                  "\(observations.map(\.text))")
        XCTAssertEqual(observations.filter { $0.text.contains("Morning Walk") }.count, 1,
                       "the playlist name renders once: \(observations.map(\.text))")
        let play = try XCTUnwrap(observations.first { $0.text.contains("Play") }, "\(observations.map(\.text))")
        XCTAssertGreaterThan(title.box.minY, play.box.maxY, "Play stays in the action row below the title")
        // Vision includes adjacent icons in a title's box. Measure the words without the accessory
        // first, so the actual frame's detector scans where both icons must draw.
        let nameOnly = try WiltedMacHeadless.render(
            WiltedMacDestination(title: playlist.name, identifier: "name-only") { EmptyView() }, size: size)
        let nameBox = try XCTUnwrap(textObservations(in: nameOnly).first {
            $0.text.contains(playlist.name)
        }).box
        XCTAssertGreaterThan(
            nonWhitePixelCount(in: bitmap, rightOf: nameBox), 20,
            "rename and delete draw beside the name; text-only OCR bounds: \(nameBox)")
        await model.close()
    }

    // MARK: - Add to Playlist as a row action

    func testLarderEpisodeRowKeepsItsTitleDateAndThreeLinesWithTheRowAction() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        model.setTextScale(.standard)
        let episode = WiltedMacEpisode(
            id: "discoverability-episode", title: "Morning garden report", feedTitle: "Garden Radio",
            summary: "", artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 3_723, playbackSeconds: 0, downloadState: .completed,
            preparationState: .prepared(summary: "Ready"))
        model.installEpisodeForTesting(episode)
        let row = WiltedMacLarderView(model: model, paneMode: .side)
            .larderRow(episode, position: 1, count: 1, showsGroupName: false)
        let date = episode.releasedAt.formatted(date: .numeric, time: .omitted)
        let minimum = WiltedMacShellLayout.windowMinimumWidth(scale: .standard) - WiltedMacShellLayout.railWidth
        for width in [minimum, CGFloat(1_400)] {
            let lines = try WiltedMacHeadless.recognizedLines(row, size: CGSize(width: width, height: 200))
            var baselines: [CGFloat] = []
            for line in lines where !baselines.contains(where: { abs($0 - line.top) < 0.025 }) {
                baselines.append(line.top)
            }
            XCTAssertEqual(baselines.count, 3, "the row keeps its three lines at \(width): \(lines)")
            XCTAssertTrue(lines.contains { $0.text.contains("Morning") }, "the title stays at \(width): \(lines)")
            XCTAssertTrue(lines.contains { $0.text.contains(date) }, "the date stays at \(width): \(lines)")
            XCTAssertTrue(lines.contains { $0.text.contains("1h 02m") }, "the length stays at \(width): \(lines)")
        }
    }

    /// The row action draws inside the trailing slot the row reserves, and the compact shape is
    /// what lets the title column keep the date at the minimum window width.
    func testAddToPlaylistRowActionDrawsInACompactTrailingSlot() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let menu = WiltedMacAddToPlaylistMenu(model: model, entryID: "discoverability-row", style: .rowAction)
        let host = NSHostingView(rootView: menu)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        XCTAssertGreaterThan(size.width, 0, "the row action has a drawn size")
        XCTAssertLessThanOrEqual(size.width, 44, "the row action stays inside a compact trailing slot")
        XCTAssertLessThanOrEqual(size.height, 44, "the row action stays inside the row's height")
        let bitmap = try WiltedMacHeadless.render(
            menu.padding(8).frame(width: 64, height: 56).background(Color.white),
            size: CGSize(width: 64, height: 56))
        XCTAssertGreaterThan(lowLuminancePixelCount(in: bitmap), 10, "the row action draws its glyph")
    }

    func testLarderArticleRowStillRendersBesideTheRowAction() async throws {
        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready"], suffix: "article-discoverability")
        let article = try XCTUnwrap(model.articles.first)
        let lines = try WiltedMacHeadless.recognizedLines(
            WiltedMacLarderView(model: model, paneMode: .side), size: CGSize(width: 900, height: 700))
        XCTAssertTrue(lines.contains { $0.text.contains(article.title) },
                      "the article stays: \(lines.map(\.text))")
        XCTAssertTrue(lines.contains { $0.text.contains("1h 02m") || $0.text.contains("2m") },
                      "the article metadata stays: \(lines.map(\.text))")
        await model.close()
    }

    func testAddToPlaylistRowActionAddsTheEntryAndCanCreateItsOwnList() async throws {
        let fixture = try await WiltedMacPlaylistTests.makeFixture(
            "discoverability-action", count: 1, directory: wiltedTemporaryDirectory("discoverability-action"))
        let model = fixture.model
        let entryID = try XCTUnwrap(fixture.ids.first).rawValue
        let created = await model.createPlaylist(kind: .manual, name: "Morning Walk")
        let existing = try XCTUnwrap(created)
        await WiltedMacAddToPlaylistMenu.add(model: model, entryID: entryID, to: existing)
        XCTAssertEqual(model.playlists.entryIDs[existing.id], [entryID], "the visible action adds the entry")
        await WiltedMacAddToPlaylistMenu.createManualPlaylist(model: model, entryID: entryID)
        let newPlaylist = try XCTUnwrap(model.playlists.playlists.last)
        XCTAssertEqual(newPlaylist.kind, .manual)
        XCTAssertEqual(model.playlists.entryIDs[newPlaylist.id], [entryID], "New Playlist creates and fills one")
        await model.close()
    }

    func testPlaylistRenameAndDeleteActionsReachTheStore() async throws {
        let fixture = try await WiltedMacPlaylistTests.makeFixture(
            "discoverability-edit", count: 1, directory: wiltedTemporaryDirectory("discoverability-edit"))
        let model = fixture.model
        let created = await model.createPlaylist(kind: .manual, name: "Morning Walk")
        let playlist = try XCTUnwrap(created)
        await model.renamePlaylist(playlist.id, to: "Evening Walk")
        XCTAssertEqual(model.playlist(playlist.id)?.name, "Evening Walk")
        await model.deletePlaylist(playlist.id)
        XCTAssertNil(model.playlist(playlist.id))
        await model.close()
    }

    // MARK: - Share options

    func testShareComposerNamesItselfShareOptionsInThePlayerContext() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        model.installPlaybackStateForTesting(
            episode: episode(), isPlaying: false, position: 0, duration: 60)
        let lines = try WiltedMacHeadless.recognizedText(
            WiltedMacPlaybackShareLink(model: model).padding(12), size: CGSize(width: 360, height: 100))
        XCTAssertTrue(lines.contains { $0.localizedCaseInsensitiveContains("Share options") },
                      "the control names itself: \(lines)")
        XCTAssertFalse(lines.contains { $0.localizedCaseInsensitiveContains("transcript summary") },
                       "the summary popover stays closed until asked: \(lines)")
    }

    // MARK: - Helpers

    private func episode() -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: "discoverability-share", title: "Episode", feedTitle: "Show", summary: "Notes are not input.",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 60,
            playbackSeconds: 0, downloadState: .completed, isReadyMediaAvailable: true,
            feedURL: URL(string: "https://example.test/feed")!, episodeLink: URL(string: "https://example.test/episode"))
    }

    private func textObservations(in bitmap: NSBitmapImageRep) throws -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
    }

    private func lowLuminancePixelCount(in bitmap: NSBitmapImageRep, below threshold: CGFloat = 0.6) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = 0.299 * color.redComponent + 0.587 * color.greenComponent
                    + 0.114 * color.blueComponent
                if luminance < threshold { count += 1 }
            }
        }
        return count
    }

    /// Counts drawn pixels on the title's line just right of its text, where the rename and delete
    /// glyphs sit. Vision's boxes have a bottom-left origin; bitmap pixels are top-left.
    private func nonWhitePixelCount(in bitmap: NSBitmapImageRep, rightOf box: CGRect) -> Int {
        let width = CGFloat(bitmap.pixelsWide), height = CGFloat(bitmap.pixelsHigh)
        let minX = max(0, Int((box.maxX + 0.01) * width))
        let maxX = min(bitmap.pixelsWide - 1, Int((box.maxX + 0.16) * width))
        let top = max(0, Int((1 - box.maxY) * height) - 6)
        let bottom = min(bitmap.pixelsHigh - 1, Int((1 - box.minY) * height) + 6)
        guard minX < maxX, top < bottom else { return 0 }
        var count = 0
        for y in top...bottom {
            for x in minX...maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = 0.299 * color.redComponent + 0.587 * color.greenComponent
                    + 0.114 * color.blueComponent
                if luminance < 0.6 { count += 1 }
            }
        }
        return count
    }
}
