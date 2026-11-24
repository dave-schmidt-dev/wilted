import AppKit
import SwiftUI
import XCTest
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacHeadlineCardTests: XCTestCase {
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
        let saved = try LibraryHeadlineStory(
            id: "saved", title: "Rail service expands", publisherID: "wire", publisherName: "City Wire",
            link: URL(string: "https://wire.example.test/saved"), publishedAt: now, firstSeenAt: now,
            lastSeenAt: now, savedAt: now, savedRevision: 1)
        let publisher = try LibraryHeadlinePublisher(id: "wire", name: "City Wire", isMuted: false, revision: 0)
        let view = WiltedHeadlinesList(
            recent: [recent], saved: [saved], publishers: [publisher], actionInProgress: false,
            actionMessage: nil, setSaved: { _, _ in }, setMuted: { _, _ in })

        let rendered = try WiltedMacHeadless.recognizedText(
            view, size: CGSize(width: 1_000, height: 900)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("Recent headlines"), rendered)
        XCTAssertTrue(rendered.contains("Saved stories"), rendered)
        XCTAssertTrue(rendered.contains("Council approves night service"), rendered)
        XCTAssertTrue(rendered.contains("Rail service expands"), rendered)
        XCTAssertTrue(rendered.contains("Read story"), rendered)
        XCTAssertTrue(rendered.contains("Save"), rendered)
        XCTAssertTrue(rendered.contains("Mute this source"), rendered)
        XCTAssertTrue(rendered.contains("Unsave"), rendered)
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

        XCTAssertTrue(rendered.contains("Recent and saved stories"), rendered)
        XCTAssertTrue(rendered.contains("Weather alerts"), rendered)
        XCTAssertTrue(rendered.contains("Read headlines aloud"), rendered)
        XCTAssertTrue(rendered.contains("Story voice"), rendered)
        XCTAssertTrue(rendered.contains("Choose a reading voice"), rendered)
        XCTAssertFalse(model.automationSettings.alertsEnabled)
        XCTAssertTrue(model.automationSettings.headlinesEnabled)
        XCTAssertFalse(model.automationSettings.interruptionsEnabled)
    }
}
