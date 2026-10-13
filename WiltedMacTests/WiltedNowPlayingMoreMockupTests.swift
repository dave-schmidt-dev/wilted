import AppKit
import SwiftUI
import XCTest
import WiltedLibrary
@testable import WiltedMac

/// Design artifacts only (B7c-2.9). Renders the shipping Now Playing pane beside three alternatives for
/// where playback speed, Restart and Recover audio live; none of them replaces the shipping pane.
@MainActor
final class WiltedNowPlayingMoreMockupTests: XCTestCase {
    func testMoreMenuAlternativesRenderBesideTheCurrentPane() async throws {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("now-playing-more-mockups"),
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.setTextScale(.standard)
        let episode = WiltedMacEpisode(
            id: "mockup-quiet-machines", title: "Quiet Machines", feedTitle: "Field Notes",
            summary: "A walk through the machines that keep the field office quiet.",
            notes: WiltedMacModel.fixtureEpisodeNotes, artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_699_827_200), durationSeconds: 1482,
            playbackSeconds: 90, downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        model.installPlaybackStateForTesting(episode: episode, isPlaying: true, position: 90, duration: 1482)
        model.playbackRate = 1.25
        let passages = [
            "Welcome to Field Notes. Today we visit the machines that keep the field office quiet.",
            "A small pump moves water through the garden. Its steady rhythm is easy to miss until the rest of the room falls silent.",
            "We stop beside the old workbench and listen. Ada explains how a few careful changes reduced the noise without replacing the equipment.",
            "The important work is often ordinary: check the seals, clear the filter, and leave the next person a useful note.",
            "Outside, the evening wind moves through the trees. We carry that slower pace back into the workshop."
        ]
        model.currentTranscript = WiltedMacTranscript(availability: .available, text: passages.joined(separator: "\n\n"),
            cues: passages.enumerated().map { index, text in
                WiltedMacTranscriptCue(id: index, startSeconds: Double(index * 75),
                                      endSeconds: Double((index + 1) * 75), text: text, speaker: "Host")
            }, timingSource: "Synthetic mockup fixture")
        let expected = WiltedMacHeadless.sourceRoot().appendingPathComponent(".logs/b7c/now-playing-more-mockups")
        let output = ProcessInfo.processInfo.environment["WILTED_WALKTHROUGH_CAPTURE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? expected
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var renders: [NowPlayingMoreMockupCapture] = []
        var pageBrightness: [String: CGFloat] = [:]
        for state in NowPlayingMoreMockupState.allCases {
            // Open shows every control an option offers, so it is also the audio route fault, where Recover
            // audio appears and playback has stopped. The other states are ordinary playback.
            let fault = state == .open
            model.installPlaybackStateForTesting(episode: episode, isPlaying: !fault, position: 90, duration: 1482)
            model.audioRouteFault = fault
            model.playbackError = fault ? WiltedMacPlaybackCopy.routeFailed : nil
            for option in NowPlayingMoreMockupOption.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    let name = "\(option.rawValue)-\(state.rawValue)-\(scheme == .dark ? "dark" : "light")"
                    let size = CGSize(width: state.width, height: 740)
                    let view = NowPlayingMoreMockupView(model: model, option: option, open: state == .open)
                        .environment(\.colorScheme, scheme).environment(\.wiltedTextScale, .standard)
                    let bitmap = try WiltedMacHeadless.render(view, size: size)
                    XCTAssertEqual(bitmap.pixelsWide, Int(size.width), name)
                    XCTAssertEqual(bitmap.pixelsHigh, 740, name)
                    XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: bitmap), 8, name)
                    let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
                    XCTAssertGreaterThanOrEqual(corner.alphaComponent, 0.99, name)
                    pageBrightness[name] = (corner.redComponent + corner.greenComponent + corner.blueComponent) / 3
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    renders.append(NowPlayingMoreMockupCapture(name: name, image: try XCTUnwrap(NSImage(data: png))))
                }
            }
        }
        // Four variants (current pane, A, B, C) in three states, each in light and dark.
        XCTAssertEqual(renders.count, 24)
        for option in NowPlayingMoreMockupOption.allCases {
            for state in NowPlayingMoreMockupState.allCases {
                let prefix = "\(option.rawValue)-\(state.rawValue)"
                XCTAssertLessThan(try XCTUnwrap(pageBrightness[prefix + "-dark"]),
                                  try XCTUnwrap(pageBrightness[prefix + "-light"]), "Actual dark page must differ from light")
            }
        }
        let comparison = try WiltedMacHeadless.render(NowPlayingMoreMockupComparison(captures: renders),
                                                      size: CGSize(width: 1440, height: 1200))
        try XCTUnwrap(comparison.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("comparison.png"), options: .atomic)
        try NowPlayingMoreMockupComparison.notes
            .write(to: output.appendingPathComponent("comparison.md"), atomically: true, encoding: .utf8)
        await model.close()
    }
}
