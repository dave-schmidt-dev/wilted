import Foundation
import XCTest
import AppKit
import MediaPlayer
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
    private var directories: [URL] = []
    private var suiteNames: [String] = []

    // Async, so the override inherits this class's main actor isolation. The
    // synchronous form is unisolated, and reaching the two properties from it
    // is exactly the kind of isolation slip that crashed this feature once.
    override func tearDown() async throws {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories.removeAll()
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
        let queue = ["episode-1", "episode-2", "episode-3"]
        model.installPlaybackStateForTesting(episode: episode(id: "episode-2"), isPlaying: true,
                                             position: 0, duration: 1_800, queue: queue)
        model.publishNowPlaying()
        XCTAssertEqual(commands.availability.last?.hasNext, true)
        XCTAssertEqual(commands.availability.last?.hasPrevious, true)

        model.installPlaybackStateForTesting(episode: episode(id: "episode-3"), isPlaying: true,
                                             position: 0, duration: 1_800, queue: queue)
        model.publishNowPlaying(force: true)
        XCTAssertEqual(commands.availability.last?.hasNext, false, "the last episode has nothing after it")
        XCTAssertEqual(commands.availability.last?.hasPrevious, true)
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
        XCTAssertTrue(WiltedMacModel.playbackRateChoices.contains(WiltedMacModel.initialPlaybackRate),
                      "the widget is told these speeds, so the default has to be one of them")
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

    private func makeModel() -> (WiltedMacModel, RecordingNowPlayingSink, RecordingRemoteCommandSource) {
        let sink = RecordingNowPlayingSink()
        let commands = RecordingRemoteCommandSource()
        let suite = "com.zerodelta.wilted.mac.nowplaying-tests.\(UUID().uuidString)"
        suiteNames.append(suite)
        let preferences = UserDefaults(suiteName: suite) ?? .standard
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-nowplaying-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory,
                                   nowPlayingSink: sink, remoteCommandSource: commands,
                                   preferences: preferences)
        return (model, sink, commands)
    }

    private func episode(id: String = "episode-1") -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: "The Cost of Everything", feedTitle: "Quarterly",
            summary: "One line.", artworkURL: URL(string: "https://example.com/art.png"),
            releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 1_800,
            playbackSeconds: 0, downloadState: .completed
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
