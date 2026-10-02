import SwiftUI
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Touch targets and the Larder screens' controls, on the shipping views hosted in a real window.
/// Controls the system sizes are exempt and named here: the navigation bar's Filter (36 pt) and Done
/// (35 pt) items and the Settings stepper (32 pt tall).
@MainActor
final class LibraryHitTargetTests: XCTestCase {
    private var fixture: LibraryViewFixture!
    private let minimum = WiltedTheme.Spacing.minimumTouchTarget

    override func setUp() async throws {
        await HostedAccessibility.prepare()
        fixture = try LibraryViewFixture()
    }
    override func tearDown() async throws { fixture.tearDown() }

    /// a: downloaded and started, b: downloaded, c: not downloaded.
    private func seedMixed() async throws {
        try await fixture.queue(["a", "b", "c"])
        for raw in ["a", "b"] {
            try await fixture.offer(raw)
            try await fixture.cacheAudio(raw)
        }
        try await fixture.offer("c", .available)
        try await fixture.startOnMac("a")
        await fixture.model.refresh()
    }

    private func assertTargets(_ buttons: [HostedElement], in what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(buttons.isEmpty, "\(what) has buttons", file: file, line: line)
        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.frame.width, minimum, "\(button.identifier ?? "?") width", file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.height, minimum, "\(button.identifier ?? "?") height", file: file, line: line)
        }
        for (index, first) in buttons.enumerated() {
            for second in buttons[(index + 1)...] {
                XCTAssertTrue(
                    first.frame.intersection(second.frame).isNull || first.frame.intersection(second.frame).isEmpty,
                    "\(first.identifier ?? "?") and \(second.identifier ?? "?") overlap", file: file, line: line)
            }
        }
    }

    func testListRowButtonsAreFullTouchTargetsThatDoNotOverlap() async throws {
        try await seedMixed()
        let hosted = HostedView(NavigationStack { LibraryListView(model: fixture.model, onPlay: { _ in }) })
        let buttons = hosted.elements().filter { $0.isButton && ($0.identifier ?? "").hasPrefix("wilted-library-") }
            .filter { $0.identifier != "wilted-library-filter" }
        assertTargets(buttons, in: "the Larder list")
        XCTAssertGreaterThanOrEqual(buttons.count, 5, "Play, Delete download and Download on the three rows")
        let width = hosted.window.bounds.width
        XCTAssertTrue(buttons.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= width })
    }

    /// A ScrollView's content is in the tree even when it is the first hosted view in the process (run alone
    /// with -only-testing): the detail and Settings both scroll, and both once came back with no elements.
    func testAScrollViewsContentIsReachableInAFreshHostedView() async throws {
        let hosted = HostedView(ScrollView { Button("Probe") {}.accessibilityIdentifier("wilted-test-scroll-probe") })
        XCTAssertNotNil(hosted.element("wilted-test-scroll-probe"))
    }

    func testDetailButtonsAreFullTouchTargetsAndOfferWhatTheRowOffers() async throws {
        try await seedMixed()
        let started = HostedView(NavigationStack { LibraryEpisodeDetailView(model: fixture.model, entryID: fixture.id("a"), onPlay: { _ in }) })
        assertTargets(started.elements().filter { $0.isButton && ($0.identifier ?? "").hasPrefix("wilted-library-") }, in: "the detail")
        XCTAssertNotNil(started.element("wilted-library-action-done-a"), "a started episode offers Mark completed")
        XCTAssertNotNil(started.element("wilted-library-action-remove-a"), "and Remove from Larder")

        let fresh = HostedView(NavigationStack { LibraryEpisodeDetailView(model: fixture.model, entryID: fixture.id("b"), onPlay: { _ in }) })
        XCTAssertNotNil(fresh.element("wilted-library-action-done-b"), "W-INV-010: audio on the phone offers it before it is started")
        XCTAssertNotNil(fresh.element("wilted-library-action-remove-b"))
    }

    func testSettingsControlsAreFullTouchTargetsExceptTheSystemStepper() async throws {
        try await seedMixed()
        let settings = LibrarySettingsStore(defaults: fixture.defaults)
        let hosted = HostedView(LibrarySettingsView(settings: settings, model: fixture.model, playingID: nil, onDone: {}))
        let ids = ["wilted-library-settings-text-scale-standard", "wilted-library-settings-text-scale-largest",
                   "wilted-library-settings-skip-back", "wilted-library-settings-skip-forward",
                   "wilted-library-settings-storage-info", "wilted-library-settings-remove-audio"]
        assertTargets(ids.compactMap { hosted.element($0) }, in: "Settings")
        XCTAssertEqual(ids.compactMap { hosted.element($0) }.count, ids.count)
        for stepper in hosted.elements().filter({ $0.identifier == "Increment" || $0.identifier == "Decrement" }) {
            XCTAssertGreaterThanOrEqual(stepper.frame.height, 32, "the system stepper: exempt, but never smaller than this")
        }
    }

    func testTheSpeedShownIsOnAQuarterStepEvenFromAnOldStoredValue() async throws {
        let settings = LibrarySettingsStore(defaults: fixture.defaults)
        let hosted = HostedView(LibrarySettingsView(settings: settings, model: fixture.model, playingID: nil, onDone: {}))
        XCTAssertNotNil(hosted.elements().first { $0.label == "1.25x" }, "the default, as the Settings row says it")
        XCTAssertNotNil(hosted.element("Increment"), "the stepper is there")

        settings.defaultSpeed = 1.1
        XCTAssertEqual(settings.defaultSpeed, 1.0, "set off the step, it lands on the nearest quarter")
        fixture.defaults.set(1.6, forKey: LibrarySettingsStore.speedKey)
        XCTAssertEqual(LibrarySettingsStore(defaults: fixture.defaults).defaultSpeed, 1.5, "and so does an old stored 0.05-step value")
    }

    // MARK: Transcript

    private func transcript() throws -> LibraryTranscript {
        try LibraryTranscript(
            entryID: fixture.id("a"), revisionID: RevisionID(rawValue: "rev-1"),
            cues: [LibraryTranscriptCue(start: 0, end: 4, text: "Hello there.", speaker: "Ann"),
                   LibraryTranscriptCue(start: 4, end: 9, text: "Hi.", speaker: nil)])
    }

    func testTranscriptNamesTheSpeakerAndEachCueSeeksWithAFullTouchTarget() throws {
        var sought: [Double] = []
        let hosted = HostedView(LibraryTranscriptView(
            transcript: try transcript(), position: 1, onSeek: { sought.append($0) }, height: 400))
        let cues = hosted.elements().filter { ($0.identifier ?? "").hasPrefix("wilted-library-transcript-cue-") }
        XCTAssertEqual(cues.count, 2)
        XCTAssertTrue(cues[0].label?.contains("Ann") == true, "the speaker is read with the cue: \(cues[0].label ?? "nil")")
        XCTAssertFalse(cues[1].label?.contains("Ann") == true, "a cue without a speaker names none")
        for cue in cues { XCTAssertGreaterThanOrEqual(cue.frame.height, minimum, cue.identifier ?? "") }
        XCTAssertTrue(try XCTUnwrap(hosted.element("wilted-library-transcript-cue-1")).activate())
        XCTAssertEqual(sought, [4], "tapping a cue seeks to its start")
    }

    func testTranscriptWithoutAPlayingItemOffersNoSeek() throws {
        let hosted = HostedView(LibraryTranscriptView(transcript: try transcript(), height: 400))
        XCTAssertTrue(hosted.elements().filter { ($0.identifier ?? "").hasPrefix("wilted-library-transcript-cue-") }.allSatisfy { !$0.isButton })
    }
}
