import AppKit
import XCTest
@testable import WiltedMac

/// Headless form of `testPodcastPlaybackJourneyAcrossDestinations`, which launched the app under
/// XCUITest. It drives the model through the same fixture and path (article playing, Keep in Feeds,
/// play from the Larder, seek through the transcript, every destination), asserts the state the
/// player showed, renders the transcript presentations, and checks the identifiers in view source.
@MainActor
final class WiltedMacPlaybackJourneyTests: XCTestCase {
    private let arguments = [
        "--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts",
        "--wilted-ui-fixture-prepared", "--wilted-ui-fixture-long-transcript",
    ]
    private let prefix = "wilted-now-playing-synced-transcript-"

    func testPodcastPlaybackJourneyAcrossDestinations() async throws {
        let model = await WiltedMacHeadless.model(self, arguments)

        // The article starts playing, and the fixture does not start faulted.
        await WiltedMacHeadless.eventually("article playing") { model.hasCurrentPlayback && model.isPlaying }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.playbackError, "a fixture that starts faulted documents a broken player")
        XCTAssertFalse(model.audioRouteFault)

        // Keep in Feeds, then the Larder offers it as the playable group.
        model.selectedNavigation = .feeds
        let episode = try XCTUnwrap(model.feedsEpisodes.first)
        model.decideFeedEpisodes(.keep, episodes: [episode])
        await WiltedMacHeadless.drainDecisions(model)
        model.selectedNavigation = .larder
        XCTAssertEqual(model.podcastQueueIDs, [episode.id])
        let playable = model.larderEpisodes(in: .playable)
        XCTAssertEqual(playable.map(\.id), [episode.id])
        XCTAssertFalse(model.isEpisodeFinished(try XCTUnwrap(playable.first)), "Play first is enabled")

        // Playing it from the Larder takes the player over.
        model.playLarderEpisode(episode)
        await WiltedMacHeadless.eventually("episode playing") {
            model.currentPodcastEpisodeID == episode.id && model.isPlaying
        }
        XCTAssertEqual(model.currentEpisode?.title, "Quiet Machines")

        // Play/pause is the one primary transport (Space invokes it).
        model.togglePlayback()
        // Toggle is ignored while a command is pending, so the pause has to have fully settled.
        await WiltedMacHeadless.eventually("paused") { !model.isPlaying && model.playbackCommands.pending == nil }
        model.togglePlayback()
        await WiltedMacHeadless.eventually("playing again") { model.isPlaying }
        XCTAssertNil(model.playbackError)

        // Scrubbing moves the active cue, and prepared cuts sit in the same transcript.
        await WiltedMacHeadless.eventually("duration") { model.playbackDurationSeconds > 0 }
        await WiltedMacHeadless.eventually("transcript and cuts") {
            model.currentTranscript?.cues.isEmpty == false && !model.currentRemovedSpans.isEmpty
        }
        let duration = model.playbackDurationSeconds
        XCTAssertEqual(model.currentRemovedSpans.map(\.id), Array(0..<8))
        XCTAssertTrue(model.currentRemovedSpans.contains { $0.id == 5 },
                      "prepared cuts stay in the synchronized transcript")
        // The fixture's cues are contiguous 14 s lines on the prepared clock, so the active cue at a
        // position is that position over 14 (the original journey scrubbed to 0.685 and 0.81 of the
        // duration and expected cues 67 and 79, which holds when the player reports 1370 s).
        let cues = try XCTUnwrap(model.currentTranscript).cues
        var active: [Int] = []
        for fraction in [0.685, 0.81] {
            await model.seekPlaybackForTesting(to: duration * fraction)
            let position = model.playbackPositionSeconds
            let cue = try XCTUnwrap(model.activeTranscriptCueID, "a cue is active at \(position)s")
            XCTAssertEqual(cue, min(Int(position / 14), cues.count - 1), "the cue under the scrubber is the active one")
            XCTAssertNotNil(cues.first { $0.id == cue })
            active.append(cue)
        }
        XCTAssertLessThan(active[0], active[1], "the next active cue follows the cue boundary")

        // The same live player follows the reader to every other destination.
        for destination in [WiltedMacNavigation.feeds, .settings, .larder] {
            model.selectedNavigation = destination
            XCTAssertTrue(model.hasCurrentPlayback, "\(destination)")
            XCTAssertTrue(model.isPlaying, "\(destination)")
            XCTAssertEqual(model.currentEpisode?.title, "Quiet Machines", "\(destination)")
            XCTAssertNil(model.playbackError, "\(destination)")
        }
        XCTAssertEqual(model.currentEpisode?.notes?.isEmpty, false,
                       "an episode started while an article plays brings its notes")
    }

    /// The transcript and notes presentations, as the rail and the full window draw them.
    func testTranscriptPresentationsRenderForThePlayingEpisode() async throws {
        let model = await WiltedMacHeadless.model(self, arguments)
        let episode = try XCTUnwrap(model.feedsEpisodes.first)
        model.decideFeedEpisodes(.keep, episodes: [episode])
        await WiltedMacHeadless.drainDecisions(model)
        model.playLarderEpisode(episode)
        await WiltedMacHeadless.eventually("episode playing") {
            model.currentPodcastEpisodeID == episode.id && model.isPlaying
        }
        await WiltedMacHeadless.eventually("duration") { model.playbackDurationSeconds > 0 }
        await WiltedMacHeadless.eventually("transcript") { model.currentTranscript?.cues.isEmpty == false }
        await model.seekPlaybackForTesting(to: model.playbackDurationSeconds * 0.685)

        for section in WiltedMacPlayerSection.allCases {
            let rail = try WiltedMacHeadless.render(
                WiltedMacCompactPlayer(model: model, presentation: .constant(section), focusRequest: nil),
                size: CGSize(width: 1100, height: 520))
            XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: rail), 8, "rail \(section) rendered blank")
            let full = try WiltedMacHeadless.render(WiltedMacFullWindowPlayer(
                model: model, presentation: .constant(section), onSelect: { _ in }, onCollapse: { _ in }))
            XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: full), 8, "full \(section) rendered blank")
        }
    }

    func testSelectedBPaneKeepsCompletionVisibleAndSecondaryActionsInNativePopover() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacNowPlayingPane.swift")
        func section(_ start: String, until end: String) throws -> String {
            let begin = try XCTUnwrap(source.range(of: start))
            let finish = try XCTUnwrap(source.range(of: end, range: begin.upperBound..<source.endIndex))
            return String(source[begin.lowerBound..<finish.lowerBound])
        }
        let header = try section("private var header:", until: "private var title:")
        XCTAssertTrue(header.contains("HStack("), "horizontal artwork/title header")
        XCTAssertTrue(header.contains("WiltedTheme.scaled(48, scale: model.textScale)"))
        XCTAssertFalse(header.contains("size: 110"))
        let transport = try section("private var transportRow:", until: "private var completionControl:")
        XCTAssertTrue(transport.contains("completionControl"))
        XCTAssertTrue(transport.contains("overflowButton"))
        XCTAssertFalse(transport.contains("speedControl"), "speed is only inside the popover")
        XCTAssertFalse(transport.contains("ViewThatFits"), "transport stays one compact row")
        XCTAssertTrue(transport.contains(".keyboardShortcut(\"r\", modifiers: .command)"))
        XCTAssertTrue(transport.contains("model.restartPlayback()"), "Cmd-R works while the popover is closed")
        let completion = try section("private var completionControl:", until: "private var speedControl:")
        XCTAssertTrue(completion.contains("model.markCurrentPlaybackCompleted()"))
        XCTAssertTrue(completion.contains(".disabled(model.playbackCompletionIsSettled)"))
        XCTAssertTrue(completion.contains("wilted-player-mark-completed"))
        let overflow = try section("private var overflowButton:", until: "var playbackActions:")
        XCTAssertTrue(overflow.contains("Button { showsPlaybackActions.toggle() }"))
        XCTAssertTrue(overflow.contains("Image(systemName: \"ellipsis\")"))
        XCTAssertTrue(overflow.contains(".popover(isPresented: $showsPlaybackActions"))
        XCTAssertTrue(overflow.contains("wilted-player-menu"))
        XCTAssertFalse(source.contains("Menu {"), "plain ellipsis must have no native menu chevron")
        let actions = try section("var playbackActions:", until: "var share:")
        for action in ["speedControl", "model.restartPlayback()", "share", "model.recoverAudioRoute()"] {
            XCTAssertTrue(actions.contains(action), action)
        }
        XCTAssertFalse(actions.contains("markCurrentPlaybackCompleted"))
        XCTAssertTrue(actions.contains("wilted-player-restart"))
        XCTAssertTrue(actions.contains("wilted-player-route-recovery"))
        XCTAssertTrue(actions.contains("if model.audioRouteFault {"))
        for identifier in ["wilted-player-menu", "wilted-player-speed", "wilted-player-mark-completed",
                           "wilted-player-restart", "wilted-player-route-recovery"] {
            XCTAssertEqual(WiltedMacHeadless.occurrences(of: "\"\(identifier)\"", in: source), 1, identifier)
        }
        XCTAssertTrue(source.contains("WiltedMacSpeedSaveLine(model: model)"))
        XCTAssertTrue(source.contains(".onKeyPress(.space)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(.leftArrow, modifiers: [.command, .shift])"))
        XCTAssertTrue(source.contains(".keyboardShortcut(.rightArrow, modifiers: [.command, .shift])"))
    }

    func testPaneActionsChangeRateRestartAndCompleteTheLoadedEpisode() async throws {
        let model = await WiltedMacHeadless.model(self, arguments)
        let episode = try XCTUnwrap(model.feedsEpisodes.first)
        model.decideFeedEpisodes(.keep, episodes: [episode])
        await WiltedMacHeadless.drainDecisions(model)
        model.playLarderEpisode(episode)
        await WiltedMacHeadless.eventually("episode playing") {
            model.currentPodcastEpisodeID == episode.id && model.isPlaying
        }
        model.setPlaybackRate(1.5)
        await WiltedMacHeadless.eventually("rate applied") { model.playbackRate == 1.5 }
        await model.seekPlaybackForTesting(to: 90)
        XCTAssertGreaterThan(model.playbackPositionSeconds, 80)
        let session = model.playback?.sessionID
        model.restartPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertNotEqual(model.playback?.sessionID, session)
        XCTAssertLessThan(model.playbackPositionSeconds, 5)
        XCTAssertEqual(model.playbackRate, 1.5, "restart preserves the popover speed")
        XCTAssertFalse(model.playbackCompletionIsSettled)
        model.markCurrentPlaybackCompleted()
        await WiltedMacHeadless.eventually("episode retired after completion") {
            model.hiddenEpisodeIDs.contains(episode.id) || model.episodes.first { $0.id == episode.id }?.retiredAt != nil
        }
        XCTAssertFalse(model.larderEpisodes(in: .playable).contains { $0.id == episode.id })
        XCTAssertNil(model.playbackError)
    }

    /// The identifiers and labels the journey looked up, one live definition each.
    func testPlayerSourceKeepsEveryTransportIdentifierAndLabelOnce() throws {
        let content = try WiltedMacHeadless.viewSource("WiltedMacPlayerContent.swift")
        for identifier in [
            "wilted-player-speed", "wilted-player-previous", "wilted-player-transcript", "wilted-player-notes",
            "wilted-player-volume", "wilted-player-scrubber", "wilted-player-next", "wilted-player-restart",
            "wilted-player-keyboard-transports",
        ] {
            XCTAssertEqual(WiltedMacHeadless.occurrences(of: "\"\(identifier)\"", in: content), 1,
                           "missing or duplicate \(identifier)")
        }
        for (symbol, value) in [
            ("playerRewindIdentifier", WiltedScreenCopy.playerRewindIdentifier),
            ("playerPlayPauseIdentifier", WiltedScreenCopy.playerPlayPauseIdentifier),
            ("playerForwardIdentifier", WiltedScreenCopy.playerForwardIdentifier),
        ] {
            XCTAssertEqual(WiltedMacHeadless.occurrences(of: "WiltedScreenCopy.\(symbol)", in: content), 1, symbol)
            XCTAssertTrue(value.hasPrefix("wilted-player-"), value)
        }
        XCTAssertEqual(WiltedScreenCopy.playerPlayPauseIdentifier, "wilted-player-play-pause")
        for label in ["Rewind 15 seconds", "Skip forward 30 seconds", "Playback position"] {
            XCTAssertTrue(content.contains("\"\(label)\""), label)
        }
        XCTAssertTrue(content.contains("label: model.isPlaying ? \"Pause\" : \"Play\""))
        XCTAssertTrue(content.contains(".onKeyPress(.space)"), "Space must invoke the primary transport")
        XCTAssertTrue(content.contains("if model.selectedNavigation != .larder {"),
                      "the player offers a way back to the Larder only off the Larder")
        XCTAssertTrue(content.contains("wilted-player-menu"))
        XCTAssertTrue(content.contains("if model.audioRouteFault {"),
                      "Recover audio appears only after route recovery fails")
        XCTAssertFalse(content.contains("wilted-player-status\""),
                       "plain playback state is conveyed by the play/pause transport")

        let root = try WiltedMacHeadless.viewSource("WiltedMacRootView.swift")
        let retire = try XCTUnwrap(root.range(of: ".onChange(of: model.selectedNavigation) {"))
        XCTAssertTrue(String(root[retire.upperBound...].prefix(80)).contains("playerPresentation = nil"),
                      "no overlay may still contain the player after a navigation change")
        XCTAssertTrue(root.contains(".allowsHitTesting(playerPresentation == nil)"))

        let sections = try WiltedMacHeadless.viewSource("WiltedMacLarderView+Sections.swift")
        for identifier in ["wilted-larder-play-first", "wilted-larder-prepare-all"] {
            XCTAssertTrue(sections.contains(identifier), identifier)
        }
        let larder = try ["WiltedMacLarderView.swift", "WiltedMacLarderView+Sections.swift", "WiltedMacLarderView+Rows.swift"]
            .map { try WiltedMacHeadless.viewSource($0) }.joined()
        XCTAssertTrue(larder.contains("\"wilted-larder-\\(group.rawValue.lowercased())-count\""))
        XCTAssertEqual("wilted-larder-\(WiltedMacLarderGroup.playable.rawValue.lowercased())-count", "wilted-larder-ready-count")
        XCTAssertTrue(larder.contains("wilted-mac-larder-detail"))
        XCTAssertTrue(larder.contains("wilted-larder-play-\\(episode.id)"))
    }
}
