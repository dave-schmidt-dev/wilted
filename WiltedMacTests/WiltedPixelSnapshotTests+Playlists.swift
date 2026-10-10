import AppKit
import SwiftUI
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Playlist surfaces: the sidebar's Playlists section, a manual playlist's page and the rule editor.
extension WiltedPixelSnapshotTests {
    private func playlistFixture(_ name: String) async throws -> WiltedMacPlaylistTests.Fixture {
        try await WiltedMacPlaylistTests.makeFixture(name, count: 3, directory: wiltedTemporaryDirectory(name))
    }

    private func newPlaylist(_ model: WiltedMacModel, _ kind: PlaylistKind, _ name: String) async throws -> Playlist {
        let made = await model.createPlaylist(kind: kind, name: name)
        return try XCTUnwrap(made)
    }

    private func variant(_ appearance: WiltedAppearance) -> WiltedVisualVariant {
        .init(appearance: appearance, dynamicType: .standard, reduceMotion: false)
    }

    /// The section heading and two playlist rows, one selected, as the sidebar column draws them.
    func testSidebarPlaylistsSectionPixelBaselines() async throws {
        for appearance in WiltedAppearance.allCases {
            let fixture = try await playlistFixture("sidebar-playlists")
            let model = fixture.model
            let manual = try await newPlaylist(model, .manual, "Morning Walk")
            _ = await model.createPlaylist(kind: .automatic, name: "Unplayed Shorts")
            model.selectedNavigation = .playlist(manual.id)
            let sidebar = WiltedMacSidebar(model: model, mode: .full) { model.selectedNavigation = $0 }
            let width = WiltedTheme.scaled(WiltedMacShellLayout.sidebarIdealWidth, scale: model.textScale)
            let content = VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                sidebar.row(.larder)
                sidebar.playlistsHeader
                ForEach(model.playlists.playlists, id: \.id) { sidebar.playlistRow($0) }
                Spacer(minLength: 0)
            }
            .padding(WiltedTheme.Spacing.small)
            .background(WiltedTheme.color(.page, scheme: appearance == .dark ? .dark : .light))
            .environment(\.wiltedTextScale, model.textScale)
            let image = render(content, variant: variant(appearance), size: CGSize(width: width, height: 180))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the playlists section drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "sidebar-playlists", appearance: appearance),
                testName: "testSidebarPlaylistsSectionPixelBaselines")
            await model.close()
        }
    }

    /// A manual playlist in its own order, with the reorder handle and Remove on every row.
    func testManualPlaylistPixelBaselines() async throws {
        for appearance in WiltedAppearance.allCases {
            let fixture = try await playlistFixture("manual-playlist")
            let model = fixture.model
            let playlist = try await newPlaylist(model, .manual, "Morning Walk")
            for id in [fixture.ids[2], fixture.ids[0], fixture.ids[1]] {
                await model.addToPlaylist(playlist.id, entryID: id.rawValue)
            }
            let image = render(
                WiltedMacPlaylistView(model: model, playlistID: playlist.id),
                variant: variant(appearance), size: CGSize(width: 760, height: 420))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the playlist drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "playlist-manual", appearance: appearance),
                testName: "testManualPlaylistPixelBaselines")
            await model.close()
        }
    }

    /// The rule editor with a played rule and a length rule.
    func testPlaylistRuleEditorPixelBaselines() async throws {
        for appearance in WiltedAppearance.allCases {
            let fixture = try await playlistFixture("playlist-rules")
            let model = fixture.model
            let playlist = try await newPlaylist(model, .automatic, "Unplayed Shorts")
            let rules = [
                try PlaylistRule(field: .played, comparator: .is, value: PlaylistPlayedState.unplayed.rawValue),
                try PlaylistRule(field: .length, comparator: .shorterThan, value: "30"),
            ]
            _ = await model.savePlaylistRules(playlist.id, rules: rules, matchAll: true)
            let saved = try XCTUnwrap(model.playlist(playlist.id))
            let image = render(
                WiltedMacPlaylistRulesSheet(model: model, playlist: saved),
                variant: variant(appearance), size: CGSize(width: WiltedMacPlaylistRulesSheet.width, height: 290))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the rule editor drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "playlist-rules", appearance: appearance),
                testName: "testPlaylistRuleEditorPixelBaselines")
            await model.close()
        }
    }
}
