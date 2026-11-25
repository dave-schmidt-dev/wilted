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

    func testHeadlineToastKeepsTheAnnouncedStoryVisibleAcrossPlayerLayoutsWhileShown() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("active-headline-card"), readyCount: 2)
        let model = library.model
        model.headlineToastDurationSeconds = 60
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
            speaker: speaker, routeSource: ActiveHeadlineRoute(),
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
        let size = CGSize(width: 1_500, height: 1_050)
        let (mainHost, mainWindow) = hostedRoot(model: model, size: size)
        _ = mainWindow
        playback.deliverBulletin(bulletin)
        XCTAssertNil(speaker.spokenText, "a headline waits for an ad-break snapshot")
        playback.adBreakReached()
        XCTAssertEqual(speaker.spokenText, bulletin.text)
        let toastVisible = await WiltedMacHeadless.eventually("the live window finishes showing the announced story") {
            guard let text = try? hostedText(mainHost) else { return false }
            return text.contains(story.title) && text.contains(story.publisherName)
        }
        XCTAssertTrue(toastVisible)

        XCTAssertEqual(model.speakingBulletin?.headlineStoryID, story.id)
        XCTAssertTrue(model.isPlaying, "the interruption keeps the listener's playing intent")
        XCTAssertEqual(
            WiltedMacPlayerContent.selectHeadlineCard(
                speaking: bulletin, lastSpokenStoryID: newer.id, pendingStoryID: newer.id,
                projection: model.headlineCatalogState.projection)?.id,
            story.id,
            "the actual speaker remains selected ahead of a newer pending story")
        let history = WiltedMacHeadlineHistoryDisclosure(
            model: model, isExpanded: .constant(true), chooseReadingVoice: model.openReadingVoiceSettings)
        XCTAssertTrue(history.headlinesList.recent.contains(where: { $0.id == story.id }),
                      "the story remains available after its toast fades")
        XCTAssertTrue(history.headlinesList.recent.contains(where: { $0.id == newer.id }),
                      "other recent stories remain available")

        for destination: WiltedMacNavigation in [.feeds, .larder, .settings] {
            model.selectedNavigation = destination
            let cardVisible = await WiltedMacHeadless.eventually("headline publisher and actions settle on \(destination)") {
                guard let text = try? hostedText(mainHost) else { return false }
                return activeCardContentIsVisible(text, publisher: story.publisherName, title: story.title)
            }
            XCTAssertTrue(cardVisible, "publisher and story actions settle on \(destination)")
            let during = try hostedText(mainHost)
            XCTAssertTrue(during.contains("City Wire"), "publisher remains visible on \(destination): \(during)")
            XCTAssertTrue(during.contains(story.title), "the announced story remains visible on \(destination): \(during)")
            XCTAssertTrue(during.contains("Read story"), "article link remains available on \(destination): \(during)")
            XCTAssertTrue(during.contains("Listen next"), "queue action remains available on \(destination): \(during)")
            XCTAssertTrue(during.contains("Reading this story"), "active speech is identified on \(destination): \(during)")
            XCTAssertTrue(during.filter { !$0.isWhitespace }.contains("Stopreading"),
                          "active speech can be stopped on \(destination): \(during)")
            XCTAssertFalse(during.contains(newer.title), "the card does not drift to a newer unrelated story")
        }

        let (fullWindowHost, fullWindow) = hostedRoot(
            model: model, size: size, presentation: .notes)
        _ = fullWindow
        let fullWindowToastVisible = await WiltedMacHeadless.eventually(
            "the full-window player shows the active headline") {
                guard let text = try? hostedText(fullWindowHost) else { return false }
                return activeCardContentIsVisible(text, publisher: story.publisherName, title: story.title)
            }
        XCTAssertTrue(fullWindowToastVisible)
        let expanded = try hostedText(fullWindowHost)
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
        let afterSpeech = try hostedText(mainHost)
        XCTAssertTrue(afterSpeech.contains(story.title), "the current window keeps the toast until it fades")
        XCTAssertFalse(afterSpeech.contains("Reading this story"), afterSpeech)
        let (reopenedHost, reopenedWindow) = hostedRoot(model: model, size: size)
        _ = reopenedWindow
        let reopened = try hostedText(reopenedHost)
        XCTAssertFalse(reopened.contains(story.title), "a restored spoken story does not reappear as a new toast")
        XCTAssertFalse(reopened.contains("Read story"), reopened)
        XCTAssertFalse(reopened.contains("Listen next"), reopened)
        XCTAssertFalse(reopened.contains(newer.title), reopened)
        XCTAssertEqual(backend.isPlaying, true, "finishing a headline resumes the episode")
    }

    private func hostedRoot(
        model: WiltedMacModel, size: CGSize, presentation: WiltedMacPlayerSection? = nil
    ) -> (NSHostingView<AnyView>, NSWindow) {
        let root = WiltedMacRootView(model: model, initialPlayerPresentation: presentation)
        let host = NSHostingView(rootView: AnyView(
            root.padding(24).frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.white).environment(\.colorScheme, .light)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = WiltedMacHeadless.offscreenWindow(hosting: host)
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func hostedText(_ host: NSHostingView<AnyView>) throws -> String {
        try WiltedMacHeadless.recognizedLines(in: hostedBitmap(host)).map(\.text).joined(separator: " ")
    }

    private func hostedBitmap(_ host: NSHostingView<AnyView>) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let size = host.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func activeCardContentIsVisible(_ text: String, publisher: String, title: String) -> Bool {
        text.contains(publisher)
            && text.contains(title)
            && text.contains("Read story")
            && text.contains("Listen next")
            && text.contains("Reading this story")
            && text.filter { !$0.isWhitespace }.contains("Stopreading")
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
