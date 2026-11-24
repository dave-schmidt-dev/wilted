import AppKit
import SwiftUI
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacListenNextCardTests: XCTestCase {
    func testCardKeepsReadStoryBesideListenNext() throws {
        let story = try story()
        let view = card(story: story)

        let rendered = try WiltedMacHeadless.recognizedText(
            view, size: CGSize(width: 900, height: 320)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("Council approves night service"), rendered)
        XCTAssertTrue(rendered.contains("Listen next"), rendered)
        XCTAssertTrue(rendered.contains("Read story"), rendered)
    }

    func testRecentListQueuesTheStoryOnItsOwnCard() async throws {
        let story = try story()
        let model = try await makeModel(story: story, voice: .caseyKasem)
        let disclosure = WiltedMacHeadlineHistoryDisclosure(
            model: model, isExpanded: .constant(true), chooseReadingVoice: model.openReadingVoiceSettings)
        let list = disclosure.headlinesList
        let rendered = try WiltedMacHeadless.recognizedText(
            list, size: CGSize(width: 1_000, height: 700)).joined(separator: " ")
        let displayedStory = try XCTUnwrap(list.recent.first)
        let rowCard = list.storyCard(for: displayedStory)

        XCTAssertTrue(rendered.contains("Recent headlines"), rendered)
        XCTAssertTrue(rendered.contains(displayedStory.title), rendered)
        XCTAssertTrue(rendered.contains("Listen next"), rendered)
        XCTAssertTrue(rendered.contains("Read story"), rendered)

        // Run the row card's production Button action, bound to this exact Recent story.
        rowCard.retry()
        let requests = try await waitForRequests(model, count: 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.story, displayedStory)
        XCTAssertEqual(request.storyID, displayedStory.id)
        XCTAssertEqual(request.requesterDeviceID, model.libraryDeviceID())

        var queuedCard = list.storyCard(for: displayedStory)
        queuedCard.listenNextRequest = request
        queuedCard.cancel(request.requestID)
        let cancelled = try await waitForStatus(model, requestID: request.requestID, status: .cancelled)
        XCTAssertEqual(cancelled.requestID, request.requestID)
        XCTAssertEqual(cancelled.storyID, displayedStory.id)
    }

    func testPreparingAndReadyRequestsShowProgressUndoAndQueueState() throws {
        let story = try story()
        let preparing = card(story: story, request: try request(story: story, status: .preparing))
        let preparingText = try WiltedMacHeadless.recognizedText(
            preparing, size: CGSize(width: 900, height: 320)).joined(separator: " ")
        XCTAssertTrue(preparingText.contains("Preparing story audio"), preparingText)
        XCTAssertTrue(preparingText.contains("Undo queue"), preparingText)

        let ready = card(story: story, request: try request(story: story, status: .ready))
        let readyText = try WiltedMacHeadless.recognizedText(
            ready, size: CGSize(width: 900, height: 320)).joined(separator: " ")
        XCTAssertTrue(readyText.contains("Queued after current episode"), readyText)
        XCTAssertTrue(readyText.contains("Undo queue"), readyText)
    }

    func testFailedRequestShowsSafeRetryAndVoiceAction() throws {
        let story = try story()
        let failed = card(
            story: story,
            request: try request(story: story, status: .failed, failure: .missingVoice))

        let rendered = try WiltedMacHeadless.recognizedText(
            failed, size: CGSize(width: 900, height: 320)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("Choose a voice to listen to stories"), rendered)
        XCTAssertTrue(rendered.contains("Retry"), rendered)
        XCTAssertTrue(rendered.contains("Choose voice"), rendered)
    }

    func testMissingVoiceWithoutSavedRequestOffersVoiceSettingsAction() async throws {
        let story = try story()
        let model = try await makeModel(story: story, installCoordinator: false)
        let player = WiltedMacPlayerHeadlineCard(
            model: model, story: story, isSpeakingHeadline: false, stopReading: {})
        await player.performListenNext()
        XCTAssertEqual(model.listenNextActionMessage, WiltedHeadlineStoryCard.listenNextFailureMessage(.missingVoice))

        let view = card(
            story: story,
            actionMessage: model.listenNextActionMessage,
            requestListenNext: player.performListenNext,
            chooseReadingVoice: model.openReadingVoiceSettings)
        let rendered = try WiltedMacHeadless.recognizedText(
            view, size: CGSize(width: 900, height: 360)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("Choose a voice to listen to stories"), rendered)
        XCTAssertTrue(rendered.contains("Choose voice"), rendered)
        view.chooseVoice()
        XCTAssertEqual(model.selectedNavigation, .settings)
        XCTAssertEqual(model.settingsSection, .reports)
    }

    func testMissingVoiceFeedbackOpensTheReportsVoiceControls() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        addTeardownBlock { await model.close() }
        do {
            _ = try await model.listenNextRequest(story: story(), anchorID: nil)
            XCTFail("A story request without a selected voice should stop with visible guidance.")
        } catch {
            XCTAssertEqual(
                model.listenNextActionMessage,
                WiltedHeadlineStoryCard.listenNextFailureMessage(.missingVoice))
        }

        let reports = WiltedMacReportsCard(model: model, location: model.bulletinHub.location)
        let rendered = try WiltedMacHeadless.recognizedText(
            reports, size: CGSize(width: 1_000, height: 1_200)).joined(separator: " ")

        XCTAssertTrue(rendered.contains("Story voice"), rendered)
        XCTAssertTrue(rendered.contains("Choose a voice"), rendered)
    }

    func testListenNextButtonQueuesOnceAndUndoCancelsTheVisibleRequest() async throws {
        let story = try story()
        let model = try await makeModel(story: story, voice: .caseyKasem)
        let player = WiltedMacPlayerHeadlineCard(
            model: model, story: story, isSpeakingHeadline: false, stopReading: {})
        let listenNextCard = player.storyCard
        let rendered = try WiltedMacHeadless.recognizedText(
            listenNextCard, size: CGSize(width: 900, height: 360)).joined(separator: " ")
        XCTAssertTrue(rendered.contains("Council approves night service"), rendered)
        XCTAssertTrue(rendered.contains("Listen next"), rendered)
        XCTAssertTrue(rendered.contains("Read story"), rendered)

        // The SwiftUI button calls this production card action, which is bound to the player's model command.
        listenNextCard.retry()
        let requests = try await waitForRequests(model, count: 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.story, story)
        XCTAssertEqual(request.storyID, story.id)
        XCTAssertEqual(request.anchorID, model.playback?.itemID)
        XCTAssertEqual(request.status, .preparing)

        var queuedCard = player.storyCard
        queuedCard.listenNextRequest = request
        let queuedText = try WiltedMacHeadless.recognizedText(
            queuedCard, size: CGSize(width: 900, height: 360)).joined(separator: " ")
        XCTAssertTrue(queuedText.contains("Preparing story audio"), queuedText)
        XCTAssertTrue(queuedText.contains("Undo queue"), queuedText)

        // This is the exact cancel action used by Undo; retain the visible request ID through cancellation.
        queuedCard.cancel(request.requestID)
        let cancelled = try await waitForStatus(model, requestID: request.requestID, status: .cancelled)
        XCTAssertEqual(cancelled.requestID, request.requestID)
        XCTAssertEqual(cancelled.storyID, story.id)
    }

    func testRetryAndChooseVoiceButtonsRunTheirActions() async throws {
        let story = try story()
        let model = try await makeModel(story: story)
        let player = WiltedMacPlayerHeadlineCard(
            model: model, story: story, isSpeakingHeadline: false, stopReading: {})
        let failedRequest = try request(story: story, status: .failed, failure: .missingVoice)
        var failedCard = player.storyCard
        failedCard.listenNextRequest = failedRequest
        let rendered = try WiltedMacHeadless.recognizedText(
            failedCard, size: CGSize(width: 900, height: 360)).joined(separator: " ")
        XCTAssertTrue(rendered.contains("Retry"), rendered)
        XCTAssertTrue(rendered.contains("Choose voice"), rendered)

        // The button action is bound to the model's real settings route.
        failedCard.chooseVoice()
        XCTAssertEqual(model.selectedNavigation, .settings)
        XCTAssertEqual(model.settingsSection, .reports)

        model.selectReadingVoice(ApprovedReadingVoiceID.caseyKasem.rawValue)
        failedCard.retry()
        let requests = try await waitForRequests(model, count: 1)
        let retriedRequest = try XCTUnwrap(requests.first)
        XCTAssertNotEqual(retriedRequest.requestID, failedRequest.requestID)
        XCTAssertEqual(retriedRequest.story, story)
        XCTAssertEqual(retriedRequest.storyID, story.id)
        XCTAssertEqual(retriedRequest.status, .preparing)

        failedCard.cancel(retriedRequest.requestID)
        let cancelled = try await waitForStatus(model, requestID: retriedRequest.requestID, status: .cancelled)
        XCTAssertEqual(cancelled.requestID, retriedRequest.requestID)
    }

    private func card(
        story: LibraryHeadlineStory,
        request: LibraryListenNextRequestSnapshot? = nil,
        actionMessage: String? = nil,
        requestListenNext: @escaping @MainActor () async -> Void = {},
        cancelListenNext: @escaping @MainActor (String) async -> Void = { _ in },
        chooseReadingVoice: @escaping () -> Void = {}
    ) -> WiltedHeadlineStoryCard {
        WiltedHeadlineStoryCard(
            story: story, isMuted: false, actionInProgress: false,
            setSaved: { _ in }, setMuted: { _ in },
            listenNextRequest: request,
            listenNextActionMessage: actionMessage,
            requestListenNext: requestListenNext,
            cancelListenNext: cancelListenNext,
            chooseReadingVoice: chooseReadingVoice)
    }

    private func makeModel(
        story: LibraryHeadlineStory,
        voice: ApprovedReadingVoiceID? = nil,
        installCoordinator: Bool = true
    ) async throws -> WiltedMacModel {
        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready"], suffix: "listen-next-card-\(UUID().uuidString)")
        if let voice { model.selectReadingVoice(voice.rawValue) }
        try model.headlineCatalogStore.mergeRecent([story], at: story.lastSeenAt)
        model.headlineCatalogState.refresh(at: story.lastSeenAt)

        let coordinator: WiltedMacListenNextCoordinator?
        if installCoordinator {
            let audioDirectory = model.libraryURL.deletingLastPathComponent()
                .appendingPathComponent("listen-next-card-audio", isDirectory: true)
            let installed = try WiltedMacListenNextCoordinator(
                model: model,
                transport: nil,
                directory: audioDirectory,
                deviceID: model.libraryDeviceID(),
                store: model.listenNextRequestStore,
                narrate: { _, _, _ in
                    try await Task.sleep(for: .seconds(60))
                    throw ArticleNarrationError.cancelled
                })
            model.installListenNextCoordinatorForTesting(installed)
            coordinator = installed
        } else {
            coordinator = nil
        }

        addTeardownBlock {
            await coordinator?.invalidate()
            await model.close()
        }
        return model
    }

    private func waitForRequests(
        _ model: WiltedMacModel, count: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [LibraryListenNextRequestSnapshot] {
        for _ in 0..<300 {
            let requests = await model.listenNextSnapshots()
            if requests.count >= count { return requests }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(count) Listen next request(s).", file: file, line: line)
        return await model.listenNextSnapshots()
    }

    private func waitForStatus(
        _ model: WiltedMacModel,
        requestID: String,
        status: LibraryListenNextRequestSnapshot.Status,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> LibraryListenNextRequestSnapshot {
        for _ in 0..<300 {
            let requests = await model.listenNextSnapshots()
            if let request = requests.first(where: { $0.requestID == requestID }), request.status == status {
                return request
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Listen next request \(requestID) to become \(status).", file: file, line: line)
        let requests = await model.listenNextSnapshots()
        return try XCTUnwrap(requests.first { $0.requestID == requestID }, file: file, line: line)
    }

    private func story() throws -> LibraryHeadlineStory {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return try LibraryHeadlineStory(
            id: "listen-next-story", title: "Council approves night service", publisherID: "wire",
            publisherName: "City Wire", link: URL(string: "https://wire.example.test/story"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
    }

    private func request(
        story: LibraryHeadlineStory,
        status: LibraryListenNextRequestSnapshot.Status,
        failure: LibraryListenNextStatus.Failure? = nil,
        id: String = "listen-next-request"
    ) throws -> LibraryListenNextRequestSnapshot {
        let voice = ApprovedReadingVoiceID.caseyKasem
        let voiceRevision = ArticleNarrationCoordinator.voiceRevision(for: voice)
        let audioOffer = status == .ready
            ? try LibraryStoryAudioOffer(
                requestID: id, storyID: story.id, requesterDeviceID: "synthetic-mac",
                voiceID: voice.rawValue, voiceRevision: voiceRevision,
                audioRevision: RevisionID(rawValue: "audio-r1"),
                contentHash: "sha256:" + String(repeating: "a", count: 64),
                byteCount: 1, mediaType: "audio/mp4", durationSeconds: 1)
            : nil
        return try LibraryListenNextRequestSnapshot(
            requestID: id, story: story, requesterDeviceID: "synthetic-mac", ownerToken: "synthetic-owner",
            operationGeneration: 1, anchorID: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_100),
            status: status, audioOffer: audioOffer,
            voiceID: status == .ready ? voice.rawValue : nil,
            voiceRevision: status == .ready ? voiceRevision : nil,
            failure: failure)
    }
}
