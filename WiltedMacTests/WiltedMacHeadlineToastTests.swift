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
