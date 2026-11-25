import AppKit
import SwiftUI
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import WiltedWeather
@testable import WiltedMac

@MainActor
private final class ActiveHeadlineSpeaker: BulletinSpeaking {
    private(set) var spokenText: String?
    private var completion: (@MainActor () -> Void)?

    func speak(_ text: String, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        spokenText = text
        completion = finished
        return true
    }

    func stop() { completion = nil }

    func finish() {
        let action = completion
        completion = nil
        action?()
    }
}

@MainActor
private final class ActiveHeadlineRoute: MacAudioRouteSource {
    func start(changed: @escaping @MainActor () -> Void) -> Bool { true }
    func currentRoute() -> MacAudioRoute? { MacAudioRoute(device: 27) }
    func stop() {}
}

@MainActor
final class WiltedMacActiveHeadlineCardTests: XCTestCase {
    private static let featuredHeadlinePreferenceKey = "wilted.bulletins.featuredHeadlineStoryID"

    func testMainWindowKeepsTheAnnouncedStoryVisibleAcrossPlayerLayoutsAndAfterSpeech() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("active-headline-card"), readyCount: 2)
        let model = library.model
        let (backend, _) = library.installScriptedPlayback(on: model)
        let speaker = ActiveHeadlineSpeaker()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let story = try LibraryHeadlineStory(
            id: "active-headline", title: "Council approves night service", publisherID: "city-wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/night-service"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        let newer = try LibraryHeadlineStory(
            id: "newer-headline", title: "Transit board meets today", publisherID: "city-wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/transit-board"),
            publishedAt: now.addingTimeInterval(60), firstSeenAt: now, lastSeenAt: now)
        _ = try model.headlineCatalogStore.mergeRecent([newer, story], at: now)
        model.headlineCatalogState.refresh(at: now)

        addTeardownBlock {
            await MainActor.run {
                model.playback?.disableInterruptions(resuming: false)
                model.stopBulletinsWithoutResuming()
            }
            await model.close()
        }

        model.selectedNavigation = .larder
        model.playEpisode(library.episodes[0])
        await model.waitForPlaybackOperationForTesting()
        let playback = try XCTUnwrap(model.playback)
        XCTAssertTrue(playback.enableInterruptions(
            speaker: speaker, waitLimit: 30, routeSource: ActiveHeadlineRoute(),
            shouldSpeakHeadline: { $0.kind == .headline && $0.headlineStoryID == story.id },
            didStartHeadline: { bulletin in
                if let storyID = bulletin.headlineStoryID {
                    model.preferences.set(storyID, forKey: Self.featuredHeadlinePreferenceKey)
                }
            },
            now: { now }))
        let bulletin = try Bulletin(
            id: "headline:active-headline", kind: .headline,
            text: "City Wire. Council approves night service", issuedAt: now,
            expiresAt: now.addingTimeInterval(3_600), storyID: story.id,
            publisherID: story.publisherID, publisherName: story.publisherName,
            headline: story.title, link: story.link, publishedAt: story.publishedAt)
        playback.deliverBulletin(bulletin)
        XCTAssertNil(speaker.spokenText, "a headline waits for a break or episode boundary")
        model.nextPlayback()
        await model.waitForPlaybackOperationForTesting()
        await WiltedMacHeadless.eventually("the headline begins at an episode boundary") {
            speaker.spokenText == bulletin.text
        }

        XCTAssertEqual(model.speakingBulletin?.headlineStoryID, story.id)
        XCTAssertEqual(
            WiltedMacPlayerContent.selectHeadlineCard(
                speaking: bulletin, lastSpokenStoryID: newer.id, pendingStoryID: newer.id,
                projection: model.headlineCatalogState.projection)?.id,
            story.id,
            "the actual speaker remains selected ahead of a newer pending story")
        let history = WiltedMacHeadlineHistoryDisclosure(
            model: model, isExpanded: .constant(true), chooseReadingVoice: model.openReadingVoiceSettings)
        XCTAssertFalse(history.headlinesList.recent.contains(where: { $0.id == story.id }),
                       "the active story stays in its window card instead of appearing twice in Recent")
        XCTAssertTrue(history.headlinesList.recent.contains(where: { $0.id == newer.id }),
                      "other recent stories remain available")

        for destination: WiltedMacNavigation in [.feeds, .larder, .settings] {
            model.selectedNavigation = destination
            for width in [CGFloat(1_500), 900] {
                let during = try WiltedMacHeadless.recognizedText(
                    WiltedMacRootView(model: model), size: CGSize(width: width, height: 1_050)).joined(separator: " ")
                XCTAssertTrue(during.contains("City Wire"), "publisher remains visible on \(destination) at width \(width): \(during)")
                XCTAssertTrue(during.contains(story.title), "the announced story remains visible on \(destination) at width \(width): \(during)")
                XCTAssertTrue(during.contains("Read story"), "article link remains available on \(destination): \(during)")
                XCTAssertTrue(during.contains("Listen next"), "queue action remains available on \(destination): \(during)")
                XCTAssertTrue(during.contains("Reading this story"), "active speech is identified on \(destination): \(during)")
                XCTAssertTrue(during.filter { !$0.isWhitespace }.contains("Stopreading"),
                              "active speech can be stopped on \(destination): \(during)")
                XCTAssertFalse(during.contains(newer.title), "the card does not drift to a newer unrelated story")
            }
        }

        let expanded = try WiltedMacHeadless.recognizedText(
            WiltedMacRootView(model: model, initialPlayerPresentation: .notes),
            size: CGSize(width: 1_500, height: 1_050)).joined(separator: " ")
        XCTAssertTrue(expanded.contains("City Wire"), expanded)
        XCTAssertTrue(expanded.contains(story.title), expanded)
        XCTAssertTrue(expanded.contains("Read story"), expanded)
        XCTAssertTrue(expanded.contains("Listen next"), expanded)
        XCTAssertTrue(expanded.contains("Reading this story"), expanded)
        XCTAssertTrue(expanded.filter { !$0.isWhitespace }.contains("Stopreading"), expanded)
        XCTAssertEqual(expanded.components(separatedBy: story.title).count - 1, 1,
                       "the full-window player keeps a single root-level story card")

        speaker.finish()
        XCTAssertNil(model.speakingBulletin)
        model.bulletinHub.shutdown()
        model.installBulletinHubForTesting(WiltedMacBulletinHub(model: model))
        XCTAssertEqual(model.bulletinHub.featuredHeadlineStoryID, story.id)
        model.selectedNavigation = .feeds
        let after = try WiltedMacHeadless.recognizedText(
            WiltedMacRootView(model: model), size: CGSize(width: 1_500, height: 1_050)).joined(separator: " ")
        XCTAssertTrue(after.contains("City Wire"), after)
        XCTAssertTrue(after.contains(story.title), after)
        XCTAssertTrue(after.contains("Read story"), after)
        XCTAssertTrue(after.contains("Listen next"), after)
        XCTAssertFalse(after.contains("Reading this story"), after)
        XCTAssertFalse(after.filter { !$0.isWhitespace }.contains("Stopreading"), after)
        XCTAssertFalse(after.contains(newer.title), "after speech, selection stays bound to the announced story")
        XCTAssertEqual(backend.isPlaying, true, "finishing a headline resumes the episode")
    }

    func testNoActiveHeadlineDoesNotPromoteTheNewestCandidateIntoTheCard() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let newest = try LibraryHeadlineStory(
            id: "newest-only", title: "A recent candidate", publisherID: "wire", publisherName: "Wire",
            link: URL(string: "https://wire.example.test/newest"), publishedAt: now,
            firstSeenAt: now, lastSeenAt: now)
        let projection = try LibraryHeadlineProjection(
            revision: 1, updatedAt: now, recent: [newest], saved: [], publishers: [])

        XCTAssertNil(WiltedMacPlayerContent.selectHeadlineCard(
            speaking: nil, lastSpokenStoryID: nil, projection: projection))

        XCTAssertEqual(
            WiltedMacPlayerContent.selectHeadlineCard(
                speaking: nil, lastSpokenStoryID: "previously-announced", pendingStoryID: newest.id,
                projection: projection)?.id,
            newest.id,
            "a real pending announcement is eligible, but arbitrary recent rows are not")
    }

    func testNarrationStatusKeepsVoiceChoiceAndFailureVisibleWithStoryActions() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        addTeardownBlock { await model.close() }
        XCTAssertEqual(
            WiltedMacRootView.narrationStatus(
                for: .unavailable(
                    storyID: "voice-choice", bulletinID: "headline:voice-choice", voiceID: .paulHarvey,
                    reason: .voiceFilesMissing)),
            .unavailable,
            "a missing selected voice reports unavailable audio rather than asking for a new selection")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let story = try LibraryHeadlineStory(
            id: "voice-choice", title: "Council approves night service", publisherID: "city-wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/night-service"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        let voiceChoice = WiltedMacPlayerHeadlineCard(
            model: model, story: story, isSpeakingHeadline: false, stopReading: {},
            narrationStatus: .chooseVoice)
        let choiceText = try WiltedMacHeadless.recognizedText(
            voiceChoice, size: CGSize(width: 900, height: 420)).joined(separator: " ")
        XCTAssertTrue(choiceText.contains("Choose story voice"), choiceText)
        XCTAssertTrue(choiceText.contains("Read story"), choiceText)
        XCTAssertTrue(choiceText.contains("Listen next"), choiceText)

        voiceChoice.chooseNarrationVoice()
        XCTAssertEqual(model.selectedNavigation, .settings)
        XCTAssertEqual(model.settingsSection, .reports)

        let failedListenNext = try LibraryListenNextRequestSnapshot(
            requestID: "missing-voice-request", story: story, requesterDeviceID: "synthetic-mac",
            ownerToken: "synthetic-owner", operationGeneration: 1, anchorID: nil,
            createdAt: now, status: .failed, audioOffer: nil, voiceID: nil, voiceRevision: nil,
            failure: .missingVoice)
        XCTAssertTrue(WiltedMacPlayerHeadlineCard.listenNextAlreadyOffersVoiceChoice(
            request: failedListenNext, actionMessage: nil))
        XCTAssertTrue(WiltedMacPlayerHeadlineCard.listenNextAlreadyOffersVoiceChoice(
            request: nil, actionMessage: WiltedHeadlineStoryCard.listenNextFailureMessage(.missingVoice)))

        let preparing = WiltedMacPlayerHeadlineCard(
            model: model, story: story, isSpeakingHeadline: false, stopReading: {}, narrationStatus: .preparing)
        let preparingText = try WiltedMacHeadless.recognizedText(
            preparing, size: CGSize(width: 900, height: 420)).joined(separator: " ")
        XCTAssertTrue(preparingText.contains("Preparing headline audio"), preparingText)
        XCTAssertTrue(preparingText.contains("Read story"), preparingText)
        XCTAssertTrue(preparingText.contains("Listen next"), preparingText)

        let unavailable = WiltedMacPlayerHeadlineCard(
            model: model, story: story, isSpeakingHeadline: false, stopReading: {}, narrationStatus: .unavailable)
        let unavailableText = try WiltedMacHeadless.recognizedText(
            unavailable, size: CGSize(width: 900, height: 420)).joined(separator: " ")
        XCTAssertTrue(unavailableText.contains("Headline audio unavailable"), unavailableText)
        XCTAssertTrue(unavailableText.contains("Read story"), unavailableText)
        XCTAssertTrue(unavailableText.contains("Listen next"), unavailableText)
    }
}
