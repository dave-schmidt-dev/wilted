import SwiftUI
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacPlayerEpisodeInfoTests: XCTestCase {
    func testPlayingEpisodeTitleOpensInfoInPaneAndRail() async throws {
        let model = makeModel()
        let first = episode("first", title: "First episode")
        model.installPlaybackStateForTesting(episode: first, isPlaying: false, position: 0, duration: 120)
        let pane = try text(WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState())))
        let rail = try text(WiltedMacPlayerContent(
            model: model, presentation: .constant(nil), layout: .rail,
            focusRequest: nil, onCollapse: { _ in }))
        XCTAssertTrue(pane.contains(first.title), pane)
        XCTAssertTrue(rail.contains(first.title), rail)
        let source = model.episodeInfoSource(id: first.id, showTitle: first.feedTitle)
        let load = await source.loadInfo()
        guard case .loaded(let info) = load else { return XCTFail("\(load)") }
        XCTAssertEqual(info.notes, first.notes)
        let details = try text(WiltedMacEpisodeNotes(info: info, prefix: "wilted-player", source: source) {
            EmptyView()
        })
        XCTAssertTrue(details.contains("Notes for first"), details)
        XCTAssertTrue(details.contains("Transcript"), details)
        let playbackTranscript = model.currentTranscript
        _ = await source.loadTranscript()
        XCTAssertEqual(model.currentTranscript, playbackTranscript,
                       "the popover read must not replace the player's transcript")

        let next = episode("next", title: "Next episode")
        model.installPlaybackStateForTesting(episode: next, isPlaying: false, position: 0, duration: 120)
        let changed = try text(WiltedMacPlayerEpisodeTitle(
            model: model, title: next.title, font: .title, titleLineLimit: 2,
            labelIdentifier: "wilted-player-item-title"))
        XCTAssertTrue(changed.contains(next.title), changed)
        XCTAssertFalse(changed.contains(first.title), changed)

        let title = try WiltedMacHeadless.viewSource("WiltedMacPlayerEpisodeTitle.swift")
        XCTAssertTrue(title.contains("Button { isPresented = true }"))
        XCTAssertTrue(title.contains(".id(episode.id)"), "a new episode discards the old open state")
        XCTAssertTrue(title.contains(".accessibilityIdentifier(labelIdentifier)"))
        XCTAssertTrue(title.contains("wilted-player-show-notes-\\(episode.id)"))
        XCTAssertTrue(title.contains("source: model.episodeInfoSource(id: episode.id, showTitle: episode.feedTitle)"))
        for (file, limit) in [("WiltedMacNowPlayingPane.swift", 2), ("WiltedMacPlayerContent.swift", 1)] {
            let caller = try WiltedMacHeadless.viewSource(file)
            XCTAssertTrue(caller.contains("WiltedMacPlayerEpisodeTitle("))
            XCTAssertTrue(caller.contains("titleLineLimit: \(limit)"))
            XCTAssertTrue(caller.contains("labelIdentifier: \"wilted-player-item-title\""))
        }
        let root = try WiltedMacHeadless.viewSource("WiltedMacRootView.swift")
        XCTAssertTrue(root.contains("if shell.pane == .side"))
        XCTAssertTrue(root.contains("playerPresentation == nil && shell.pane == .bottom"),
                      "pane and rail must not expose duplicate title identifiers")
    }

    func testArticleAndIdleTitlesStayPlainText() throws {
        let model = makeModel()
        XCTAssertNil(model.currentEpisode)
        let idle = try text(WiltedMacPlayerEpisodeTitle(
            model: model, title: "Nothing playing", font: .body, titleLineLimit: 1,
            labelIdentifier: "wilted-player-item-title"))
        XCTAssertTrue(idle.contains("Nothing playing"), idle)
        model.installPlaybackStateForTesting(article: article(), isPlaying: false, position: 0, duration: 120)
        XCTAssertNil(model.currentEpisode)
        let shown = try text(WiltedMacPlayerEpisodeTitle(
            model: model, title: article().title, font: .title, titleLineLimit: 2,
            labelIdentifier: "wilted-player-item-title"))
        XCTAssertTrue(shown.contains(article().title), shown)
        let source = try WiltedMacHeadless.viewSource("WiltedMacPlayerEpisodeTitle.swift")
        XCTAssertTrue(source.contains("if let episode = model.currentEpisode"))
        XCTAssertTrue(source.contains("} else {\n            Text(title)"))
    }

    func testPlaylistEpisodeAndAudiobookRowsOpenInfoButArticlesDoNot() async throws {
        let model = makeModel()
        let episode = episode("playlist", title: "Playlist episode")
        model.installPlaybackStateForTesting(episode: episode, isPlaying: false, position: 0, duration: 120)
        for item in [WiltedMacLibraryItem.episode(episode), .audiobook(episode), .article(article())] {
            let rendered = try text(WiltedMacPlaylistItemTitle(model: model, item: item))
            XCTAssertTrue(rendered.contains(item.title), rendered)
        }
        let load = await model.episodeInfoSource(id: episode.id, showTitle: episode.feedTitle).loadInfo()
        guard case .loaded(let info) = load else { return XCTFail("\(load)") }
        XCTAssertEqual(info.id, episode.id)
        XCTAssertEqual(info.notes, "Notes for playlist")
        let content = try text(WiltedMacEpisodeNotes(
            episode: episode, prefix: "wilted-playlist",
            source: model.episodeInfoSource(id: episode.id, showTitle: episode.feedTitle)
        ) { EmptyView() })
        XCTAssertTrue(content.contains("Notes for playlist"), content)
        XCTAssertTrue(content.contains("Transcript"), content)
        let source = try WiltedMacHeadless.viewSource("WiltedMacPlaylistView.swift")
        XCTAssertTrue(source.contains("WiltedMacPlaylistItemTitle(model: model, item: item)"))
        XCTAssertTrue(source.contains("case .article(let article):\n            Text(article.title)"))
        XCTAssertTrue(source.contains("case .episode(let episode), .audiobook(let episode):"))
        XCTAssertTrue(source.contains("episode: episode, prefix: \"wilted-playlist\", isPresented: $isPresented"))
        XCTAssertTrue(source.contains("titleLineLimit: 2"))
    }

    private func makeModel() -> WiltedMacModel {
        WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
    }

    private func text<V: View>(_ view: V) throws -> String {
        try WiltedMacHeadless.recognizedText(view, size: CGSize(width: 900, height: 700))
            .joined(separator: " ")
    }

    private func episode(_ id: String, title: String) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: title, feedTitle: "Player show", summary: "Summary",
            notes: "Notes for \(id)", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 120,
            playbackSeconds: 0, downloadState: .completed, preparationState: .prepared(summary: "Clean"))
    }

    private func article() -> WiltedMacArticle {
        WiltedMacArticle(
            id: "article", title: "Article title", source: "example.test",
            url: URL(string: "https://example.test/article")!, isReady: true, durationSeconds: 120)
    }
}
