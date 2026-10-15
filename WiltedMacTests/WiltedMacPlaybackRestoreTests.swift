import Foundation
import SwiftData
import SwiftUI
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer
@testable import WiltedMac
import XCTest

@MainActor
final class WiltedMacPlaybackRestoreTests: XCTestCase {
    private let feedURL = URL(string: "https://podcasts.example.test/restore-test.xml")!
    private let timestamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

    private func seedStoreForRestore(
        in directory: URL,
        episodeTitle: String = "Restored Episode Title",
        savedPosition: Double = 145.0
    ) async throws -> (ItemID, LocalLibraryStore) {
        let storeURL = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: storeURL)
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Restore Show", createdAt: timestamp))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: timestamp))

        let enclosure = URL(string: "https://media.example.test/restore.mp3")!
        let itemID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "restore-guid", enclosureURL: enclosure)
        let episode = try PodcastEpisode(
            itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: "restore-guid", title: episodeTitle,
            publishedTime: timestamp, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: timestamp
        )
        try await store.save(episode: episode)

        let revisionID = try RevisionID(rawValue: "rev-restore")
        let mediaURL = directory.appendingPathComponent("restore.m4a")
        let audioData = Data(repeating: 0x42, count: 512)
        try audioData.write(to: mediaURL)
        let hash = "sha256:" + String(repeating: "b", count: 64)

        let revision = try AudioRevision(
            itemID: itemID, revisionID: revisionID, durationSeconds: 600, byteCount: 512,
            contentHash: hash, mediaType: "audio/mp4", createdAt: timestamp, schemaVersion: 1
        )
        try await store.saveReadyRevision(revision, mediaURL: mediaURL)

        let download = try PodcastDownload(
            episodeID: itemID, status: .completed, bytesReceived: 512,
            expectedByteCount: 512, localURL: mediaURL, contentHash: hash, updatedAt: timestamp
        )
        try await store.save(download: download)

        let outcome = PodcastPreparationOutcome(
            episodeID: itemID, revisionID: revisionID, policyDigest: "digest",
            pipelineFingerprint: "fingerprint", semanticVersion: "1.0.0", producedAt: timestamp,
            eligibility: .current
        )
        try await store.savePreparationOutcome(outcome)

        let playbackState = try PlaybackState(
            itemID: itemID, revisionID: revisionID, sessionID: "saved-restore-session", sequence: 5,
            positionSeconds: savedPosition, durationSeconds: 600, completed: false, intent: .progress,
            deviceID: "mac-test", updatedAt: timestamp
        )
        _ = try await store.save(playback: playbackState)

        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [itemID], currentEpisodeID: itemID))
        return (itemID, store)
    }

    func testBootRestoresDurableQueueCurrentWithSavedPausedPositionWithoutAutoplay() async throws {
        let dir = wiltedTemporaryDirectory("restore-boot")
        let expectedTitle = "Restored Episode Title"
        let expectedPosition: Double = 145.0
        let (itemID, store) = try await seedStoreForRestore(in: dir, episodeTitle: expectedTitle, savedPosition: expectedPosition)

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: dir,
            storeBootstrap: { _ in store },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        addTeardownBlock { await model.close() }
        let backend = WiltedMacScriptedBackend()
        defer { backend.onLoad = nil }
        var preReturnObserved = false
        backend.onLoad = {
            preReturnObserved = true
            XCTAssertEqual(backend.currentTime, 0)
            XCTAssertFalse(backend.isPlaying)
        }

        model.startupStepObserverForTesting = { [weak model] step in
            if step == .restoringPlayback {
                model?.installPlaybackBackendForTesting(backend)
            }
        }

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertTrue(preReturnObserved, "ScriptedBackend.onLoad must execute during restore")
        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.currentPodcastEpisodeID, itemID.rawValue)
        XCTAssertEqual(try XCTUnwrap(model.currentEpisode).title, expectedTitle)
        XCTAssertTrue(model.isNowPlaying)
        XCTAssertTrue(model.hasCurrentPlayback)
        XCTAssertEqual(model.playbackPositionSeconds, expectedPosition, "saved position restored before any Play")
        XCTAssertFalse(model.isPlaying, "never autoplay on launch")
        XCTAssertEqual(backend.playCount, 0, "never autoplay on launch")

        // Render Now Playing pane and Compact Player to verify title and controls
        let pane = WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))
        let paneLines = try WiltedMacHeadless.recognizedText(pane, size: CGSize(width: 450, height: 400)).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(paneLines.contains(expectedTitle), "Now Playing pane displays restored episode: \(paneLines)")

        let rail = WiltedMacCompactPlayer(model: model, presentation: .constant(nil), focusRequest: nil)
        let railLines = try WiltedMacHeadless.recognizedText(rail, size: CGSize(width: 800, height: 100)).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(railLines.contains(expectedTitle), "player rail displays restored episode: \(railLines)")

        await model.close()
    }

    func testRootDisplaysStartupLoadingDuringBootUntilReady() async throws {
        let dir = wiltedTemporaryDirectory("restore-loading")
        let (itemID, store) = try await seedStoreForRestore(in: dir)

        let gate = WiltedMacCommandGate()
        gate.arm()
        defer { gate.release() }
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: dir,
            storeBootstrap: { _ in
                await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        addTeardownBlock { await model.close() }
        let backend = WiltedMacScriptedBackend()
        defer { backend.onLoad = nil }
        model.startupStepObserverForTesting = { [weak model] step in
            if step == .restoringPlayback { model?.installPlaybackBackendForTesting(backend) }
        }

        model.startStoreBootstrap()
        await gate.waitUntilHeld()

        // During boot: root displays startupLoading
        guard case .loading = model.startupState else {
            XCTFail("StartupState must be loading during boot")
            gate.release()
            await model.close()
            return
        }

        let root = WiltedMacRootView(model: model)
        let loadingLines = try WiltedMacHeadless.recognizedText(root, size: CGSize(width: 800, height: 600)).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertFalse(loadingLines.contains("Restored Episode Title"), "player controls not shown while startupLoading: \(loadingLines)")

        gate.release()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.currentPodcastEpisodeID, itemID.rawValue)

        let readyLines = try WiltedMacHeadless.recognizedText(root, size: CGSize(width: 800, height: 600)).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(readyLines.contains("Restored Episode Title"), "player appears once ready: \(readyLines)")

        await model.close()
    }

    func testRestorePlaybackFailureProjectsIdentityTruthfully() async throws {
        let dir = wiltedTemporaryDirectory("restore-failure")
        let (failedID, store) = try await seedStoreForRestore(in: dir)

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: dir,
            storeBootstrap: { _ in store },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        addTeardownBlock { await model.close() }
        let backend = WiltedMacScriptedBackend()
        defer { backend.onLoad = nil }
        backend.failNextLoads = 1

        model.startupStepObserverForTesting = { [weak model] step in
            if step == .restoringPlayback {
                model?.installPlaybackBackendForTesting(backend)
            }
        }

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertFalse(model.isRestoringPodcastPlayback)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(backend.playCount, 0)
        XCTAssertEqual(model.currentPodcastEpisodeID, failedID.rawValue, "The fault names the attempted saved episode")
        XCTAssertEqual(try XCTUnwrap(model.currentEpisode).title, "Restored Episode Title")
        XCTAssertEqual(model.playbackError, "This episode's saved audio could not be opened.")
        XCTAssertNil(model.playback?.itemID, "A backend load failure cannot claim loaded audio")
        XCTAssertNil(model.playback?.revisionID)

        await model.close()
    }

    func testUserSelectionDuringRestoreSupersedesRestore() async throws {
        let dir = wiltedTemporaryDirectory("restore-supersede")
        let (episodeAID, store) = try await seedStoreForRestore(in: dir, episodeTitle: "Episode A")

        // Seed a second episode B
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosureB = URL(string: "https://media.example.test/b.mp3")!
        let episodeBID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "b-guid", enclosureURL: enclosureB)
        try await store.save(episode: PodcastEpisode(
            itemID: episodeBID, feedID: feedID, feedURL: feedURL, rssGUID: "b-guid", title: "Episode B",
            publishedTime: timestamp, enclosureURL: enclosureB, enclosureMediaType: "audio/mpeg", createdAt: timestamp
        ))
        let revB = try RevisionID(rawValue: "rev-b")
        let fileB = dir.appendingPathComponent("b.m4a")
        try Data(repeating: 0x43, count: 256).write(to: fileB)
        let hashB = "sha256:" + String(repeating: "c", count: 64)
        try await store.saveReadyRevision(AudioRevision(
            itemID: episodeBID, revisionID: revB, durationSeconds: 300, byteCount: 256,
            contentHash: hashB, mediaType: "audio/mp4", createdAt: timestamp, schemaVersion: 1
        ), mediaURL: fileB)
        try await store.save(download: PodcastDownload(
            episodeID: episodeBID, status: .completed, bytesReceived: 256,
            expectedByteCount: 256, localURL: fileB, contentHash: hashB, updatedAt: timestamp
        ))
        try await store.savePreparationOutcome(PodcastPreparationOutcome(
            episodeID: episodeBID, revisionID: revB, policyDigest: "d", pipelineFingerprint: "f",
            semanticVersion: "1.0", producedAt: timestamp, eligibility: .current
        ))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: dir,
            storeBootstrap: { _ in store },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        addTeardownBlock { await model.close() }
        let backend = WiltedMacScriptedBackend()
        defer { backend.onLoad = nil }
        var selectedB = false
        backend.onLoad = { [weak model] in
            guard !selectedB, let model,
                  let episodeB = model.episodes.first(where: { $0.id == episodeBID.rawValue }) else { return }
            selectedB = true
            model.playEpisode(episodeB)
        }

        model.startupStepObserverForTesting = { [weak model] step in
            if step == .restoringPlayback {
                model?.installPlaybackBackendForTesting(backend)
            }
        }

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(selectedB, "Restore must be interrupted by a real selection")
        XCTAssertEqual(model.currentPodcastEpisodeID, episodeBID.rawValue, "The actual user selection wins restore")
        XCTAssertEqual(model.playback?.itemID, episodeBID)
        XCTAssertEqual(try XCTUnwrap(model.currentEpisode).title, "Episode B")
        XCTAssertNotEqual(model.currentPodcastEpisodeID, episodeAID.rawValue, "superseded restore must not overwrite user selection")

        await model.close()
    }

    func testUserPauseDuringRestoreSupersedesRestore() async throws {
        let dir = wiltedTemporaryDirectory("restore-pause")
        let (episodeID, store) = try await seedStoreForRestore(in: dir)

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: dir,
            storeBootstrap: { _ in store },
            preferences: WiltedMacTestPreferences.ephemeral()
        )

        addTeardownBlock { await model.close() }
        let backend = WiltedMacScriptedBackend()
        defer { backend.onLoad = nil }
        backend.onLoad = { [weak model] in
            model?.pausePlayback()
        }

        model.startupStepObserverForTesting = { [weak model] step in
            if step == .restoringPlayback {
                model?.installPlaybackBackendForTesting(backend)
            }
        }

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(backend.playCount, 0)
        XCTAssertEqual(model.currentPodcastEpisodeID, episodeID.rawValue)

        await model.close()
    }
}
