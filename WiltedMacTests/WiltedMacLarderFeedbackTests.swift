import Foundation
import WiltedDomain
@testable import WiltedProducer
import XCTest
@testable import WiltedMac

/// The owner's feedback path in Larder: article preparation keeps its address
/// across the Add sheet, Cancel is observable, Retry re-runs the same article,
/// and queue writes report failure instead of announcing success first.
@MainActor
final class WiltedMacLarderFeedbackTests: XCTestCase {
    private struct FailingWrite: Error {}
    private let feedURL = URL(string: "https://feeds.example.test/larder-feedback.xml")!
    private let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

    private func bootedModel(_ name: String) async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
    }

    /// A model on a real store with episodes queued in `guids` order.
    private func queuedModel(
        _ name: String, guids: [String]
    ) async throws -> (WiltedMacModel, LocalLibraryStore, [String]) {
        let model = try await bootedModel(name)
        let store = try XCTUnwrap(model.store)
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created
        ))
        var ids: [ItemID] = []
        for guid in guids {
            let enclosure = URL(string: "https://media.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
                publishedTime: created, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg",
                createdAt: created
            ))
            ids.append(id)
        }
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: ids))
        await model.reloadLibraryRowsForTesting()
        await model.refreshPodcastQueueState()
        return (model, store, ids.map(\.rawValue))
    }

    private func book(_ id: String, title: String) -> WiltedMacEpisode {
        var book = WiltedMacEpisode(
            id: id, title: title, feedTitle: "Audiobooks", summary: "", artworkURL: nil,
            releasedAt: created.date, durationSeconds: 3_600, playbackSeconds: 0,
            downloadState: .completed, preparationState: .prepared(summary: "Audiobook")
        )
        book.audiobook = WiltedMacAudiobookDetails(
            author: "Author", chapters: [WiltedMacChapter(title: "One", startSeconds: 0)],
            sourceFormat: "audio", volumeIndex: 0, volumeCount: 1
        )
        book.isReadyMediaAvailable = true
        return book
    }

    private actor WriteGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private(set) var writes = 0

        /// Counts the write; the first one waits for `open()`.
        func arrive() async {
            writes += 1
            guard writes == 1, !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    func testInvalidArticleURLKeepsTheSheetOpenWithTheDraft() async throws {
        let model = try await bootedModel("larder-feedback-invalid-url")
        model.presentAddSheet()
        model.urlDraft = "not a link"
        let session = model.makeAddSession(linkDebounce: .zero, searchDebounce: .zero)
        let row = WiltedMacAddSession.Row(
            id: "article", title: "Article", detail: "Article", action: .addArticle,
            feedURL: nil, articleURL: URL(string: "http://example.test/not-secure")!
        )

        session.addArticle(row)

        XCTAssertTrue(model.isPresentingAddSheet, "the sheet stays open until a run starts")
        XCTAssertEqual(model.urlDraft, "not a link", "the owner's text is preserved")
        XCTAssertEqual(session.statusMessage, WiltedMacModel.invalidArticleURLDetail)
        XCTAssertNil(model.preparation, "a refused address starts no preparation")
    }

    func testRetryAfterFailureRerunsTheCanonicalArticleURL() async throws {
        let model = try await bootedModel("larder-feedback-retry")
        let gate = model.preparationGateForTesting
        try await gate.admit(sequence: 1)
        let page = try XCTUnwrap(URL(string: "https://blog.example.test/posts/retry"))
        let session = model.makeAddSession(
            classify: { _ in .article }, linkDebounce: .zero, searchDebounce: .zero
        )
        model.presentAddSheet()
        session.text = page.absoluteString
        await session.settle()
        let row = try XCTUnwrap(session.rows.first)
        XCTAssertEqual(row.action, .addArticle)

        session.addArticle(row)

        XCTAssertFalse(model.isPresentingAddSheet, "the sheet closes only after the run starts")
        XCTAssertEqual(model.urlDraft, "")
        XCTAssertEqual(model.articlePreparationURL, page, "the canonical address survives the sheet")
        XCTAssertTrue(model.preparation?.cancellable ?? false)

        model.preparation = WiltedMacPreparation(
            phase: .failed, detail: "Preparation failed.", fraction: nil, cancellable: false
        )
        model.retryArticlePreparation()

        XCTAssertEqual(model.preparation?.phase, .preparing, "Retry starts the same article again")
        XCTAssertEqual(model.preparation?.detail, WiltedMacModel.articlePreparationQueuedDetail)
        XCTAssertEqual(model.articlePreparationURL, page)
        XCTAssertEqual(model.urlDraft, "")

        model.cancelPreparation()
        gate.release()
        await model.preparationTask?.value
    }

    func testCancelPreparationMovesACancellableRunToCancelling() async throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("larder-feedback-cancel"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.urlDraft = "https://blog.example.test/posts/cancel"
        XCTAssertTrue(model.addArticle())
        XCTAssertTrue(model.canCancelPreparation)

        model.cancelPreparation()

        XCTAssertEqual(model.preparation?.phase, .cancelling)
        await WiltedMacHeadless.eventually("the cancelled fixture run settles") {
            model.preparation?.phase == .cancelled
        }
    }

    func testFailedPreparationCauseComesFromTheTypedCodeNotTheMessage() throws {
        let timeout = try ProducerError(
            code: .timedOut, message: "worker /Users/owner/secret path stalled", retryable: true
        )
        XCTAssertEqual(WiltedMacModel.preparationFailureCause(for: timeout), "Timed out")
        let speech = try ProducerError(code: .speechUnavailable, message: "daemon gone", retryable: true)
        XCTAssertEqual(WiltedMacModel.preparationFailureCause(for: speech), "Speech unavailable")
        XCTAssertEqual(WiltedMacModel.preparationFailureCause(for: FailingWrite()), "Preparation failed",
                       "an unclassified error gets the plain cause, never its description")
    }

    func testReorderWriteFailureIsReportedWithoutASuccessMessage() async throws {
        let (model, store, ids) = try await queuedModel("larder-feedback-reorder", guids: ["a", "b", "c"])
        let durableBefore = try await store.podcastQueueState().episodeIDs.map(\.rawValue)
        model.larderSortWriteHookForTesting = { throw FailingWrite() }

        model.moveLarderEpisode(ids[0], by: 1)
        XCTAssertEqual(model.playbackOperationStatus, "Reordering Larder…")

        await WiltedMacHeadless.eventually("the reorder failure is reported") {
            model.playbackOperationStatus == "The Larder order could not be saved."
        }
        XCTAssertNotEqual(model.playbackOperationStatus, "Reordering Larder…",
                          "the in-flight line never survives as if the move succeeded")
        await WiltedMacHeadless.eventually("the list returns to the durable order") {
            model.podcastQueueIDs == durableBefore
        }
    }

    func testClearGroupWriteFailureReportsHowManyStayAndNeverAnnouncesSuccessFirst() async throws {
        let (model, _, _) = try await queuedModel("larder-feedback-clear", guids: ["a"])
        model.installEpisodeForTesting(book("book-a", title: "Dune"))
        model.installEpisodeForTesting(book("book-b", title: "Emma"))
        model.podcastQueueIDs = ["book-a", "book-b"]
        let gate = WriteGate()
        model.larderSortWriteHookForTesting = {
            await gate.arrive()
            throw FailingWrite()
        }

        model.clearLarderGroup(.playable)

        XCTAssertEqual(model.podcastOperationMessage, "Removing all 2 in Ready from Larder…",
                       "the progress line names the work before any write finishes")
        XCTAssertFalse(model.podcastOperationMessage?.contains("Removed all") ?? false)
        await gate.open()
        await WiltedMacHeadless.eventually("the clear failure is reported") {
            model.podcastOperationMessage?.contains("2 could not be removed") == true
        }
        XCTAssertEqual(
            model.podcastOperationMessage,
            "Removed 0 of 2 in Ready from Larder; 2 could not be removed and stay in Larder."
        )
        XCTAssertFalse(model.podcastOperationMessage?.contains("Removed all 2") ?? false,
                       "a failed clear never announces the whole group removed")
    }

    /// The producer's retry classification reaches the article's work ticket:
    /// a failure it calls not retryable (here a paywall) is recorded terminal,
    /// and one it calls retryable stays retryable.
    func testArticleTicketKeepsTheProducersRetryClassification() async throws {
        let cases: [(String, ArticleExtractionError, PodcastDownloadFailureKind)] = [
            ("walled", .unsupported("paywall"), .terminal),
            ("flaky", .invalidResponse, .retryable),
        ]
        for (name, failure, expected) in cases {
            let model = try await bootedModel("larder-feedback-classify-\(name)")
            let store = try XCTUnwrap(model.store)
            model.coordinator = PreparationCoordinator(
                store: store,
                mediaDirectory: wiltedTemporaryDirectory("larder-feedback-classify-\(name)-media"),
                extraction: { _ in throw failure },
                synthesis: { _ in throw CancellationError() },
                assembly: { _, _, _, _ in throw CancellationError() }
            )
            let page = try XCTUnwrap(URL(string: "https://blog.example.test/posts/\(name)"))
            model.urlDraft = page.absoluteString

            XCTAssertTrue(model.addArticle())
            await model.preparationTask?.value

            XCTAssertEqual(model.preparation?.phase, .failed, name)
            let ticket = try await store.workTicket(
                kind: .articlePreparation, subjectID: try ItemID.derive(from: page).rawValue
            )
            XCTAssertEqual(ticket?.state, .failed, name)
            XCTAssertEqual(ticket?.failureKind, expected.rawValue, name)
        }
    }
}
