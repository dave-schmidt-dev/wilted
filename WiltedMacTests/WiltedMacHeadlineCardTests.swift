import AppKit
import SwiftUI
import XCTest
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacHeadlineCardTests: XCTestCase {
    func testRoleVoicesInheritTheOldSelectionOnceThenPersistIndependently() throws {
        let preferences = WiltedMacTestPreferences.ephemeral()
        preferences.set(ApprovedReadingVoiceID.wolfmanJack.rawValue,
                        forKey: WiltedMacReadingVoiceSelection.preferenceKey)

        let selection = WiltedMacReadingVoiceSelection(preferences: preferences)
        XCTAssertEqual(selection.headlineVoiceID, .wolfmanJack)
        XCTAssertEqual(selection.weatherVoiceID, .rodSerling)
        XCTAssertEqual(selection.morningReportVoiceID, .caseyKasem)

        selection.select(ApprovedReadingVoiceID.paulHarvey.rawValue)
        selection.selectHeadlineVoice(.caseyKasem)
        selection.selectWeatherVoice(.paulHarvey)
        selection.selectMorningReportVoice(.wolfmanJack)

        let restored = WiltedMacReadingVoiceSelection(preferences: preferences)
        XCTAssertEqual(restored.selectedVoice, .paulHarvey)
        XCTAssertEqual(restored.headlineVoiceID, .caseyKasem)
        XCTAssertEqual(restored.weatherVoiceID, .paulHarvey)
        XCTAssertEqual(restored.morningReportVoiceID, .wolfmanJack)
    }

    func testRoleVoiceDefaultsWhenThereIsNoPreviousStoryVoice() throws {
        let preferences = WiltedMacTestPreferences.ephemeral()

        let selection = WiltedMacReadingVoiceSelection(preferences: preferences)

        XCTAssertEqual(selection.headlineVoiceID, .paulHarvey)
        XCTAssertEqual(selection.weatherVoiceID, .rodSerling)
        XCTAssertEqual(selection.morningReportVoiceID, .caseyKasem)
    }

    func testSpeakingHeadlineWinsOverNewerCandidateAndKeepsItsArticleLink() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let announcedLink = try XCTUnwrap(URL(string: "https://wire.example.test/story/announced"))
        let announced = try LibraryHeadlineStory(
            id: "announced", title: "Council approves night service", publisherID: "wire",
            publisherName: "City Wire", link: announcedLink, publishedAt: now.addingTimeInterval(-90),
            firstSeenAt: now, lastSeenAt: now)
        let newer = try LibraryHeadlineStory(
            id: "newer", title: "Transit board meets today", publisherID: "wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/story/newer"),
            publishedAt: now.addingTimeInterval(-10), firstSeenAt: now, lastSeenAt: now)
        let projection = try LibraryHeadlineProjection(
            revision: 2, updatedAt: now, recent: [newer, announced], saved: [], publishers: [])
        let bulletin = try Bulletin(
            id: "headline:announced", kind: .headline, text: "City Wire. Council approves night service",
            issuedAt: now, expiresAt: now.addingTimeInterval(3_600), storyID: "announced",
            publisherID: "wire", publisherName: "City Wire", headline: announced.title,
            link: announcedLink, publishedAt: announced.publishedAt)

        let selected = WiltedMacPlayerContent.selectHeadlineCard(
            speaking: bulletin, lastSpokenStoryID: "newer", projection: projection)

        XCTAssertEqual(selected?.id, "announced")
        XCTAssertEqual(selected?.title, "Council approves night service")
        XCTAssertEqual(selected?.link, announcedLink)

        let selectedAfterSpeech = WiltedMacPlayerContent.selectHeadlineCard(
            speaking: nil, lastSpokenStoryID: "announced", projection: projection)
        XCTAssertEqual(selectedAfterSpeech?.id, "announced", "the player keeps the spoken story selected")
        XCTAssertEqual(selectedAfterSpeech?.link, announcedLink)
    }

    func testCardAndRecentListRenderReadSaveAndMuteActions() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = try LibraryHeadlineStory(
            id: "recent", title: "Council approves night service", publisherID: "wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/story"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        let savedRecent = try LibraryHeadlineStory(
            id: "saved-recent", title: "Rail service expands", publisherID: "wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/saved"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now, savedAt: now, savedRevision: 1)
        let publisher = try LibraryHeadlinePublisher(id: "wire", name: "City Wire", isMuted: false, revision: 0)
        let view = WiltedHeadlinesList(
            recent: [recent, savedRecent], publishers: [publisher], actionInProgress: false,
            actionMessage: nil, setSaved: { _, _ in }, setMuted: { _, _ in })

        let rendered = try WiltedMacHeadless.recognizedText(
            view, size: CGSize(width: 1_000, height: 900)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("Recent headlines"), rendered)
        XCTAssertFalse(rendered.contains("Saved stories"), rendered)
        XCTAssertTrue(rendered.contains("Council approves night service"), rendered)
        XCTAssertTrue(rendered.contains("Rail service expands"), rendered)
        XCTAssertTrue(rendered.contains("Read story"), rendered)
        XCTAssertTrue(rendered.contains("Save to Notebook"), rendered)
        XCTAssertTrue(rendered.contains("Mute this source"), rendered)
        XCTAssertTrue(rendered.contains("Remove from Notebook"), rendered)
    }

    func testTickerRendersKeyboardReachableHeadlinesAndUsesPinnedStoryActions() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        addTeardownBlock { await model.close() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let story = try LibraryHeadlineStory(
            id: "ticker-story", title: "Council approves night service", publisherID: "wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/story"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        _ = try model.headlineCatalogStore.mergeRecent([story], at: now)
        model.headlineCatalogState.refresh(at: now)
        model.headlineTickerEnabled = true

        let ticker = WiltedMacHeadlineTicker(model: model, stories: [story])
        let rendered = try WiltedMacHeadless.recognizedText(
            ticker, size: CGSize(width: 900, height: 100)).joined(separator: " ")
        let source = try WiltedMacHeadless.viewSource("WiltedMacPlayerHeadlineCard.swift")

        XCTAssertTrue(rendered.contains("Headlines"), rendered)
        XCTAssertTrue(rendered.contains("City Wire"), rendered)
        XCTAssertTrue(rendered.contains("Council approves night service"), rendered)
        XCTAssertTrue(source.contains(".focused($focusedStoryID, equals: story.id)"), source)
        XCTAssertTrue(source.contains(".popover(item: $selectedStorySnapshot"), source)
        XCTAssertTrue(source.contains("WiltedMacPlayerHeadlineCard("), source)
        XCTAssertTrue(source.contains("queue audio after the current episode"), source)
    }

    func testTickerShowsAnEmptyStateWhenNoRecentStoriesExist() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        addTeardownBlock { await model.close() }
        let ticker = WiltedMacHeadlineTicker(model: model, stories: [])

        let rendered = try WiltedMacHeadless.recognizedText(
            ticker, size: CGSize(width: 900, height: 100)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("No recent stories yet"), rendered)
    }

    func testTickerPopoverResolvesLatestSavedStoryRevision() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = try LibraryHeadlineStory(
            id: "ticker-save-story", title: "A local story", publisherID: "wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/story"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        let saved = try LibraryHeadlineStory(
            id: original.id, title: original.title, publisherID: original.publisherID,
            publisherName: original.publisherName, link: original.link, publishedAt: original.publishedAt,
            firstSeenAt: original.firstSeenAt, lastSeenAt: now.addingTimeInterval(10),
            savedAt: now.addingTimeInterval(10), savedRevision: 2)
        let projection = try LibraryHeadlineProjection(
            revision: 2, updatedAt: now, recent: [original], saved: [saved], publishers: [])

        XCTAssertEqual(
            WiltedMacHeadlineTickerSelection.currentStory(matching: original, in: projection), saved)
    }

    func testNotebookShowsSavedHeadlineWithItsOriginalLinkAndListenNextAction() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        addTeardownBlock { await model.close() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let link = try XCTUnwrap(URL(string: "https://wire.example.test/saved"))
        let story = try LibraryHeadlineStory(
            id: "saved-headline", title: "Rail service expands", publisherID: "wire",
            publisherName: "City Wire", link: link, publishedAt: now, firstSeenAt: now,
            lastSeenAt: now)
        _ = try model.headlineCatalogStore.mergeRecent([story], at: now)
        _ = try model.headlineCatalogStore.setSaved(
            story: story, isSaved: true, basedOnRevision: story.savedRevision,
            commandID: "save-headline", at: now)
        model.headlineCatalogState.refresh(at: now)

        let rendered = try WiltedMacHeadless.recognizedText(
            WiltedMacNotebookView(model: model), size: CGSize(width: 1_000, height: 900)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("Saved stories"), rendered)
        XCTAssertTrue(rendered.contains("Rail service expands"), rendered)
        XCTAssertTrue(rendered.contains("Read story"), rendered)
        XCTAssertTrue(rendered.contains("Remove from Notebook"), rendered)
        XCTAssertTrue(rendered.contains("Listen next"), rendered)
        XCTAssertFalse(rendered.contains("Notebook is empty"), rendered)
    }

    func testNotebookDoesNotReportEmptyWhenSavedHeadlinesCannotLoad() async throws {
        let directory = wiltedTemporaryDirectory("notebook-headline-load-failure")
        let catalogURL = directory.appendingPathComponent("headline-catalog.json")
        try Data("not-json".utf8).write(to: catalogURL)
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral())
        await model.waitForFixturePodcastInstallForTesting()
        addTeardownBlock { await model.close() }

        let rendered = try WiltedMacHeadless.recognizedText(
            WiltedMacNotebookView(model: model), size: CGSize(width: 1_000, height: 900)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("Saved stories could not be loaded"), rendered)
        XCTAssertFalse(rendered.contains("Notebook is empty"), rendered)
    }

    func testSpeakingCardShowsTheStoryAndAnImmediateStopAction() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let story = try LibraryHeadlineStory(
            id: "announced", title: "Council approves night service", publisherID: "wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/story"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        let view = WiltedHeadlineStoryCard(
            story: story, isMuted: false, actionInProgress: false,
            setSaved: { _ in }, setMuted: { _ in }, isSpeakingHeadline: true)

        let rendered = try WiltedMacHeadless.recognizedText(
            view, size: CGSize(width: 760, height: 240)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("Council approves night service"), rendered)
        XCTAssertTrue(rendered.contains("Reading this story"), rendered)
        XCTAssertTrue(rendered.filter { !$0.isWhitespace }.contains("Stopreading"), rendered)
        let cardSource = try WiltedMacHeadless.viewSource("WiltedHeadlinesList.swift")
        XCTAssertTrue(cardSource.contains("Button(\"Stop reading\", action: stopReading)"))
        XCTAssertTrue(cardSource.contains(".accessibilityLabel(\"Stop reading\")"))
        XCTAssertTrue(rendered.contains("Read story"), rendered)
    }

    func testReadStoryRejectsNonWebOrCredentialBearingLinks() throws {
        XCTAssertNil(WiltedHeadlineStoryCard.readableLink(URL(string: "file:///etc/passwd")))
        XCTAssertNil(WiltedHeadlineStoryCard.readableLink(URL(string: "https://user:secret@example.test/story")))
        XCTAssertEqual(WiltedHeadlineStoryCard.readableLink(URL(string: "https://example.test/story"))?.host,
                       "example.test")
    }

    func testVoiceChoiceHasNoDefaultAndPersistsTheSelectedRevision() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        addTeardownBlock { await model.close() }
        XCTAssertNil(model.selectedReadingVoiceID)
        XCTAssertNil(model.readingVoiceRevision)

        model.selectReadingVoice(ApprovedReadingVoiceID.caseyKasem.rawValue)

        XCTAssertEqual(model.selectedReadingVoiceID, "casey-kasem")
        XCTAssertEqual(model.readingVoiceRevision, ArticleNarrationCoordinator.voiceRevision(for: .caseyKasem))
        XCTAssertEqual(model.readingVoiceSelection.selectedVoice?.displayName, "Casey Kasem")
        XCTAssertFalse(model.readingVoiceSelection.selectedStatus.isEmpty)

        model.selectReadingVoice(nil)
        XCTAssertNil(model.selectedReadingVoiceID)
        XCTAssertNil(model.readingVoiceRevision)
    }

    func testHeadlineSpeechSettingStaysSeparateFromWeatherAndInterruptionSwitches() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        addTeardownBlock { await model.close() }
        model.updateAutomationSettings { current in
            current.updatingReports {
                $0.interruptionsEnabled = false
                $0.alertsEnabled = false
                $0.headlinesEnabled = true
            }
        }

        let card = WiltedMacReportsCard(
            model: model, location: model.bulletinHub.location, startsExpanded: true)
        let rendered = try WiltedMacHeadless.recognizedText(
            card, size: CGSize(width: 900, height: 1_000)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("Recent stories"), rendered)
        XCTAssertTrue(rendered.contains("Weather alerts"), rendered)
        XCTAssertTrue(rendered.contains("Read headlines aloud"), rendered)
        XCTAssertTrue(rendered.contains("Headline voice"), rendered)
        XCTAssertTrue(rendered.contains("Weather voice"), rendered)
        XCTAssertTrue(rendered.contains("Morning report voice"), rendered)
        XCTAssertTrue(rendered.contains("Story voice"), rendered)
        XCTAssertTrue(rendered.contains("Choose a voice for stories you queue"), rendered)
        XCTAssertFalse(model.automationSettings.alertsEnabled)
        XCTAssertTrue(model.automationSettings.headlinesEnabled)
        XCTAssertFalse(model.automationSettings.interruptionsEnabled)
    }
}
