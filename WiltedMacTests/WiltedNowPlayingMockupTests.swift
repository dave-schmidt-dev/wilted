import AppKit
import SwiftUI
import XCTest
import WiltedLibrary
@testable import WiltedMac

/// Design artifacts only. Neither alternative replaces the shipping pane.
@MainActor
final class WiltedNowPlayingMockupTests: XCTestCase {
    func testEightNativeNowPlayingAlternativesAndComparison() async throws {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("now-playing-mockups"),
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.setTextScale(.standard)
        let episode = WiltedMacEpisode(
            id: "mockup-quiet-machines", title: "Quiet Machines", feedTitle: "Field Notes",
            summary: "A walk through the machines that keep the field office quiet.",
            notes: WiltedMacModel.fixtureEpisodeNotes, artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_699_827_200), durationSeconds: 1482,
            playbackSeconds: 90, downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        model.installPlaybackStateForTesting(episode: episode, isPlaying: true, position: 90, duration: 1482)
        let passages = [
            "Welcome to Field Notes. Today we visit the machines that keep the field office quiet.",
            "A small pump moves water through the garden. Its steady rhythm is easy to miss until the rest of the room falls silent.",
            "We stop beside the old workbench and listen. Ada explains how a few careful changes reduced the noise without replacing the equipment.",
            "The important work is often ordinary: check the seals, clear the filter, and leave the next person a useful note.",
            "Outside, the evening wind moves through the trees. We carry that slower pace back into the workshop.",
            "Tomorrow we will return to the same bench and compare what changed. Thank you for listening to Field Notes."
        ]
        model.currentTranscript = WiltedMacTranscript(availability: .available, text: passages.joined(separator: "\n\n"),
            cues: passages.enumerated().map { index, text in
                WiltedMacTranscriptCue(id: index, startSeconds: Double(index * 75),
                                      endSeconds: Double((index + 1) * 75), text: text, speaker: "Host")
            }, timingSource: "Synthetic mockup fixture")
        let expected = WiltedMacHeadless.sourceRoot().appendingPathComponent(".logs/b7a/now-playing-mockups")
        let output = ProcessInfo.processInfo.environment["WILTED_WALKTHROUGH_CAPTURE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? expected
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var renders: [NowPlayingMockupCapture] = []
        var pageBrightness: [String: CGFloat] = [:]
        for alternative in NowPlayingMockupAlternative.allCases {
            for (band, width) in [("full", CGFloat(640)), ("narrow", CGFloat(360))] {
                for scheme in [ColorScheme.light, .dark] {
                    let name = "\(alternative.rawValue)-\(band)-\(scheme == .dark ? "dark" : "light")"
                    let size = CGSize(width: width, height: 740)
                    let view = NowPlayingMockupPane(model: model, alternative: alternative)
                        .environment(\.colorScheme, scheme).environment(\.wiltedTextScale, .standard)
                    let bitmap = try WiltedMacHeadless.render(view, size: size)
                    XCTAssertEqual(bitmap.pixelsWide, Int(width), name)
                    XCTAssertEqual(bitmap.pixelsHigh, 740, name)
                    XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: bitmap), 8, name)
                    let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
                    XCTAssertGreaterThanOrEqual(corner.alphaComponent, 0.99, name)
                    pageBrightness[name] = (corner.redComponent + corner.greenComponent + corner.blueComponent) / 3
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    renders.append(NowPlayingMockupCapture(name: name, image: try XCTUnwrap(NSImage(data: png))))
                }
            }
        }
        XCTAssertEqual(renders.count, 8)
        for alternative in NowPlayingMockupAlternative.allCases {
            for band in ["full", "narrow"] {
                let prefix = "\(alternative.rawValue)-\(band)"
                XCTAssertLessThan(try XCTUnwrap(pageBrightness[prefix + "-dark"]),
                                  try XCTUnwrap(pageBrightness[prefix + "-light"]), "Actual dark page must differ from light")
            }
        }
        let comparison = try WiltedMacHeadless.render(NowPlayingMockupComparison(captures: renders),
                                                      size: CGSize(width: 1440, height: 1120))
        try XCTUnwrap(comparison.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("comparison.png"), options: .atomic)
        try Self.comparisonText.write(to: output.appendingPathComponent("comparison.md"), atomically: true, encoding: .utf8)
        let findings: [String: Any] = [
            "scope": "Now Playing mockups only; shipping pane unchanged; owner acceptance pending",
            "fixture": "Synthetic Quiet Machines episode, timed transcript and existing synthetic show notes",
            "findings": [
                ["rule": 4, "evidence": "WiltedMacNowPlayingPane.swift:227",
                 "owner_note": "Second button row competes with transport; Restart duplicates skip-back",
                 "action": "Move Restart, Mark completed and Share into overflow",
                 "addressed_by": ["A", "B"],
                 "tradeoff": "Those actions require opening a menu; Restart remains distinct from rewind 15 seconds"],
                ["rule": 14, "evidence": "WiltedMacNowPlayingPane.swift:107,147",
                 "owner_note": "Wasted space leaves less reader height",
                 "action": "Reduce header and padding, place speed beside transport",
                 "addressed_by": ["B"], "tradeoff": "Smaller artwork and a denser transport row"]
            ],
            "alternatives": ["A": "Existing vertical header and padding; speed plus overflow on second row",
                             "B": "Compact header; speed and overflow in transport row"],
            "recommendation": "B for owner comparison; accept only after viewing full/narrow light/dark renders",
            "renders": renders.map { $0.name + ".png" }, "comparison": "comparison.png"
        ]
        try JSONSerialization.data(withJSONObject: findings, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("clear-b7-5.1.json"), options: .atomic)
        await model.close()
    }

    private static let comparisonText = """
    # Now Playing alternatives
    B is the recommended candidate for owner comparison. It makes more room for the reader by reducing the header and keeping speed beside transport. A changes fewer placements and keeps the large artwork.

    | | A | B |
    |---|---|---|
    | Header | Current vertical layout, 110-point artwork | Compact horizontal header, 48-point artwork |
    | Transport | Current five controls | Same five controls, speed and overflow alongside |
    | Secondary actions | Restart, Mark completed and Share in overflow | Same overflow |
    | Tradeoff | A second row remains | Smaller artwork and denser transport |

    Restart returns to the beginning; rewind moves back 15 seconds. Both remain available. These synthetic native renders compare layout only; they do not qualify playback or menu behavior. Shipping Now Playing remains unchanged. Owner acceptance is pending.

    ![One-page native comparison](comparison.png)
    """
}

private enum NowPlayingMockupAlternative: String, CaseIterable { case A, B }

private struct NowPlayingMockupCapture {
    let name: String
    let image: NSImage
}

@MainActor
private struct NowPlayingMockupPane: View {
    let model: WiltedMacModel
    let alternative: NowPlayingMockupAlternative
    @Environment(\.colorScheme) private var scheme
    @State private var tab: WiltedMacPaneTab = .transcript
    @State private var followsPlayback = true

    private var compact: Bool { alternative == .B }

    var body: some View {
        VStack(spacing: compact ? WiltedTheme.Spacing.medium : WiltedTheme.Spacing.large) {
            header
            VStack(spacing: WiltedTheme.Spacing.small) {
                HStack(spacing: compact ? 8 : WiltedTheme.Spacing.large) {
                    transport("backward.end.fill", label: "Previous episode", action: model.previousPlayback)
                    transport("gobackward.15", label: "Rewind 15 seconds", action: model.rewind)
                    transport(model.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                              label: model.isPlaying ? "Pause" : "Play", size: 48, action: model.togglePlayback)
                        .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: scheme))
                    transport("goforward.30", label: "Skip forward 30 seconds", action: model.forward)
                    transport("forward.end.fill", label: "Next episode", action: model.nextPlayback)
                    if compact { speed; overflow }
                }
                if !compact {
                    HStack(spacing: WiltedTheme.Spacing.medium) { speed; overflow }
                }
            }
            scrubber
            VStack(spacing: WiltedTheme.Spacing.small) {
                Picker("Section", selection: $tab) {
                    ForEach(WiltedMacPaneTab.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Group {
                    switch tab {
                    case .transcript:
                        WiltedMacTranscriptPanel(model: model, viewportHeight: nil, following: $followsPlayback)
                    case .notes:
                        WiltedMacNotesPanel(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxHeight: .infinity)
        }
        .padding(compact ? WiltedTheme.Spacing.large : WiltedTheme.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WiltedTheme.color(.page, scheme: scheme))
        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: scheme))
    }

    @ViewBuilder private var header: some View {
        if compact {
            HStack(spacing: WiltedTheme.Spacing.medium) {
                WiltedProduceTile(symbol: .cabbage, size: 48).accessibilityHidden(true)
                titles.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: WiltedTheme.Spacing.medium) {
                WiltedProduceTile(symbol: .cabbage, size: 110).accessibilityHidden(true)
                titles.multilineTextAlignment(.center)
            }
        }
    }

    private var titles: some View {
        VStack(alignment: compact ? .leading : .center, spacing: WiltedTheme.Spacing.xSmall) {
            Text(model.currentEpisode?.title ?? "Quiet Machines").wiltedFont(.title).lineLimit(2)
            Text(model.currentEpisode?.presentation.playerSubtitleLabel ?? "Field Notes")
                .wiltedFont(.utility).foregroundStyle(WiltedTheme.color(.secondaryText, scheme: scheme)).lineLimit(1)
        }
    }

    private var speed: some View {
        Picker("Speed", selection: Binding(get: { model.playbackRate }, set: { model.setPlaybackRate($0) })) {
            ForEach(PlaybackSpeeds.all, id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
        }
        .labelsHidden().fixedSize().accessibilityLabel("Speed").help("Playback speed")
    }

    private var overflow: some View {
        Menu {
            Button("Restart") { model.restartPlayback() }
            Button("Mark completed") { model.markCurrentPlaybackCompleted() }
            // Mockup affordance only: no share, publication or owner-state action is performed.
            Button("Share…") {}
        } label: { Image(systemName: "ellipsis.circle").wiltedSquare(24) }
        .menuStyle(.borderlessButton).fixedSize().help("More playback actions")
    }

    private func transport(_ symbol: String, label: String, size: CGFloat = 24,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).resizable().scaledToFit().wiltedSquare(size)
        }.buttonStyle(.borderless).accessibilityLabel(label).help(label)
    }

    private var scrubber: some View {
        VStack(spacing: WiltedTheme.Spacing.xSmall) {
            Slider(value: Binding(get: { model.playbackPositionSeconds }, set: { model.scrub(to: $0) }),
                   in: 0...model.playbackDurationSeconds).labelsHidden().accessibilityLabel("Playback position")
            HStack {
                Text(WiltedMacScrubberLabels.elapsed(model.playbackPositionSeconds))
                Spacer()
                Text(WiltedMacScrubberLabels.remaining(position: model.playbackPositionSeconds,
                                                       duration: model.playbackDurationSeconds))
            }.wiltedFont(.utility).monospacedDigit()
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: scheme))
        }
    }
}

@MainActor
private struct NowPlayingMockupComparison: View {
    let captures: [NowPlayingMockupCapture]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Now Playing · two native alternatives").wiltedFont(.title)
            Text("A: current header, secondary actions in overflow.  B: compact header, speed beside transport.")
                .wiltedFont(.body)
            Text("B is the recommended comparison candidate. Smaller artwork and denser controls trade for reader space; owner acceptance is pending.")
                .wiltedFont(.utility)
            ForEach(["A", "B"], id: \.self) { alternative in
                HStack(alignment: .top, spacing: 20) {
                    ForEach(captures.filter { $0.name.hasPrefix(alternative) }, id: \.name) { capture in
                        VStack(spacing: 5) {
                            Text(capture.name).wiltedFont(.utility)
                            Image(nsImage: capture.image).resizable().scaledToFit().frame(height: 400)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
            Text("Synthetic episode and transcript; native SwiftUI offscreen renders, no shipping UI change. Restart remains in the menu because it differs from rewind 15 seconds.")
                .wiltedFont(.utility)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WiltedTheme.color(.page, scheme: .light))
        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: .light))
    }
}
