import SwiftUI
import Foundation
import XCTest
import AppKit
import MediaPlayer
import Vision
import CoreML
import WiltedLibrary
@testable import WiltedMac

@MainActor
private final class RecordingNowPlayingSink: WiltedNowPlayingSink {
    private(set) var published: [WiltedNowPlayingInfo] = []
    private(set) var clearCount = 0

    func publish(_ info: WiltedNowPlayingInfo) { published.append(info) }
    func clear() { clearCount += 1 }
}

@MainActor
private final class RecordingRemoteCommandSource: WiltedRemoteCommandSource {
    private var handler: (@MainActor (WiltedRemoteCommand) -> Void)?
    private(set) var availability: [(hasNext: Bool, hasPrevious: Bool)] = []

    var isInstalled: Bool { handler != nil }

    func install(handler: @escaping @MainActor (WiltedRemoteCommand) -> Void) { self.handler = handler }
    func updateQueueAvailability(hasNext: Bool, hasPrevious: Bool) {
        availability.append((hasNext: hasNext, hasPrevious: hasPrevious))
    }

    /// Stands in for a media key press.
    func send(_ command: WiltedRemoteCommand) { handler?(command) }
}

/// Carries a reference across an isolation boundary the type does not model.
/// `MPMediaItemArtwork` is not `Sendable`; handing it to another executor is the
/// exact thing under test, so the boundary has to be crossed deliberately.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
final class WiltedMacNowPlayingTests: XCTestCase {
    private var suiteNames: [String] = []

    // Async, so the override inherits this class's main actor isolation. The
    // synchronous form is unisolated, and reaching the two properties from it
    // is exactly the kind of isolation slip that crashed this feature once.
    override func tearDown() async throws {
        suiteNames.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    // MARK: - Test host

    /// `WiltedMacApp` decides whether to seize the machine's Now Playing widget
    /// and media keys by looking for this variable, because the unit test host
    /// is the app bundle itself. If a future Xcode stops setting it, the app
    /// would silently point the menu bar at a process XCTest is about to kill,
    /// reading the owner's real library. That should fail here rather than in
    /// the menu bar.
    func testTheTestHostIsIdentifiableFromItsEnvironment() {
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
    }

    // MARK: - Artwork

    /// The system asks for the artwork image on whatever queue it is drawing
    /// from. A request handler formed inside a main-actor method inherits that
    /// isolation and traps the first time the system calls it, which took the
    /// whole process down rather than degrading to a missing image.
    func testTheArtworkImageCanBeRequestedOffTheMainActor() async throws {
        let data = try XCTUnwrap(Self.smallPNGData())
        let artwork = try XCTUnwrap(MediaPlayerNowPlayingSink.artwork(from: data))
        let held = UncheckedBox(artwork)
        let size = await Task.detached { held.value.image(at: CGSize(width: 16, height: 16))?.size }.value
        XCTAssertNotNil(size, "the system's request handler has to answer off the main actor")
    }

    /// Artwork the system cannot decode is a missing image, not a failure.
    func testUndecodableArtworkIsSimplyAbsent() {
        XCTAssertNil(MediaPlayerNowPlayingSink.artwork(from: Data([0x00, 0x01, 0x02])))
    }

    // MARK: - What gets published

    func testAnEpisodePublishesItsShowDurationAndPosition() {
        let (model, sink, _) = makeModel()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: true, position: 90, duration: 1_800)
        model.publishNowPlaying()

        XCTAssertEqual(sink.published.count, 1)
        let info = try? XCTUnwrap(sink.published.first)
        XCTAssertEqual(info?.title, "The Cost of Everything")
        XCTAssertEqual(info?.showTitle, "Quarterly")
        XCTAssertEqual(info?.durationSeconds, 1_800)
        XCTAssertEqual(info?.positionSeconds, 90)
        XCTAssertEqual(info?.isPlaying, true)
        XCTAssertEqual(info?.rate, model.playbackRate,
                       "the chosen speed, because the system advances its own clock from it")
    }

    /// A paused episode has to report a rate of zero. The system extrapolates
    /// elapsed time from the rate it was last told, so reporting the speed a
    /// resume would use walks the widget's scrubber forward through silence.
    func testAPausedEpisodePublishesARateOfZero() {
        let (model, sink, _) = makeModel()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: false, position: 90, duration: 1_800)
        model.publishNowPlaying()

        XCTAssertEqual(sink.published.first?.rate, 0)
        XCTAssertEqual(sink.published.first?.isPlaying, false)
    }

    func testAnArticleAlsoAppearsInTheSystemWidget() {
        let (model, sink, _) = makeModel()
        model.installPlaybackStateForTesting(article: article(), isPlaying: true, position: 12, duration: 300)
        model.publishNowPlaying()

        XCTAssertEqual(sink.published.first?.title, "A Long Read")
        XCTAssertEqual(sink.published.first?.showTitle, "example.com",
                       "an article's source is what a show's title is to an episode")
    }

    /// The readout refreshes once a second for the life of an episode. The
    /// system advances its own copy of the position from the rate, so
    /// re-publishing an identical dictionary sixty times a minute is work
    /// nothing asked for.
    func testAnUnchangedReadoutIsNotRepublished() {
        let (model, sink, _) = makeModel()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: true, position: 90, duration: 1_800)
        model.publishNowPlaying()
        model.publishNowPlaying()
        XCTAssertEqual(sink.published.count, 1)

        model.installPlaybackStateForTesting(episode: episode(), isPlaying: true, position: 91, duration: 1_800)
        model.publishNowPlaying()
        XCTAssertEqual(sink.published.count, 1, "one second of drift is what extrapolation is for")

        model.installPlaybackStateForTesting(episode: episode(), isPlaying: true, position: 400, duration: 1_800)
        model.publishNowPlaying()
        XCTAssertEqual(sink.published.count, 2, "a jump the system cannot have extrapolated is republished")
    }

    func testPausingRepublishesEvenAtTheSamePosition() {
        let (model, sink, _) = makeModel()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: true, position: 90, duration: 1_800)
        model.publishNowPlaying()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: false, position: 90, duration: 1_800)
        model.publishNowPlaying()

        XCTAssertEqual(sink.published.count, 2)
        XCTAssertEqual(sink.published.last?.rate, 0)
    }

    func testStoppingClearsTheWidgetExactlyOnce() {
        let (model, sink, _) = makeModel()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: true, position: 90, duration: 1_800)
        model.publishNowPlaying()

        model.clearPlaybackStateForTesting()
        model.publishNowPlaying()
        model.publishNowPlaying()

        XCTAssertEqual(sink.clearCount, 1, "an already-cleared widget is not cleared again every second")
    }

    func testNothingIsPublishedBeforeAnythingIsLoaded() {
        let (model, sink, _) = makeModel()
        model.publishNowPlaying()
        XCTAssertTrue(sink.published.isEmpty)
        XCTAssertEqual(sink.clearCount, 0)
    }

    /// An enabled command tells the system the app handles it, so the widget
    /// draws the control. Leaving next enabled at the end of Up Next draws a
    /// button that does nothing.
    func testQueuePositionDecidesWhichSkipControlsTheWidgetDraws() {
        let (model, _, commands) = makeModel()
        let ep1 = episode(id: "episode-1")
        let ep2 = episode(id: "episode-2")
        let ep3 = episode(id: "episode-3")
        model.installEpisodeForTesting(ep1)
        model.installEpisodeForTesting(ep2)
        model.installEpisodeForTesting(ep3)
        let queue = ["episode-1", "episode-2", "episode-3"]
        model.installPlaybackStateForTesting(episode: ep2, isPlaying: true,
                                             position: 0, duration: 1_800, queue: queue)
        model.publishNowPlaying()
        XCTAssertEqual(commands.availability.last?.hasNext, true)
        XCTAssertEqual(commands.availability.last?.hasPrevious, true)

        model.installPlaybackStateForTesting(episode: ep3, isPlaying: true,
                                             position: 0, duration: 1_800, queue: queue)
        model.publishNowPlaying(force: true)
        XCTAssertEqual(commands.availability.last?.hasNext, false, "the last episode has nothing after it")
        XCTAssertEqual(commands.availability.last?.hasPrevious, true)
    }

    func testRemoteCommandNextTrackWithABCSkipsUnpreparedBAndSelectsC() {
        let (model, _, commands) = makeModel()
        let epA = episode(id: "episode-A", prepared: true)
        let epB = episode(id: "episode-B", prepared: false)
        let epC = episode(id: "episode-C", prepared: true)
        model.installEpisodeForTesting(epA)
        model.installEpisodeForTesting(epB)
        model.installEpisodeForTesting(epC)
        let queue = ["episode-A", "episode-B", "episode-C"]
        model.installPlaybackStateForTesting(episode: epA, isPlaying: true,
                                             position: 0, duration: 1_800, queue: queue)
        model.publishNowPlaying()
        XCTAssertEqual(commands.availability.last?.hasNext, true)

        commands.send(.nextTrack)

        XCTAssertEqual(model.currentPodcastEpisodeID, "episode-C",
                       "remote next-track must skip unprepared B and advance directly to C")
    }

    // MARK: - What comes back

    func testTheRemoteCommandHandlerIsInstalledWhenTheModelIsBuilt() {
        let (_, _, commands) = makeModel()
        XCTAssertTrue(commands.isInstalled,
                      "media keys have to work from launch, not from the first press of an on-screen button")
    }

    /// A media key routes through the same method the on-screen control calls,
    /// so it cannot acquire behaviour of its own.
    func testARemoteRateChangeIsTheSameChangeTheRateControlMakes() {
        let (model, _, commands) = makeModel()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: true, position: 0, duration: 1_800)
        commands.send(.changeRate(1.5))
        XCTAssertEqual(model.playbackRate, 1.5)
    }

    func testARemoteRateOutsideTheSupportedRangeIsClamped() {
        let (model, _, commands) = makeModel()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: true, position: 0, duration: 1_800)
        commands.send(.changeRate(9))
        XCTAssertEqual(model.playbackRate, 2, "the widget cannot ask for a speed the app refuses")
    }

    /// A press that arrives with nothing loaded is refused rather than starting
    /// something. The media keys are shared with every other app on the
    /// machine, and Wilted answering one it has no item for would take the
    /// keys away from whatever the listener actually meant.
    func testAPressWithNothingLoadedChangesNothing() {
        let (model, sink, commands) = makeModel()
        let rate = model.playbackRate
        commands.send(.toggle)
        commands.send(.play)
        commands.send(.changeRate(0.5))
        commands.send(.nextTrack)

        XCTAssertEqual(model.playbackRate, rate)
        XCTAssertFalse(model.isPlaying)
        XCTAssertTrue(sink.published.isEmpty)
    }

    func testTheSkipIntervalsMatchTheOnScreenTransports() {
        XCTAssertEqual(WiltedMacModel.backwardSkipSeconds, 15)
        XCTAssertEqual(WiltedMacModel.forwardSkipSeconds, 30)
        XCTAssertTrue(PlaybackSpeeds.all.contains(WiltedMacModel.initialPlaybackRate),
                      "the widget is told these speeds, so the default has to be one of them")
    }

    // MARK: - Sharing

    private let waveformFeed = URL(string: "https://feeds.example.test/waveform.xml")!
    private let waveformPage = URL(string: "https://waveform.example.test/episodes/the-cost-of-everything")!

    /// A Waveform-style episode: a feed with a published page for every episode.
    func testAnEpisodeSharesItsOwnPageAndNeverItsFeed() {
        let (model, _, _) = makeModel()
        var linked = episode()
        linked.feedURL = waveformFeed
        linked.episodeLink = waveformPage
        model.installPlaybackStateForTesting(episode: linked, isPlaying: false, position: 0, duration: 1_800)

        XCTAssertEqual(model.currentPlaybackShareURL, waveformPage)
        XCTAssertNotEqual(model.currentPlaybackShareURL, waveformFeed)
        XCTAssertEqual(model.currentPlaybackShareTitle, "The Cost of Everything")
        XCTAssertEqual(model.currentPlaybackShareMessage, "The Cost of Everything · Quarterly")
    }

    /// A feed that publishes no per-episode page shares what it honestly has.
    func testAnEpisodeWithNoPageSharesTitleAndShowAndSaysSo() {
        let (model, _, _) = makeModel()
        var linkless = episode()
        linkless.feedURL = waveformFeed
        model.installPlaybackStateForTesting(episode: linkless, isPlaying: false, position: 0, duration: 1_800)

        XCTAssertNil(model.currentPlaybackShareURL, "the feed address is not the episode's page")
        XCTAssertEqual(model.currentPlaybackShareText, "The Cost of Everything - Quarterly")
        XCTAssertEqual(model.currentPlaybackShareMessage, "The Cost of Everything · Quarterly")
        XCTAssertFalse(model.currentPlaybackShareMessage.contains("Only title and show text is shared."),
                       "control guidance must not be sent as the shared message")
        XCTAssertFalse((model.currentPlaybackShareText ?? "").contains(waveformFeed.absoluteString))
    }

    /// Both destinations keep the normal Share control; the fallback explains its payload in help.
    func testTextFallbackKeepsTheNormalShareControlAndExplainsItsPayloadInHelp() throws {
        let (model, _, _) = makeModel()
        var linked = episode()
        linked.episodeLink = waveformPage
        model.installPlaybackStateForTesting(episode: linked, isPlaying: false, position: 0, duration: 1_800)
        let withPage = try WiltedMacHeadless.recognizedText(
            WiltedMacPlaybackShareLink(model: model).padding(12), size: CGSize(width: 320, height: 90))
        XCTAssertFalse(withPage.contains { $0.contains("Only title") })

        let linkless = episode(id: "linkless-share")
        model.installPlaybackStateForTesting(episode: linkless, isPlaying: false, position: 0, duration: 1_800)
        let without = try WiltedMacHeadless.recognizedText(
            WiltedMacPlaybackShareLink(model: model).padding(12), size: CGSize(width: 320, height: 90))
        XCTAssertEqual(withPage, without, "the fallback must retain the normal Share presentation, got \(without)")
        let source = try WiltedMacHeadless.viewSource("WiltedMacPlayerContent.swift")
        XCTAssertTrue(source.contains(".help(\"Only title and show text is shared.\")"))
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: ".accessibilityLabel(\"Share\")", in: source), 2,
                       "both destinations have the same normal accessible Share name")
    }

    func testAnArticleKeepsItsCanonicalURL() {
        let (model, _, _) = makeModel()
        model.installPlaybackStateForTesting(article: article(), isPlaying: false, position: 0, duration: 300)
        XCTAssertEqual(model.currentPlaybackShareURL, URL(string: "https://example.com/read"))
        XCTAssertEqual(model.currentPlaybackShareMessage, "A Long Read · example.com")
    }

    /// The pane and the full player share one control, so neither can disagree about the fallback.
    func testBothPlayersUseTheSameShareControl() throws {
        for view in ["WiltedMacNowPlayingPane.swift", "WiltedMacPlayerContent.swift"] {
            let source = try WiltedMacHeadless.viewSource(view)
            XCTAssertTrue(source.contains("WiltedMacPlaybackShareLink(model: model)"), view)
        }
        let pane = try WiltedMacHeadless.viewSource("WiltedMacNowPlayingPane.swift")
        XCTAssertFalse(pane.contains("currentPlaybackShareURL"), "the pane must not build its own share")
        let player = try WiltedMacHeadless.viewSource("WiltedMacPlayerContent.swift")
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: ".accessibilityLabel(\"Share\")", in: player), 2)
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: ".accessibilityIdentifier(\"wilted-player-share\")", in: player), 2)
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "Image(systemName: \"square.and.arrow.up\")", in: player), 2)
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "currentPlaybackShareURL", in: player), 1,
                       "only the shared control reads it")
    }

    /// Share is a direct control beside the title and Mark completed reads as a button; neither
    /// hides in the overflow popover or looks like loose text.
    func testPaneShareSitsBesideTheTitleAndMarkCompletedIsABorderedButton() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacNowPlayingPane.swift")
        func section(_ start: String, until end: String) throws -> String {
            let begin = try XCTUnwrap(source.range(of: start), start)
            let finish = try XCTUnwrap(source.range(of: end, range: begin.upperBound..<source.endIndex), end)
            return String(source[begin.lowerBound..<finish.lowerBound])
        }
        let header = try section("private var header:", until: "@ViewBuilder private var artwork")
        let headerLines = header.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let titleLine = try XCTUnwrap(headerLines.firstIndex { $0.contains("wilted-player-item-title") }, "title in header")
        XCTAssertTrue(headerLines[titleLine...].contains { $0.hasPrefix("share") }, "Share follows the title block inside the header HStack")
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "WiltedMacPlaybackShareLink(model: model)", in: source), 1,
                       "one Share definition, mounted in the header")
        let actions = try section("var playbackActions:", until: "var share:")
        XCTAssertFalse(actions.contains("share"), "the More popover no longer holds Share")
        XCTAssertFalse(actions.contains("wilted-player-share"))
        let completion = try section("private var completionControl:", until: "private var speedControl:")
        XCTAssertTrue(completion.contains(".buttonStyle(.bordered)"))
        XCTAssertFalse(completion.contains(".buttonStyle(.borderless)"))
        XCTAssertFalse(completion.contains(".wiltedFont(.utility)"), "bordered button keeps the native control font")
        XCTAssertTrue(completion.contains("\"Mark completed\""))
        XCTAssertTrue(completion.contains(".disabled(model.playbackCompletionIsSettled)"))
        XCTAssertTrue(completion.contains("wilted-player-mark-completed"))
    }

    func testPaneKeepsCompletionAboveTheReaderAndSpeedHiddenAtNarrowAndFullWidths() throws {
        let (model, _, _) = makeModel()
        let item = WiltedMacEpisode(
            id: "selected-b-quiet-machines", title: "Quiet Machines", feedTitle: "Field Notes", summary: "A quiet workshop.",
            notes: WiltedMacModel.fixtureEpisodeNotes, artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_699_827_200), durationSeconds: 1482, playbackSeconds: 90,
            downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        model.installPlaybackStateForTesting(episode: item, isPlaying: true, position: 90, duration: 1482)
        model.playbackRate = 1.25
        model.currentTranscript = WiltedMacTranscript(availability: .available, text: "The small pump keeps the garden quiet.",
            cues: [WiltedMacTranscriptCue(id: 0, startSeconds: 0, endSeconds: 200,
                                         text: "The small pump keeps the garden quiet.", speaker: "Host")],
            timingSource: "Synthetic fixture")
        for width in [CGFloat(360), 640] {
            for scheme in [ColorScheme.light, .dark] {
                let bitmap = try WiltedMacHeadless.render(
                    WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))
                        .environment(\.colorScheme, scheme), size: CGSize(width: width, height: 740))
                XCTAssertEqual(bitmap.pixelsWide, Int(width))
                XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: bitmap), 8)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "selected-B-\(Int(width))-\(scheme)"; attachment.lifetime = .keepAlways; add(attachment)
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
                let devices = try request.supportedComputeStageDevices
                let cpu = try XCTUnwrap(devices[.main]?.first { device in
                    if case .cpu = device { return true }
                    return false
                }, "accurate OCR must vend a supported main-stage CPU device")
                request.setComputeDevice(cpu, for: .main)
                try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
                let lines = (request.results ?? []).compactMap { observation -> (text: String, top: CGFloat)? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return (text, (1 - observation.boundingBox.maxY) * 740)
                }
                let context = "\(width)/\(scheme): \(lines)"
                let title = try XCTUnwrap(lines.first { $0.text.contains("Quiet Machines") }, context)
                // Adjacent SF Symbols confuse Vision language selection. Read the actual
                // completion pixels alone, retaining exact copy and absolute geometry checks.
                let completionCrop = CGRect(x: width / 2 + 12, y: 64, width: width / 2 - 24, height: 70)
                let completionImage = try XCTUnwrap(bitmap.cgImage?.cropping(to: completionCrop), context)
                try VNImageRequestHandler(cgImage: completionImage).perform([request])
                let completion = try XCTUnwrap((request.results ?? []).first {
                    $0.topCandidates(1).first?.string.contains("Mark completed") == true
                }, "isolated completion must read its exact label: \(context)")
                let completionBounds = completion.boundingBox
                let completionTop = completionCrop.minY + (1 - completionBounds.maxY) * completionCrop.height
                XCTAssertGreaterThan(completionCrop.minX + completionBounds.minX * completionCrop.width, 12, context)
                XCTAssertLessThan(completionCrop.minX + completionBounds.maxX * completionCrop.width, width - 12, context)
                let reader = try XCTUnwrap(lines.first { $0.text.contains("Transcript") }, context)
                XCTAssertLessThan(title.top, 72, "compact48-point header: \(context)")
                XCTAssertLessThan(completionTop, 130, "completion shares the first transport row: \(context)")
                XCTAssertLessThan(reader.top, 225, "compact controls leave reader height: \(context)")
                XCTAssertFalse(lines.contains { $0.text.contains("Restart") || $0.text.contains("Speed") || $0.text.contains("1.25") },
                               "secondary actions stay inside overflow: \(context)")
                XCTAssertTrue(lines.contains { $0.text.contains("garden quiet") }, context)
            }
        }
    }

    func testPopoverRendersSpeedAndOnlyAvailableSecondaryActionsInBothThemes() throws {
        let (model, _, _) = makeModel()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: false, position: 90, duration: 1800)
        model.playbackRate = 1.25
        for scheme in [ColorScheme.light, .dark] {
            for fault in [false, true] {
                model.audioRouteFault = fault
                let view = WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))
                    .playbackActions.environment(\.colorScheme, scheme)
                    .background(WiltedTheme.color(.page, scheme: scheme))
                let lines = try WiltedMacHeadless.recognizedText(view, size: CGSize(width: 300, height: 300))
                let context = "\(scheme)/fault=\(fault): \(lines)"
                XCTAssertTrue(lines.contains { $0.contains("Speed") }, context)
                XCTAssertTrue(lines.contains { $0.contains("1.25") }, context)
                XCTAssertTrue(lines.contains { $0.contains("Restart") }, context)
                // Share now lives in the header; it is still rendered here as a unit.
                let share = WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))
                    .share.environment(\.colorScheme, scheme)
                    .background(WiltedTheme.color(.page, scheme: scheme))
                let shareBitmap = try WiltedMacHeadless.render(share, size: CGSize(width: 120, height: 80))
                XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: shareBitmap), 8,
                                     "the native Share icon must render: \(context)")
                XCTAssertEqual(lines.contains { $0.contains("Recover audio") }, fault, context)
                XCTAssertFalse(lines.contains { $0.contains("Mark completed") }, context)
                try retainCopyEvidence(WiltedMacHeadless.render(view, size: CGSize(width: 300, height: 300)),
                                       name: "playback-popover-\(scheme)-fault-\(fault)")
            }
        }
    }

    // MARK: - Fixtures

    /// A one-pixel PNG, so the decode is real without a fixture file.
    private static func smallPNGData() -> Data? {
        let image = NSImage(size: CGSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func testExpandedNotesNameThePaneOnlyOnceAndKeepBodyOrEmptyState() throws {
        let (model, _, _) = makeModel()
        for hasNotes in [true, false] {
            var item = episode(id: hasNotes ? "notes-present" : "notes-absent")
            item.notes = hasNotes ? "The fixture describes a quiet machine." : nil
            model.installPlaybackStateForTesting(episode: item, isPlaying: false, position: 0, duration: 1_800)
            let view = WiltedMacFullWindowPlayer(model: model, presentation: .constant(.notes),
                                               onSelect: { _ in }, onCollapse: { _ in })
            let size = CGSize(width: 1_100, height: 900)
            let lines = try WiltedMacHeadless.recognizedText(view, size: size)
            XCTAssertFalse(lines.contains("Notes"), "subtitle absent: \(lines)")
            XCTAssertFalse(lines.contains("Show Notes"), "heading absent: \(lines)")
            XCTAssertEqual(lines.filter { $0.contains("Hide Notes") }.count, 1, "\(lines)")
            XCTAssertTrue(lines.joined(separator: " ").contains(hasNotes ? "quiet machine" : "did not include show notes"), "\(lines)")
            try retainCopyEvidence(WiltedMacHeadless.render(view, size: size),
                                   name: hasNotes ? "fullplayer-notes-light" : "fullplayer-notes-empty-light")
        }
    }

    private func retainCopyEvidence(_ bitmap: NSBitmapImageRep, name: String) throws {
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeModel() -> (WiltedMacModel, RecordingNowPlayingSink, RecordingRemoteCommandSource) {
        let sink = RecordingNowPlayingSink()
        let commands = RecordingRemoteCommandSource()
        let suite = "com.zerodelta.wilted.mac.nowplaying-tests.\(UUID().uuidString)"
        suiteNames.append(suite)
        let preferences = UserDefaults(suiteName: suite) ?? .standard
        let directory = wiltedTemporaryDirectory("now-playing")
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory,
                                   nowPlayingSink: sink, remoteCommandSource: commands,
                                   preferences: preferences)
        return (model, sink, commands)
    }

    private func episode(id: String = "episode-1", prepared: Bool = true) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: "The Cost of Everything", feedTitle: "Quarterly",
            summary: "One line.", artworkURL: URL(string: "https://example.com/art.png"),
            releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 1_800,
            playbackSeconds: 0, downloadState: .completed,
            preparationState: prepared ? .prepared(summary: "Clean") : .notPrepared,
            isReadyMediaAvailable: true
        )
    }

    private func article() -> WiltedMacArticle {
        WiltedMacArticle(
            id: "article-1", title: "A Long Read", source: "example.com",
            url: URL(string: "https://example.com/read")!, isReady: true,
            durationSeconds: 300, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
