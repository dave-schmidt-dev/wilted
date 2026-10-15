import Foundation
import SwiftData
import SwiftUI
import WiltedDomain
@testable import WiltedProducer
@testable import WiltedMac
import XCTest

@MainActor
final class WiltedMacTranscriptLoadingTests: XCTestCase {
    private let panelSize = CGSize(width: 450, height: 350)

    func testHeldTailShowsLoadingAndNoPrepareCTAUntilReleasedNilShowsAbsent() async throws {
        let (model, _, episode) = makePlaybackCommandModel(prepared: true)
        addTeardownBlock { await model.close() }
        await model.fixtureInstallTask?.value
        await model.waitForFixturePodcastInstallForTesting()

        // Ensure no transcript exists for this episode
        let store = try XCTUnwrap(model.store)
        let itemID = try ItemID(rawValue: episode.id)
        let readyValue = try await store.readyRevision(for: itemID)
        let ready = try XCTUnwrap(readyValue)
        let context = ModelContext(store.container)
        let key = "\(itemID.rawValue)|\(ready.revision.revisionID.rawValue)"
        let existing = try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>(
            predicate: #Predicate { $0.id == key }
        ))
        for record in existing { context.delete(record) }
        try context.save()

        let gate = WiltedMacCommandGate()
        gate.arm()
        defer { gate.release() }
        var hookEntered = false
        model.playbackCommands.beforeTranscriptTailForTesting = {
            hookEntered = true
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }

        model.playEpisode(episode)
        guard await WiltedMacHeadless.eventually("Play reaches the held transcript tail", { hookEntered }) else {
            XCTFail("Transcript hook did not run: current=\(model.currentPodcastEpisodeID ?? "none"), error=\(model.playbackError ?? "none"), failure=\(String(describing: model.playbackCommands.failure))")
            gate.release()
            return
        }

        // In held state: model reports loading
        XCTAssertEqual(model.currentTranscript?.availability, .loading)
        XCTAssertNil(model.currentTranscript?.text)

        // View must show loading and NO Prepare-CTA
        let panel = WiltedMacTranscriptPanel(model: model, viewportHeight: 300)
        let heldText = try WiltedMacHeadless.recognizedText(panel, size: panelSize).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(heldText.contains("Loading transcript"), "held state must render loading: \(heldText)")
        XCTAssertFalse(heldText.contains("Prepare this episode"), "held state must NOT show Prepare-CTA: \(heldText)")
        XCTAssertFalse(heldText.contains("Transcript unavailable"), "held state must not claim unavailable: \(heldText)")

        // Release tail: lookup returns nil, confirming absent
        gate.release()
        await model.waitForPlaybackOperationForTesting()
        await model.waitForPlaybackPresentationForTesting()

        XCTAssertEqual(model.currentTranscript?.availability, .absent)
        let releasedText = try WiltedMacHeadless.recognizedText(panel, size: panelSize).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(releasedText.contains("Transcript unavailable. Prepare this episode to add one."), "absent state shows CTA: \(releasedText)")

        await model.close()
    }

    func testHeldTailShowsLoadingUntilReleasedPopulatesTranscript() async throws {
        let (model, _, episode) = makePlaybackCommandModel(prepared: true)
        addTeardownBlock { await model.close() }
        await model.fixtureInstallTask?.value
        await model.waitForFixturePodcastInstallForTesting()

        let store = try XCTUnwrap(model.store)
        let itemID = try ItemID(rawValue: episode.id)
        let readyValue = try await store.readyRevision(for: itemID)
        let ready = try XCTUnwrap(readyValue)
        let expectedText = "The verified transcript text for this episode."
        let transcript = try Transcript(
            itemID: itemID, revisionID: ready.revision.revisionID, availability: .available,
            text: expectedText, updatedAt: Timestamp(Date())
        )
        try await store.save(transcript: transcript)

        let gate = WiltedMacCommandGate()
        gate.arm()
        defer { gate.release() }
        var hookEntered = false
        model.playbackCommands.beforeTranscriptTailForTesting = {
            hookEntered = true
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }

        model.playEpisode(episode)
        guard await WiltedMacHeadless.eventually("Play reaches the held transcript tail", { hookEntered }) else {
            XCTFail("Transcript hook did not run: current=\(model.currentPodcastEpisodeID ?? "none"), error=\(model.playbackError ?? "none"), failure=\(String(describing: model.playbackCommands.failure))")
            gate.release()
            return
        }

        XCTAssertEqual(model.currentTranscript?.availability, .loading)
        let panel = WiltedMacTranscriptPanel(model: model, viewportHeight: 300)
        let heldText = try WiltedMacHeadless.recognizedText(panel, size: panelSize).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(heldText.contains("Loading transcript"))
        XCTAssertFalse(heldText.contains("Prepare this episode"))

        gate.release()
        await model.waitForPlaybackOperationForTesting()
        await model.waitForPlaybackPresentationForTesting()

        XCTAssertEqual(model.currentTranscript?.availability, .available)
        XCTAssertEqual(model.currentTranscript?.text, expectedText)

        let readyText = try WiltedMacHeadless.recognizedText(panel, size: panelSize).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(readyText.contains(expectedText), "ready transcript rendered: \(readyText)")

        await model.close()
    }

    func testPauseDoesNotCancelPresentationTail() async throws {
        let (model, _, episode) = makePlaybackCommandModel(prepared: true)
        addTeardownBlock { await model.close() }
        await model.fixtureInstallTask?.value
        await model.waitForFixturePodcastInstallForTesting()

        let store = try XCTUnwrap(model.store)
        let itemID = try ItemID(rawValue: episode.id)
        let readyValue = try await store.readyRevision(for: itemID)
        let ready = try XCTUnwrap(readyValue)
        let transcript = try Transcript(
            itemID: itemID, revisionID: ready.revision.revisionID, availability: .available,
            text: "Pause preservation words", updatedAt: Timestamp(Date())
        )
        try await store.save(transcript: transcript)

        let gate = WiltedMacCommandGate()
        gate.arm()
        defer { gate.release() }
        var hookEntered = false
        model.playbackCommands.beforeTranscriptTailForTesting = {
            hookEntered = true
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }

        model.playEpisode(episode)
        guard await WiltedMacHeadless.eventually("Play reaches the held transcript tail", { hookEntered }) else {
            XCTFail("Transcript hook did not run: current=\(model.currentPodcastEpisodeID ?? "none"), error=\(model.playbackError ?? "none"), failure=\(String(describing: model.playbackCommands.failure))")
            gate.release()
            return
        }

        // Issue pause while presentation tail is still held
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertFalse(model.isPlaying)
        let presentationID = try XCTUnwrap(model.playbackPresentationTaskID)
        XCTAssertNotNil(model.playbackPresentationTasks[presentationID], "presentation tail must survive Pause")

        let revisionID = try XCTUnwrap(model.playback?.revisionID)
        let owner = try XCTUnwrap(model.playbackPresentationOwner(itemID: itemID, revisionID: revisionID))
        XCTAssertTrue(model.ownsPlaybackPresentation(owner), "Pause keeps presentation owner valid")

        gate.release()
        await model.waitForPlaybackPresentationForTesting()

        XCTAssertEqual(model.currentTranscript?.text, "Pause preservation words")
        XCTAssertEqual(model.currentTranscript?.availability, .available)
        XCTAssertFalse(model.isPlaying)

        await model.close()
    }

    func testOldReadCannotClobberNewSelection() async throws {
        let (model, _, episode1) = makePlaybackCommandModel(prepared: true)
        addTeardownBlock { await model.close() }
        await model.fixtureInstallTask?.value
        await model.waitForFixturePodcastInstallForTesting()

        let store = try XCTUnwrap(model.store)
        let snapshot = try await store.podcastLibrarySnapshot()
        let backing = try XCTUnwrap(snapshot.episodes.first { $0.itemID.rawValue == episode1.id })
        let firstReady = try XCTUnwrap(snapshot.readyRevisions[backing.itemID])
        // The launch fixture draws a completed download but persists only its
        // ready revision. A real reload requires the durable download proof too.
        try await store.save(download: PodcastDownload(episodeID: backing.itemID, status: .completed,
            bytesReceived: firstReady.revision.byteCount, expectedByteCount: firstReady.revision.byteCount,
            localURL: firstReady.mediaURL, contentHash: firstReady.revision.contentHash, updatedAt: backing.createdAt))
        let secondURL = URL(string: "https://fixtures.example.test/media/second-transcript.mp3")!
        let secondID = try ItemID.derivePodcastEpisode(feedURL: backing.feedURL,
            rssGUID: "second-transcript", enclosureURL: secondURL)
        try await WiltedMacModelTests.addReadyEpisode(secondID, guid: "second-transcript",
            feedID: backing.feedID, feedURL: backing.feedURL, enclosureURL: secondURL,
            publishedAt: backing.createdAt.date, directory: model.libraryURL.deletingLastPathComponent(),
            store: store, created: backing.createdAt)
        let secondReadyValue = try await store.readyRevision(for: secondID)
        let secondReady = try XCTUnwrap(secondReadyValue)
        try await store.savePreparationOutcome(PodcastPreparationOutcome(episodeID: secondID,
            revisionID: secondReady.revision.revisionID, policyDigest: "fixture-policy",
            pipelineFingerprint: "fixture-fingerprint", semanticVersion: "fixture-semantic-version",
            producedAt: backing.createdAt, eligibility: .current))
        await model.reloadLibraryRowsForTesting()
        let episode2 = try XCTUnwrap(model.episodes.first { $0.id == secondID.rawValue })
        let reloadedFirst = try XCTUnwrap(model.episodes.first { $0.id == episode1.id })
        XCTAssertEqual(reloadedFirst.downloadState, .completed)
        XCTAssertTrue(reloadedFirst.preparationState.isPrepared)
        XCTAssertTrue(model.canPlayEpisode(reloadedFirst), "First fixture remains genuinely playable after reload")
        XCTAssertTrue(model.canPlayEpisode(episode2), "The second selection has real durable ready proof")

        let item1ID = try ItemID(rawValue: episode1.id)
        let ready1Value = try await store.readyRevision(for: item1ID)
        let ready1 = try XCTUnwrap(ready1Value)
        try await store.save(transcript: Transcript(
            itemID: item1ID, revisionID: ready1.revision.revisionID, availability: .available,
            text: "Episode 1 Text", updatedAt: Timestamp(Date())
        ))

        let item2ID = try ItemID(rawValue: episode2.id)
        let ready2Value = try await store.readyRevision(for: item2ID)
        let ready2 = try XCTUnwrap(ready2Value)
        try await store.save(transcript: Transcript(
            itemID: item2ID, revisionID: ready2.revision.revisionID, availability: .available,
            text: "Episode 2 Text", updatedAt: Timestamp(Date())
        ))

        let gate = WiltedMacCommandGate()
        gate.arm()
        defer { gate.release() }
        var hookEntered = false
        var observedPresentationIDs = Set<UUID>()
        model.playbackPresentationReadBarrierForTesting = { [weak model] in
            hookEntered = true
            if let id = model?.playbackPresentationTaskID { observedPresentationIDs.insert(id) }
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }

        // Start playing episode 1 and hold its read barrier.
        model.playEpisode(episode1)
        guard await WiltedMacHeadless.eventually("First Play reaches the held transcript read", { hookEntered }) else {
            XCTFail("First presentation hook did not run: error=\(model.playbackError ?? "none"), failure=\(String(describing: model.playbackCommands.failure))")
            gate.release()
            return
        }
        let heldPresentationID = try XCTUnwrap(model.playbackPresentationTaskID)
        let heldPresentationTask = try XCTUnwrap(model.playbackPresentationTasks[heldPresentationID])

        // Require the second Play to own a new presentation before joining its tail.
        model.playEpisode(episode2)
        await model.waitForPlaybackOperationForTesting()
        guard await WiltedMacHeadless.eventually("Second Play owns a new transcript presentation", {
            model.currentPodcastEpisodeID == episode2.id
                && observedPresentationIDs.contains(where: { $0 != heldPresentationID })
                && model.playbackPresentationTaskID != heldPresentationID
        }) else {
            XCTFail("Second presentation did not take ownership: current=\(model.currentPodcastEpisodeID ?? "none"), error=\(model.playbackError ?? "none"), failure=\(String(describing: model.playbackCommands.failure))")
            gate.release()
            return
        }
        await model.waitForPlaybackPresentationForTesting()

        XCTAssertEqual(model.currentPodcastEpisodeID, episode2.id)
        XCTAssertEqual(model.currentTranscript?.text, "Episode 2 Text")

        // Release episode 1's old read and join that exact superseded task.
        gate.release()
        await heldPresentationTask.value

        // Old read must not clobber new selection
        XCTAssertEqual(model.currentTranscript?.text, "Episode 2 Text")
        XCTAssertEqual(model.currentPodcastEpisodeID, episode2.id)

        await model.close()
    }

    func testReadFailureShowsHonestErrorAndRetry() async throws {
        let (model, _, episode) = makePlaybackCommandModel(prepared: true)
        addTeardownBlock { await model.close() }
        await model.fixtureInstallTask?.value
        await model.waitForFixturePodcastInstallForTesting()

        let store = try XCTUnwrap(model.store)
        let itemID = try ItemID(rawValue: episode.id)
        let readyValue = try await store.readyRevision(for: itemID)
        let ready = try XCTUnwrap(readyValue)

        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()

        // Insert corrupt transcript record with invalid timing so store.transcript throws
        let context = ModelContext(store.container)
        let record = try LocalLibrarySchemaV7Models.TranscriptRecord(Transcript(
            itemID: itemID, revisionID: ready.revision.revisionID, availability: .available,
            text: "Corrupted timing transcript", languageCode: "en", updatedAt: Timestamp(Date())))
        record.timing = "unknown-corrupt-timing-value"
        let existing = try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
            .filter { $0.id == record.id }
        for value in existing { context.delete(value) }
        try context.save()
        context.insert(record)
        try context.save()

        model.requestPlaybackPresentation(itemID: itemID, includesCuts: true)
        await model.waitForPlaybackPresentationForTesting()

        XCTAssertEqual(model.currentTranscript?.availability, .failed)

        let panel = WiltedMacTranscriptPanel(model: model, viewportHeight: 300)
        let text = try WiltedMacHeadless.recognizedText(panel, size: panelSize).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(text.contains("Could not read the saved transcript."), "shows honest failure: \(text)")
        XCTAssertTrue(text.contains("Retry"), "shows retry button: \(text)")
        XCTAssertFalse(text.contains("Prepare this episode"), "read failure must NOT claim missing: \(text)")

        let repairedText = "The saved transcript is readable after Retry."
        try await store.save(transcript: Transcript(itemID: itemID, revisionID: ready.revision.revisionID,
            availability: .available, text: repairedText, updatedAt: Timestamp(Date())))
        let retryGate = WiltedMacCommandGate()
        retryGate.arm()
        defer { retryGate.release() }
        var retryHookEntered = false
        model.playbackPresentationReadBarrierForTesting = {
            retryHookEntered = true
            await retryGate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }
        model.retryCurrentTranscriptLoad()
        XCTAssertEqual(model.currentTranscript?.availability, .loading, "Retry immediately clears the old read failure")
        guard await WiltedMacHeadless.eventually("Retry reaches the held presentation read", { retryHookEntered }) else {
            XCTFail("Retry never reached the saved transcript: error=\(model.playbackError ?? "none")")
            retryGate.release()
            return
        }
        XCTAssertEqual(model.currentTranscript?.availability, .loading)
        retryGate.release()
        await model.waitForPlaybackPresentationForTesting()
        XCTAssertEqual(model.currentTranscript?.availability, .available)
        XCTAssertEqual(model.currentTranscript?.text, repairedText)
        let repairedPanelText = try WiltedMacHeadless.recognizedText(panel, size: panelSize)
            .joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(repairedPanelText.contains(repairedText))
        XCTAssertFalse(repairedPanelText.contains("Could not read the saved transcript."), "Retry removes the old failed state")

        await model.close()
    }
    func testMissingStoreResolvesOnlyTheCurrentLoadedPresentationAsFailed() async throws {
        let (model, _, episode) = makePlaybackCommandModel(prepared: true)
        addTeardownBlock { await model.close() }
        await model.waitForFixturePodcastInstallForTesting()
        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()
        let itemID = try ItemID(rawValue: episode.id)
        let revisionID = try XCTUnwrap(model.playback?.revisionID)
        let owner = try XCTUnwrap(model.playbackPresentationOwner(itemID: itemID, revisionID: revisionID))
        let savedStore = try XCTUnwrap(model.store)
        defer { model.store = savedStore }
        model.store = nil
        model.currentTranscript = WiltedMacTranscript(availability: .loading, text: nil, presentationOwner: owner)
        await model.readPlaybackPresentation(owner, includesCuts: false)
        XCTAssertEqual(model.currentTranscript?.availability, .failed)
        XCTAssertEqual(model.currentTranscript?.presentationOwner, owner)
        XCTAssertEqual(model.playback?.itemID, itemID)
        XCTAssertFalse(model.isPlaying)

        model.cancelPlaybackPresentation()
        let newerOwner = try XCTUnwrap(model.playbackPresentationOwner(itemID: itemID, revisionID: revisionID))
        model.currentTranscript = WiltedMacTranscript(availability: .loading, text: nil, presentationOwner: newerOwner)
        await model.readPlaybackPresentation(owner, includesCuts: false)
        XCTAssertEqual(model.currentTranscript?.availability, .loading, "A stale read cannot resolve a newer owner's state")
        XCTAssertEqual(model.currentTranscript?.presentationOwner, newerOwner)
    }

}
