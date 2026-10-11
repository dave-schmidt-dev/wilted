import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

extension WiltedPixelSnapshotTests {
    /// The owner-selected compact pane, using the native synthetic podcast and reader content.
    func testNowPlayingPanePixelBaselines() throws {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("now-playing-pane-\(appearance)"),
                preferences: WiltedMacTestPreferences.ephemeral())
            let episode = WiltedMacEpisode(
                id: "pane-quiet-machines", title: "Quiet Machines", feedTitle: "Field Notes",
                summary: "A walk through the machines that keep the field office quiet.",
                notes: WiltedMacModel.fixtureEpisodeNotes, artworkURL: nil,
                releasedAt: Date(timeIntervalSince1970: 1_699_827_200), durationSeconds: 1482,
                playbackSeconds: 90, downloadState: .completed, preparationState: .prepared(summary: "Ready"))
            model.installPlaybackStateForTesting(episode: episode, isPlaying: true, position: 90, duration: 1482)
            model.playbackRate = 1.25
            let passages = [
                "Welcome to Field Notes. Today we visit the machines that keep the field office quiet.",
                "A small pump moves water through the garden. Its steady rhythm is easy to miss until the rest of the room falls silent.",
                "We stop beside the old workbench and listen. Ada explains how a few careful changes reduced the noise without replacing the equipment."
            ]
            model.currentTranscript = WiltedMacTranscript(availability: .available, text: passages.joined(separator: "\n\n"),
                cues: passages.enumerated().map { index, text in
                    WiltedMacTranscriptCue(id: index, startSeconds: Double(index * 75),
                                          endSeconds: Double((index + 1) * 75), text: text, speaker: "Host")
                }, timingSource: "Synthetic fixture")
            let image = render(
                WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState())),
                variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 640, height: 740))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the pane must contain painted controls and reader content")
            assertSnapshot(image, named: WiltedSnapshotContract.shellName(kind: "now-playing-pane", appearance: appearance),
                           testName: "testNowPlayingPanePixelBaselines")
        }
    }
}
