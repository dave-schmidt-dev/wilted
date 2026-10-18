import Foundation
import SwiftUI
import XCTest
import WiltedDomain
@testable import WiltedProducer
@testable import WiltedMac

/// Confirmed deletion on the Mac: Unsubscribe and article Delete each ask
/// first, commit through the store's single-save removal before anything on
/// screen changes, and on a failed save leave the row, selection, player and
/// every durable record exactly as they were, with a Retry.
///
/// Failures are injected at each real persistence stage through the store's
/// task-local `removalStageObserver`; rendered controls cover the row entry point.
@MainActor
final class WiltedMacDeletionSafetyTests: XCTestCase {
    // MARK: Unsubscribe

    func testCancelledUnsubscribeWritesNothingAndKeepsPlaying() async throws {
        let model = try await playingFixtureModel()
        let feed = try fieldNotes(model)
        let quiet = try quietSeasonID(model)
        let before = try await durable(model)
        let rows = model.episodes.map(\.id)
        let flow = WiltedMacRemovalFlow()
        let probe = StageProbe()

        flow.request(.feed(feed))
        XCTAssertEqual(flow.requested, .feed(feed))
        LocalLibraryStore.$removalStageObserver.withValue(probe.observer) { flow.cancel() }
        await model.waitForPodcastOperations()

        XCTAssertNil(flow.requested)
        XCTAssertNil(flow.statusText, "Cancel must not report a removal")
        XCTAssertEqual(probe.stages, [], "Cancel must not reach the store")
        XCTAssertEqual(Set(model.subscriptions.map(\.id)), [feed.id, quiet])
        XCTAssertEqual(model.episodes.map(\.id), rows)
        XCTAssertEqual(model.currentPodcastEpisodeID, rows.first)
        XCTAssertTrue(model.isPlaying)
        let after = try await durable(model)
        XCTAssertEqual(after, before)
        XCTAssertTrue(mediaExists(model))
    }

    func testConfirmedUnsubscribeRemovesOnlyThatFeedAndStopsItsAudio() async throws {
        let model = try await playingFixtureModel()
        let feed = try fieldNotes(model)
        let quiet = try quietSeasonID(model)
        let episodeID = try XCTUnwrap(model.currentPodcastEpisodeID)
        let bystander = model.mediaDirectory.appendingPathComponent("bystander.mp3")
        try Data("bystander".utf8).write(to: bystander)
        let before = try await durable(model)
        let flow = WiltedMacRemovalFlow()
        let probe = StageProbe()

        flow.request(.feed(feed))
        let target = try XCTUnwrap(flow.requested)
        // A second press of the confirm button while the first commits.
        LocalLibraryStore.$removalStageObserver.withValue(probe.observer) {
            flow.confirm(target, model: model)
            XCTAssertEqual(flow.statusText, WiltedMacRemovalFlow.savingCopy)
            flow.confirm(target, model: model)
        }
        await model.waitForPodcastOperations()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(probe.stages, LocalLibraryStageList.unsubscribe, "a duplicate confirm must coalesce")
        XCTAssertEqual(flow.phase, .saved)
        XCTAssertEqual(flow.statusText, "Unsubscribed. Downloaded audio was deleted.")
        XCTAssertEqual(model.subscriptions.map(\.id), [quiet])
        XCTAssertFalse(model.episodes.contains { $0.id == episodeID })
        XCTAssertNil(model.undoableRemoval, "a feed cascade must not offer Undo")

        let after = try await durable(model)
        XCTAssertEqual(after.subscriptions, before.subscriptions.subtracting([feed.id]))
        XCTAssertEqual(after.episodes, before.episodes.subtracting([episodeID]))
        XCTAssertEqual(after.liveArticles, before.liveArticles, "articles are not part of a feed")
        XCTAssertFalse(after.queue.contains(episodeID))
        XCTAssertNotEqual(after.currentQueued, episodeID)
        // W-INV-025: the unsubscribed feed's audio goes with its records, and
        // nothing else in the media directory is touched.
        XCTAssertFalse(mediaExists(model), "the unsubscribed feed's downloaded audio is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path), "other media stays")

        // Stopped after the commit, with nothing left to play or show.
        XCTAssertNil(model.currentPodcastEpisodeID)
        XCTAssertFalse(model.hasCurrentPlayback)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.isNowPlaying)
        XCTAssertNil(model.currentNowPlayingInfo)
        XCTAssertEqual(model.playback?.liveIsPlaying, false)

        // The stop's pause checkpoints after the cascade committed; the store
        // must not re-create the removed episode's position or speed.
        let store = try XCTUnwrap(model.store)
        let removedID = try ItemID(rawValue: episodeID)
        for revision in Self.fixtureRevisions {
            let orphan = try await store.playbackState(for: removedID, revisionID: RevisionID(rawValue: revision))
            XCTAssertNil(orphan, "a late checkpoint re-created the unsubscribed episode's playback record")
        }
        let speed = try await store.playbackSpeed(for: removedID)
        XCTAssertNil(speed)
    }

    func testEveryFailedUnsubscribeStageKeepsRowsPlayerAndRecords() async throws {
        let model = try await playingFixtureModel()
        let feed = try fieldNotes(model)
        let quiet = try quietSeasonID(model)
        let rows = model.episodes.map(\.id)
        let current = model.currentPodcastEpisodeID
        let before = try await durable(model)
        let flow = WiltedMacRemovalFlow()

        for stage in LocalLibraryStageList.unsubscribe {
            let probe = StageProbe(failingAt: stage)
            flow.request(.feed(feed))
            let target = try XCTUnwrap(flow.requested)
            LocalLibraryStore.$removalStageObserver.withValue(probe.observer) { flow.confirm(target, model: model) }
            await model.waitForPodcastOperations()

            XCTAssertEqual(probe.stages.last, stage, "\(stage) was never reached")
            XCTAssertEqual(flow.phase, .failed, "\(stage)")
            XCTAssertEqual(flow.statusText, "Removal save failed. Nothing was removed; retry is available.")
            XCTAssertEqual(Set(model.subscriptions.map(\.id)), [feed.id, quiet], "\(stage)")
            XCTAssertEqual(model.episodes.map(\.id), rows, "\(stage)")
            XCTAssertEqual(model.currentPodcastEpisodeID, current, "\(stage)")
            XCTAssertTrue(model.isPlaying, "a failed removal must not stop the audio (\(stage))")
            XCTAssertNotNil(model.currentNowPlayingInfo, "\(stage)")
            let after = try await durable(model)
            XCTAssertEqual(after, before, "\(stage) committed part of the cascade")
            XCTAssertTrue(mediaExists(model))
        }

        flow.retry(model: model)
        await model.waitForPodcastOperations()
        XCTAssertEqual(flow.phase, .saved, "Retry repeats the same removal")
        XCTAssertEqual(model.subscriptions.map(\.id), [quiet])
        XCTAssertNil(model.currentPodcastEpisodeID)
    }

    /// An episode's own Undo belongs to that episode. Unsubscribing from a
    /// different feed keeps it; unsubscribing from its own feed withdraws it,
    /// because the row it would restore is gone.
    func testEpisodeUndoSurvivesOnlyAnUnrelatedUnsubscribe() async throws {
        let model = try await storeModel(feeds: ["Alpha", "Beta"])
        let alphaEpisode = try XCTUnwrap(model.episodes.first { $0.feedTitle == "Alpha" })
        let alpha = try XCTUnwrap(model.subscriptions.first { $0.title == "Alpha" })
        let beta = try XCTUnwrap(model.subscriptions.first { $0.title == "Beta" })
        model.removeEpisode(alphaEpisode)
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.undoableSkip?.id, alphaEpisode.id)

        let flow = WiltedMacRemovalFlow()
        flow.confirm(.feed(beta), model: model)
        await model.waitForPodcastOperations()
        XCTAssertEqual(flow.phase, .saved)
        XCTAssertEqual(model.undoableSkip?.id, alphaEpisode.id, "Beta's unsubscribe must keep Alpha's Undo")

        let undo = try XCTUnwrap(model.undoableSkip)
        model.undoSkipEpisode(undo)
        await model.waitForPodcastOperations()
        XCTAssertTrue(model.episodes.contains { $0.id == alphaEpisode.id }, "Undo restores offline")

        model.removeEpisode(try XCTUnwrap(model.episodes.first { $0.id == alphaEpisode.id }))
        await model.waitForPodcastOperations()
        flow.confirm(.feed(alpha), model: model)
        await model.waitForPodcastOperations()
        XCTAssertEqual(flow.phase, .saved)
        XCTAssertNil(model.undoableSkip, "Undo must not outlive the feed it would restore into")
        XCTAssertTrue(model.subscriptions.isEmpty)
    }

    // MARK: Article delete

    func testArticlePopoverDeleteRequestsConfirmationWithoutWriting() async throws {
        let model = try await fixtureModel()
        let article = try await openArticle(model)
        let flow = WiltedMacRemovalFlow()
        let row = WiltedMacArticleRow(model: model, article: article, removal: flow)
        let before = try await durable(model)
        for scheme in [ColorScheme.light, .dark] {
            let closed = try WiltedMacHeadless.recognizedText(
                row.environment(\.colorScheme, scheme)
                    .background(WiltedTheme.color(.page, scheme: scheme)), size: CGSize(width: 480, height: 140))
            XCTAssertFalse(closed.contains { $0.contains("Delete") || $0.contains("Retry removal") },
                           "Secondary actions stay inside the closed native popover")
            let text = try WiltedMacHeadless.recognizedText(
                row.articleActions.environment(\.colorScheme, scheme)
                    .background(WiltedTheme.color(.page, scheme: scheme)), size: CGSize(width: 240, height: 140))
            XCTAssertTrue(text.contains { $0.contains("Delete") }, "Delete must render in the native popover: \(scheme), \(text)")
            XCTAssertFalse(text.contains { $0.contains("Retry") }, "Retry only belongs to failed removals: \(scheme), \(text)")
            if !text.contains(where: { $0.contains("Delete") }) || text.contains(where: { $0.contains("Retry") }) {
                try retainArticleActions(row, scheme: scheme, size: CGSize(width: 240, height: 140))
            }
        }
        row.requestRemoval()
        XCTAssertEqual(flow.requested, .article(article))
        XCTAssertNil(flow.phase, "The popover action only requests confirmation")
        let after = try await durable(model)
        XCTAssertEqual(after, before)
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedsComponents.swift")
        let rowSource = try XCTUnwrap(source.components(separatedBy: "struct WiltedMacArticleRow: View {").last)
            .components(separatedBy: "struct WiltedMacLarderArticleAction: View {")[0]
        XCTAssertTrue(rowSource.contains(".frame(width: 32, height: 32)"))
        XCTAssertTrue(rowSource.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(rowSource.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(rowSource.contains(".popover(isPresented: $showsActions"))
        XCTAssertFalse(rowSource.contains("Menu {"))
    }

    func testArticlePopoverOffersRetryAfterFailureAndRepeatsConfirmedRemoval() async throws {
        let model = try await fixtureModel()
        let article = try await openArticle(model)
        let flow = WiltedMacRemovalFlow()
        let row = WiltedMacArticleRow(model: model, article: article, removal: flow)
        row.requestRemoval()
        let target = try XCTUnwrap(flow.requested)
        let probe = StageProbe(failingAt: LocalLibraryStageList.articleRemoval[0])
        LocalLibraryStore.$removalStageObserver.withValue(probe.observer) { flow.confirm(target, model: model) }
        await model.waitForPodcastOperations()
        XCTAssertEqual(flow.phase, .failed)
        for scheme in [ColorScheme.light, .dark] {
            let text = try WiltedMacHeadless.recognizedText(
                row.articleActions.environment(\.colorScheme, scheme)
                    .background(WiltedTheme.color(.page, scheme: scheme)), size: CGSize(width: 260, height: 180))
            XCTAssertTrue(text.contains { $0.contains("Retry removal") }, "\(scheme): \(text)")
            XCTAssertTrue(text.contains { $0.contains("Delete") }, "\(scheme): \(text)")
            if !text.contains(where: { $0.contains("Retry removal") }) || !text.contains(where: { $0.contains("Delete") }) {
                try retainArticleActions(row, scheme: scheme, size: CGSize(width: 260, height: 180))
            }
        }
        row.retryRemoval()
        await model.waitForPodcastOperations()
        XCTAssertEqual(flow.phase, .saved)
        XCTAssertTrue(model.articles.isEmpty)
    }

    private func retainArticleActions(_ row: WiltedMacArticleRow, scheme: ColorScheme, size: CGSize) throws {
        let bitmap = try WiltedMacHeadless.render(row.articleActions.environment(\.colorScheme, scheme)
            .background(WiltedTheme.color(.page, scheme: scheme)), size: size)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "article-actions-\(scheme)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCancelledArticleDeleteWritesNothing() async throws {
        let model = try await fixtureModel()
        let article = try await openArticle(model)
        let before = try await durable(model)
        let flow = WiltedMacRemovalFlow()
        let probe = StageProbe()

        flow.request(.article(article))
        LocalLibraryStore.$removalStageObserver.withValue(probe.observer) { flow.cancel() }
        await model.waitForPodcastOperations()

        XCTAssertEqual(probe.stages, [])
        XCTAssertNil(flow.statusText)
        XCTAssertEqual(model.articles.map(\.id), [article.id])
        XCTAssertEqual(model.selectedArticleID, article.id)
        XCTAssertTrue(model.isNowPlaying)
        let after = try await durable(model)
        XCTAssertEqual(after, before)
    }

    func testConfirmedDeleteOfTheCurrentArticleCommitsOnceAndClearsThePlayer() async throws {
        let model = try await fixtureModel()
        let article = try await openArticle(model)
        let rows = model.episodes.map(\.id)
        let before = try await durable(model)
        let flow = WiltedMacRemovalFlow()
        let probe = StageProbe()

        flow.request(.article(article))
        let target = try XCTUnwrap(flow.requested)
        LocalLibraryStore.$removalStageObserver.withValue(probe.observer) {
            flow.confirm(target, model: model)
            flow.confirm(target, model: model)
        }
        await model.waitForPodcastOperations()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(probe.stages, LocalLibraryStageList.articleRemoval, "a duplicate confirm must coalesce")
        XCTAssertEqual(flow.phase, .saved)
        XCTAssertTrue(model.articles.isEmpty)
        XCTAssertEqual(model.episodes.map(\.id), rows, "episodes are not part of an article")
        let after = try await durable(model)
        XCTAssertEqual(after.deletedArticles, before.deletedArticles.union([article.id]))
        XCTAssertEqual(after.subscriptions, before.subscriptions)
        XCTAssertEqual(after.episodes, before.episodes)
        XCTAssertTrue(mediaExists(model))

        XCTAssertNil(model.selectedArticleID)
        XCTAssertFalse(model.hasCurrentPlayback)
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.currentNowPlayingInfo)
        XCTAssertEqual(model.playback?.liveIsPlaying, false)

        // A late repeat after the commit finds nothing left to remove.
        flow.confirm(target, model: model)
        await model.waitForPodcastOperations()
        XCTAssertEqual(flow.phase, .saved)
        let repeated = try await durable(model)
        XCTAssertEqual(repeated, after, "a repeat must not write anything")
    }

    func testEveryFailedArticleStageKeepsSelectionPlayerAndRecords() async throws {
        let model = try await fixtureModel()
        let article = try await openArticle(model)
        let before = try await durable(model)
        let flow = WiltedMacRemovalFlow()

        for stage in LocalLibraryStageList.articleRemoval {
            let probe = StageProbe(failingAt: stage)
            flow.request(.article(article))
            let target = try XCTUnwrap(flow.requested)
            LocalLibraryStore.$removalStageObserver.withValue(probe.observer) { flow.confirm(target, model: model) }
            await model.waitForPodcastOperations()

            XCTAssertEqual(probe.stages.last, stage, "\(stage) was never reached")
            XCTAssertEqual(flow.phase, .failed, "\(stage)")
            XCTAssertEqual(flow.statusText, WiltedMacRemovalFlow.failedCopy)
            XCTAssertEqual(model.articles.map(\.id), [article.id], "\(stage)")
            XCTAssertEqual(model.selectedArticleID, article.id, "\(stage)")
            XCTAssertTrue(model.isPlaying, "a failed delete must not stop the audio (\(stage))")
            XCTAssertNotNil(model.currentNowPlayingInfo, "\(stage)")
            let after = try await durable(model)
            XCTAssertEqual(after, before, "\(stage) committed the flag or the tombstone alone")
        }

        flow.retry(model: model)
        await model.waitForPodcastOperations()
        XCTAssertEqual(flow.phase, .saved)
        XCTAssertTrue(model.articles.isEmpty)
        XCTAssertNil(model.selectedArticleID)
    }
}

// MARK: - Fixtures

/// The store's own stage orders, so a stage added there is covered here.
private enum LocalLibraryStageList {
    static let unsubscribe = LocalLibraryRemovalStage.unsubscribe
    static let articleRemoval = LocalLibraryRemovalStage.articleRemoval
}

/// Records each removal stage the store reaches and fails the chosen one.
private final class StageProbe: @unchecked Sendable {
    struct InjectedFailure: Error {}
    private let lock = NSLock()
    private var reached: [LocalLibraryRemovalStage] = []
    private let failing: LocalLibraryRemovalStage?

    init(failingAt stage: LocalLibraryRemovalStage? = nil) { failing = stage }

    var stages: [LocalLibraryRemovalStage] { lock.withLock { reached } }

    var observer: @Sendable (LocalLibraryRemovalStage) throws -> Void {
        { [self] stage in
            lock.withLock { reached.append(stage) }
            if stage == failing { throw InjectedFailure() }
        }
    }
}

/// Every durable record a removal could touch, compared whole.
private struct DurableLibrary: Equatable {
    var subscriptions: Set<String>
    var episodes: Set<String>
    var liveArticles: Set<String>
    var deletedArticles: Set<String>
    var queue: [String]
    var currentQueued: String?
    var downloads: Set<String>
    var playback: [String]
    var listening: [String]
}

extension WiltedMacDeletionSafetyTests {
    private static let fixtureRevisions = ["fixture-podcast-revision", "fixture-revision"]

    fileprivate func fixtureModel() async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"],
            stateDirectoryOverride: wiltedTemporaryDirectory("deletion-safety"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        await model.fixtureInstallTask?.value
        await model.fixturePodcastInstallTask?.value
        return model
    }

    /// The fixture with its one episode playing, so playback and listening
    /// records exist to be preserved or removed.
    fileprivate func playingFixtureModel() async throws -> WiltedMacModel {
        let model = try await fixtureModel()
        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.currentPodcastEpisodeID, episode.id)
        XCTAssertTrue(model.isPlaying)
        return model
    }

    /// Opens and starts the fixture article, making it the current item.
    fileprivate func openArticle(_ model: WiltedMacModel) async throws -> WiltedMacArticle {
        let article = try XCTUnwrap(model.articles.first)
        model.openNowPlaying(for: article)
        let deadline = Date().addingTimeInterval(5)
        while !(model.currentArticle?.id == article.id && model.playbackDurationSeconds == 120), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.selectedArticleID, article.id)
        XCTAssertTrue(model.isPlaying)
        return article
    }

    fileprivate func fieldNotes(_ model: WiltedMacModel) throws -> WiltedMacSubscription {
        try XCTUnwrap(model.subscriptions.first { $0.title == "Field Notes" })
    }

    fileprivate func quietSeasonID(_ model: WiltedMacModel) throws -> String {
        try XCTUnwrap(model.subscriptions.first { $0.title == "Quiet Season" }?.id)
    }

    fileprivate func mediaExists(_ model: WiltedMacModel) -> Bool {
        FileManager.default.fileExists(atPath: model.mediaDirectory.appendingPathComponent("fixture-podcast.mp3").path)
    }

    fileprivate func durable(_ model: WiltedMacModel) async throws -> DurableLibrary {
        let store = try XCTUnwrap(model.store)
        let articles = try await store.articles()
        let queue = try await store.podcastQueueState()
        let episodes = try await store.podcastEpisodes()
        var playback: [String] = []
        var listening: [String] = []
        for item in try await store.podcastEpisodes().map(\.itemID) + articles.map(\.itemID) {
            for revision in Self.fixtureRevisions {
                if let state = try await store.playbackState(for: item, revisionID: RevisionID(rawValue: revision)) {
                    // The session, not the position: the checkpoint ticker
                    // moves the position while audio plays.
                    playback.append("\(item.rawValue)|\(revision)|\(state.sessionID)")
                }
            }
            if let state = try await store.listeningState(for: item) {
                listening.append("\(item.rawValue)|\(String(describing: state.completedAt))")
            }
        }
        return try await DurableLibrary(
            subscriptions: Set(store.subscriptions().map(\.feedID.rawValue)),
            episodes: Set(episodes.map(\.itemID.rawValue)),
            liveArticles: Set(articles.filter { !$0.isDeleted }.map(\.itemID.rawValue)),
            deletedArticles: Set(articles.filter(\.isDeleted).map(\.itemID.rawValue)),
            queue: queue.episodeIDs.map(\.rawValue),
            currentQueued: queue.currentEpisodeID?.rawValue,
            downloads: Set(store.downloads().map(\.episodeID.rawValue)),
            playback: playback.sorted(),
            listening: listening.sorted()
        )
    }

    /// A store-backed model with one subscribed feed and one episode per title.
    fileprivate func storeModel(feeds titles: [String]) async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: wiltedTemporaryDirectory("deletion-safety-feeds"),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                for title in titles {
                    let feedURL = URL(string: "https://feeds.example.test/\(title.lowercased()).xml")!
                    let enclosureURL = URL(string: "https://media.example.test/\(title.lowercased()).mp3")!
                    let feedID = try ItemID.derivePodcastFeed(from: feedURL)
                    try await store.save(feed: PodcastFeed(
                        itemID: feedID, canonicalURL: feedURL, title: title, createdAt: created
                    ))
                    try await store.save(episode: PodcastEpisode(
                        itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: title, enclosureURL: enclosureURL),
                        feedID: feedID, feedURL: feedURL, rssGUID: title, title: "\(title) episode",
                        publishedTime: created, enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
                        createdAt: created
                    ))
                    try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                }
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
    }
}
