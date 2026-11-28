import Foundation
import XCTest
import WiltedLibrary
@testable import WiltedMac

final class WiltedMacHeadlineToastTests: XCTestCase {
    func testDurationDefaultsToFifteenSecondsAndClampsSavedValues() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        XCTAssertEqual(WiltedMacHeadlineToastPreference.duration(from: preferences), 15)

        preferences.set(35, forKey: WiltedMacHeadlineToastPreference.key)
        XCTAssertEqual(WiltedMacHeadlineToastPreference.duration(from: preferences), 35)

        preferences.set(0, forKey: WiltedMacHeadlineToastPreference.key)
        XCTAssertEqual(WiltedMacHeadlineToastPreference.duration(from: preferences), 5)
        preferences.set(600, forKey: WiltedMacHeadlineToastPreference.key)
        XCTAssertEqual(WiltedMacHeadlineToastPreference.duration(from: preferences), 60)
    }

    @MainActor
    func testDurationChangesPersistToTheModelPreferences() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let state = WiltedMacHeadlineToastPreferenceState(preferences: preferences)

        state.setDuration(35)

        XCTAssertEqual(state.durationSeconds, 35)
        XCTAssertEqual(preferences.integer(forKey: WiltedMacHeadlineToastPreference.key), 35)
    }

    @MainActor
    func testTickerPreferenceDefaultsOffAndPersistsItsSelection() {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let state = WiltedMacHeadlineToastPreferenceState(preferences: preferences)

        XCTAssertFalse(state.tickerEnabled)
        state.setTickerEnabled(true)

        XCTAssertTrue(state.tickerEnabled)
        XCTAssertTrue(preferences.bool(forKey: WiltedMacHeadlineToastPreference.tickerEnabledKey))
        XCTAssertTrue(WiltedMacHeadlineToastPreferenceState(preferences: preferences).tickerEnabled)
    }

    func testTickerMotionStopsForReducedMotionHoverKeyboardFocusAndStoryActions() {
        XCTAssertTrue(WiltedMacHeadlineTickerMotion.shouldAutoScroll(
            reduceMotion: false, isHovering: false, hasKeyboardFocus: false,
            isPresentingStory: false, storyCount: 2))
        for condition in [
            (true, false, false, false, 2),
            (false, true, false, false, 2),
            (false, false, true, false, 2),
            (false, false, false, true, 2),
            (false, false, false, false, 0)
        ] {
            XCTAssertFalse(WiltedMacHeadlineTickerMotion.shouldAutoScroll(
                reduceMotion: condition.0, isHovering: condition.1, hasKeyboardFocus: condition.2,
                isPresentingStory: condition.3, storyCount: condition.4))
        }
        XCTAssertTrue(WiltedMacHeadlineTickerMotion.shouldAutoScroll(
            reduceMotion: false, isHovering: false, hasKeyboardFocus: false,
            isPresentingStory: false, storyCount: 1))
    }

    func testTickerCrawlWrapsSeamlesslyAndRepeatsEnoughCopies() {
        XCTAssertEqual(WiltedMacHeadlineTickerMotion.wrapOffset(0, loopWidth: 500), 0)
        XCTAssertEqual(WiltedMacHeadlineTickerMotion.wrapOffset(530, loopWidth: 500), 30)
        XCTAssertEqual(WiltedMacHeadlineTickerMotion.wrapOffset(-20, loopWidth: 500), 480)
        XCTAssertGreaterThan(
            WiltedMacHeadlineTickerMotion.copiesNeeded(containerWidth: 1_100, loopWidth: 300), 2)
        XCTAssertEqual(
            WiltedMacHeadlineTickerMotion.focusedStoryOffset(leadingEdge: 740, leftInset: 12, loopWidth: 1_000),
            728)
    }

    func testKeyboardFocusStopsMotionBeforeSeekingEvenIfPauseArrivesLater() {
        var motion = WiltedMacHeadlineTickerMotionState()
        let start = Date(timeIntervalSinceReferenceDate: 100)
        motion.resume(at: start)
        motion.revealFocusedStory(at: 400, loopWidth: 1_000)
        motion.pause(at: start.addingTimeInterval(5), loopWidth: 1_000)
        XCTAssertEqual(motion.offset(at: start.addingTimeInterval(15), loopWidth: 1_000), 400)
    }

    func testTickerHoverFreezesExactPositionAndPinsIncomingSequenceUntilExit() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let hoverStart = start.addingTimeInterval(4)
        var motion = WiltedMacHeadlineTickerMotionState()
        motion.resume(at: start)
        let visibleOffset = motion.offset(at: hoverStart, loopWidth: 1_000)
        motion.pause(at: hoverStart, loopWidth: 1_000)
        XCTAssertEqual(motion.offset(at: hoverStart.addingTimeInterval(30), loopWidth: 1_000), visibleOffset)

        motion.resume(at: hoverStart.addingTimeInterval(30))
        XCTAssertEqual(
            motion.offset(at: hoverStart.addingTimeInterval(31), loopWidth: 1_000),
            WiltedMacHeadlineTickerMotion.wrapOffset(visibleOffset + 36, loopWidth: 1_000))

        let original = try LibraryHeadlineStory(
            id: "ticker-original", title: "Original lead", publisherID: "wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/original"),
            publishedAt: start, firstSeenAt: start, lastSeenAt: start)
        let prepended = try LibraryHeadlineStory(
            id: "ticker-prepended", title: "New lead", publisherID: "wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/new"),
            publishedAt: start.addingTimeInterval(1), firstSeenAt: start.addingTimeInterval(1),
            lastSeenAt: start.addingTimeInterval(1))
        var pin = WiltedMacHeadlineTickerSequencePin()
        pin.pin([original])
        XCTAssertEqual(pin.stories(current: [prepended, original]), [original])
        pin.release()
        XCTAssertEqual(pin.stories(current: [prepended, original]), [prepended, original])
    }

    func testSpeakingEventShowsOnceAndAccountResetAllowsNewStories() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let story = try LibraryHeadlineStory(
            id: "toast-story", title: "A new local story", publisherID: "local-wire",
            publisherName: "Local Wire", link: URL(string: "https://wire.example.test/story"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        var state = WiltedMacHeadlineToastState()

        XCTAssertTrue(state.present(story, eventID: "speaking:toast-story"))
        let pendingPresentation = try XCTUnwrap(state.presentationID)
        XCTAssertFalse(state.present(story, eventID: "speaking:toast-story"))
        XCTAssertEqual(state.presentationID, pendingPresentation)

        state.dismiss()
        XCTAssertNil(state.story)
        XCTAssertFalse(state.present(story, eventID: "speaking:toast-story"))

        state.reset()
        XCTAssertTrue(state.present(story, eventID: "speaking:toast-story"))
        XCTAssertNotEqual(state.presentationID, pendingPresentation)
    }

    func testPresentedEventHistoryIsBounded() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let story = try LibraryHeadlineStory(
            id: "bounded-toast-story", title: "A new local story", publisherID: "local-wire",
            publisherName: "Local Wire", link: URL(string: "https://wire.example.test/story"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        var state = WiltedMacHeadlineToastState()

        for index in 0...WiltedMacHeadlineToastState.historyLimit {
            XCTAssertTrue(state.present(story, eventID: "speaking:\(index)"))
        }

        XCTAssertEqual(state.seenEventIDs.count, WiltedMacHeadlineToastState.historyLimit)
    }

    func testToastReadsTheLatestSavedRevisionFromTheCatalog() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = try LibraryHeadlineStory(
            id: "toast-save-story", title: "A new local story", publisherID: "local-wire",
            publisherName: "Local Wire", link: URL(string: "https://wire.example.test/story"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        let saved = try LibraryHeadlineStory(
            id: original.id, title: original.title, publisherID: original.publisherID,
            publisherName: original.publisherName, link: original.link, publishedAt: original.publishedAt,
            firstSeenAt: original.firstSeenAt, lastSeenAt: now.addingTimeInterval(10),
            savedAt: now.addingTimeInterval(10), savedRevision: 2)
        let projection = try LibraryHeadlineProjection(
            revision: 2, updatedAt: now, recent: [original], saved: [saved], publishers: [])
        var state = WiltedMacHeadlineToastState()
        XCTAssertTrue(state.present(original, eventID: "speaking:\(original.id)"))

        XCTAssertEqual(state.currentStory(in: projection), saved)
    }

    @MainActor
    func testTimerFadesAfterItsDeadline() async throws {
        let timer = WiltedMacHeadlineToastTimer()
        var didFade = false

        timer.start(after: 0.02) { didFade = true }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(didFade)
    }

    @MainActor
    func testTimerPausesOnHoverAndResumesWithRemainingTime() async throws {
        let timer = WiltedMacHeadlineToastTimer()
        var didFade = false

        timer.start(after: 0.3) { didFade = true }
        try await Task.sleep(for: .milliseconds(20))
        timer.pause()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(didFade)

        timer.resume()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(didFade)
    }

    @MainActor
    func testDismissalCancelsTimerWithoutRunningItsFadeAction() async throws {
        let timer = WiltedMacHeadlineToastTimer()
        var didFade = false

        timer.start(after: 0.02) { didFade = true }
        timer.cancel()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(didFade)
    }
}
