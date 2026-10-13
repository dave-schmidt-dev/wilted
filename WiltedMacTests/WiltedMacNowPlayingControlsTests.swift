import AppKit
import SwiftUI
import Vision
import XCTest
import WiltedLibrary
@testable import WiltedMac

/// The Now Playing pane's controls as the owner chose them (B7c-2.10: mockup A, with speed beside the
/// reader's tabs). Speed is a visible pull-down at the end of the Transcript/Notes row; Restart and,
/// during an audio route fault, Recover audio sit in a labelled More menu after Mark completed.
@MainActor
final class WiltedMacNowPlayingControlsTests: XCTestCase {
    /// The narrowest pane, and a width past the content's 720-point cap.
    private let widths: [CGFloat] = [WiltedMacLarderLayout.paneWidth.lowerBound, 760]
    private let height: CGFloat = 740

    func testSpeedEndsTheReaderRowAndMoreStaysClosedAtNarrowAndWideWidths() async throws {
        let model = paneModel()
        var pageBrightness: [String: CGFloat] = [:]
        for fault in [false, true] {
            setFault(fault, on: model)
            for width in widths {
                for scheme in [ColorScheme.light, .dark] {
                    let name = "now-playing-controls-\(Int(width))-\(fault ? "fault" : "rest")-\(scheme == .dark ? "dark" : "light")"
                    let pane = WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))
                        .environment(\.colorScheme, scheme)
                    let size = CGSize(width: width, height: height)
                    let bitmap = try WiltedMacHeadless.render(pane, size: size)
                    XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: bitmap), 8, name)
                    let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
                    pageBrightness[name] = (corner.redComponent + corner.greenComponent + corner.blueComponent) / 3
                    try keep(bitmap, name: name)

                    let lines = try recognizedFrames(pane, size: size)
                    let context = "\(name): \(lines.map(\.text))"
                    func line(_ match: (String) -> Bool) throws -> (text: String, frame: CGRect) {
                        try XCTUnwrap(lines.first { match($0.text) }, context)
                    }
                    let words = { (text: String) in text.split(separator: " ").map(String.init) }
                    let title = try line { $0.contains("Quiet Machines") }
                    let completion = try line { $0.contains("Mark completed") }
                    let more = try line { words($0).contains("More") }
                    let transcript = try line { $0.contains("Transcript") }
                    let notes = try line { $0.contains("Notes") && !$0.contains("Field") }
                    let speed = try line { $0.contains("Speed") }
                    let rate = try line { $0.contains("1.25") }

                    // The header is artwork, title and show only; the controls follow it.
                    XCTAssertLessThan(title.frame.minY, 72, context)
                    XCTAssertGreaterThan(speed.frame.minY, title.frame.maxY + 60, "Speed is not in the header: \(context)")
                    // Mark completed and More share the transport row, fully on screen.
                    XCTAssertLessThan(completion.frame.minY, 130, context)
                    XCTAssertLessThan(abs(more.frame.midY - completion.frame.midY), 6, context)
                    XCTAssertGreaterThanOrEqual(more.frame.minX, completion.frame.minX, context)
                    XCTAssertGreaterThan(completion.frame.minX, 12, context)
                    XCTAssertLessThan(more.frame.maxX, width - 12, context)
                    // Speed and its rate read on one line with Transcript and Notes, after Notes, unclipped.
                    for part in [notes, speed, rate] {
                        XCTAssertLessThan(abs(part.frame.midY - transcript.frame.midY), 6, "same row: \(context)")
                    }
                    if speed.text == notes.text {
                        let order = speed.text
                        XCTAssertLessThan(try XCTUnwrap(order.range(of: "Notes")).lowerBound,
                                          try XCTUnwrap(order.range(of: "Speed")).lowerBound, context)
                    } else {
                        XCTAssertGreaterThan(speed.frame.minX, notes.frame.maxX, context)
                    }
                    XCTAssertGreaterThan(rate.frame.minX, width / 2, "Speed ends the row: \(context)")
                    XCTAssertLessThan(rate.frame.maxX, width - 12, context)
                    XCTAssertLessThan(transcript.frame.minY, 225, "the controls leave the reader its height: \(context)")
                    XCTAssertTrue(lines.contains { $0.text.contains("garden") }, context)
                    // The More menu is closed: its items are not drawn, fault or not.
                    XCTAssertFalse(lines.contains { $0.text.contains("Restart") || $0.text.contains("Recover audio") }, context)
                }
            }
        }
        for name in pageBrightness.keys where name.hasSuffix("-dark") {
            let light = name.replacingOccurrences(of: "-dark", with: "-light")
            XCTAssertLessThan(try XCTUnwrap(pageBrightness[name]), try XCTUnwrap(pageBrightness[light]), name)
        }
        await model.close()
    }

    func testMoreMenuListsRestartAlwaysAndRecoverAudioOnlyDuringAFault() async throws {
        let model = paneModel()
        for fault in [false, true] {
            setFault(fault, on: model)
            for scheme in [ColorScheme.light, .dark] {
                let pane = WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))
                let items = VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) { pane.playbackActions }
                    .padding(WiltedTheme.Spacing.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(WiltedTheme.color(.page, scheme: scheme))
                    .environment(\.colorScheme, scheme)
                let size = CGSize(width: 300, height: 160)
                let lines = try WiltedMacHeadless.recognizedText(items, size: size)
                let context = "\(scheme)/fault=\(fault): \(lines)"
                XCTAssertTrue(lines.contains { $0.contains("Restart") }, context)
                XCTAssertEqual(lines.contains { $0.contains("Recover audio") }, fault, context)
                XCTAssertFalse(lines.contains { $0.contains("Speed") || $0.contains("Mark completed") }, context)
                try keep(WiltedMacHeadless.render(items, size: size),
                         name: "now-playing-more-items-\(fault ? "fault" : "rest")-\(scheme == .dark ? "dark" : "light")")
                // Share lives in the header, not the menu; it still renders as a unit.
                let share = pane.share.environment(\.colorScheme, scheme)
                    .background(WiltedTheme.color(.page, scheme: scheme))
                XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(
                    in: try WiltedMacHeadless.render(share, size: CGSize(width: 120, height: 80))), 8, context)
            }
        }
        await model.close()
    }

    /// Cmd-R restarts the loaded episode exactly once without the More menu ever being opened. A shortcut
    /// on a closed SwiftUI menu's item never fires, so the binding is the pane's hidden Restart button.
    func testCommandRRestartsOnceWhileTheMoreMenuIsClosed() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let log = WiltedMacCommandLog()
        model.installPlaybackCommandHookForTesting { log.kinds.append($0.kind) }
        let window = offscreenWindow(for: WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState())))
        try await Task.sleep(for: .milliseconds(300))
        let issued = model.playbackCommands.generation
        XCTAssertTrue(window.performKeyEquivalent(with: try commandR(window)), "Cmd-R is handled with More closed")
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playbackCommands.generation - issued, 1, "one binding, one restart")
        XCTAssertEqual(log.kinds, [.restart])
        window.close()
        await model.close()
    }

    // MARK: - Fixtures

    private func paneModel() -> WiltedMacModel {
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("now-playing-controls"),
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.setTextScale(.standard)
        model.installPlaybackStateForTesting(episode: episode, isPlaying: true, position: 90, duration: 1482)
        model.playbackRate = 1.25
        let passages = [
            "Welcome to Field Notes. Today we visit the machines that keep the field office quiet.",
            "A small pump moves water through the garden. Its steady rhythm is easy to miss until the room falls silent.",
            "We stop beside the old workbench and listen. Ada explains how a few careful changes reduced the noise."
        ]
        model.currentTranscript = WiltedMacTranscript(availability: .available, text: passages.joined(separator: "\n\n"),
            cues: passages.enumerated().map { index, text in
                WiltedMacTranscriptCue(id: index, startSeconds: Double(index * 75),
                                      endSeconds: Double((index + 1) * 75), text: text, speaker: "Host")
            }, timingSource: "Synthetic fixture")
        return model
    }

    private let episode = WiltedMacEpisode(
        id: "controls-quiet-machines", title: "Quiet Machines", feedTitle: "Field Notes",
        summary: "A walk through the machines that keep the field office quiet.",
        notes: WiltedMacModel.fixtureEpisodeNotes, artworkURL: nil,
        releasedAt: Date(timeIntervalSince1970: 1_699_827_200), durationSeconds: 1482,
        playbackSeconds: 90, downloadState: .completed, preparationState: .prepared(summary: "Ready"))

    /// An audio route fault stops playback and reports the failed recovery, which is when Recover audio exists.
    private func setFault(_ fault: Bool, on model: WiltedMacModel) {
        model.installPlaybackStateForTesting(episode: episode, isPlaying: !fault, position: 90, duration: 1482)
        model.audioRouteFault = fault
        model.playbackError = fault ? WiltedMacPlaybackCopy.routeFailed : nil
    }

    /// An offscreen window hosting `view`; it is never ordered in, so nothing reaches the screen.
    private func offscreenWindow<V: View>(for view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 740),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return window
    }

    private func commandR(_ window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "r", charactersIgnoringModifiers: "r",
            isARepeat: false, keyCode: 15))
    }

    /// Text Vision reads from `view` drawn at exactly `size`, each line with its frame in the view's points.
    /// The view is drawn at 2x inside a margin, because Vision misses text that touches the image edge.
    private func recognizedFrames<V: View>(_ view: V, size: CGSize) throws -> [(text: String, frame: CGRect)] {
        let margin: CGFloat = 24
        let scale = 2
        let canvas = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .padding(margin).background(Color.white))
        host.frame = NSRect(origin: .zero, size: canvas)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width) * scale, pixelsHigh: Int(canvas.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = canvas
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            let frame = CGRect(x: box.minX * canvas.width - margin, y: (1 - box.maxY) * canvas.height - margin,
                               width: box.width * canvas.width, height: box.height * canvas.height)
            return (text, frame)
        }
    }

    /// Attaches the render and, when `WILTED_WALKTHROUGH_CAPTURE_DIR` is set, writes it there for review.
    private func keep(_ bitmap: NSBitmapImageRep, name: String) throws {
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["WILTED_WALKTHROUGH_CAPTURE_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

/// The playback commands a test saw admitted, in order.
@MainActor
private final class WiltedMacCommandLog {
    var kinds: [WiltedMacPlaybackCommandKind] = []
}
