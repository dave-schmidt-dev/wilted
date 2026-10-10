import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacAddSheetTests: XCTestCase {
    private static let audioFeed = "<rss version=\"2.0\"><channel><title>Followed show</title>"
        + "<item><guid>e1</guid><title>Episode one</title><pubDate>Mon, 29 Sep 2026 12:00:00 GMT</pubDate>"
        + "<enclosure url=\"https://media.example.test/e1.mp3\" type=\"audio/mpeg\" /></item></channel></rss>"
    private static let articleFeed = "<rss version=\"2.0\"><channel><title>Articles only</title>"
        + "<item><guid>a1</guid><title>Post</title><link>https://feeds.example.test/post</link></item></channel></rss>"

    private func bootedModel(_ name: String, feedXML: String = audioFeed) async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(feedXML.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
    }

    nonisolated static func show(_ id: Int, _ title: String, feed: String) -> PodcastCatalogShow {
        PodcastCatalogShow(collectionID: id, title: title, feedURL: URL(string: feed)!, author: "Author \(id)")
    }

    func testFollowedShowIsMarkedAndSubscribeIsNotOffered() async throws {
        let model = try await bootedModel("add-sheet-followed")
        let followedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/followed.xml"))
        model.startPodcastSubscriptionIntake(followedURL)
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.count, 1)

        let results = [
            Self.show(1, "Followed show", feed: followedURL.absoluteString),
            Self.show(2, "Other show", feed: "https://feeds.example.test/other.xml"),
        ]
        let session = model.makeAddSession(search: { _ in results }, linkDebounce: .zero, searchDebounce: .zero)
        session.text = "followed show"
        await session.settle()

        XCTAssertEqual(session.rows.map(\.action), [.following, .subscribe])
        session.subscribe(session.rows[0])
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.count, 1, "a followed show is never subscribed twice")
    }

    func testPastedArticleLinkAddsOneArticle() async throws {
        let model = try await bootedModel("add-sheet-article")
        let gate = model.preparationGateForTesting
        try await gate.admit(sequence: 1)
        let page = try XCTUnwrap(URL(string: "https://blog.example.test/posts/one"))
        let session = model.makeAddSession(classify: { _ in .article }, linkDebounce: .zero, searchDebounce: .zero)
        model.presentAddSheet()

        session.text = page.absoluteString
        await session.settle()
        XCTAssertEqual(session.rows.map(\.action), [.addArticle])

        session.addArticle(session.rows[0])

        XCTAssertEqual(model.preparation?.phase, .preparing)
        XCTAssertFalse(model.isPresentingAddSheet)
        XCTAssertEqual(model.urlDraft, "")
        let store = try XCTUnwrap(model.store)
        let subject = try ItemID.derive(from: page).rawValue
        var ticket: WorkTicket?
        for _ in 0..<50 where ticket == nil {
            ticket = try await store.workTicket(kind: .articlePreparation, subjectID: subject)
            if ticket == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertNotNil(ticket, "exactly this article was requested")
        XCTAssertTrue(model.subscriptions.isEmpty)
        gate.release()
    }

    func testSubscribeToAFeedWithoutAudioFollowsItAsAnArticleFeedAndTheRowReadsFollowing() async throws {
        let model = try await bootedModel("add-sheet-article-feed", feedXML: Self.articleFeed)
        let feed = try XCTUnwrap(URL(string: "https://feeds.example.test/articles.xml"))
        let session = model.makeAddSession(classify: { _ in .podcastFeed }, linkDebounce: .zero, searchDebounce: .zero)
        session.text = feed.absoluteString
        await session.settle()
        XCTAssertEqual(session.rows.map(\.action), [.followArticleFeed])

        session.subscribe(session.rows[0])
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.subscriptions.map(\.feedURL), [feed])
        XCTAssertEqual(model.subscriptions.map(\.title), ["Articles only"])
        XCTAssertEqual(session.rows.map(\.action), [.following])
    }

    func testFeedWithoutAudioOffersFollowAsArticleFeedAndAFeedWithAudioStaysSubscribe() async throws {
        let articles = try await bootedModel("add-sheet-offer-article", feedXML: Self.articleFeed)
        let feed = try XCTUnwrap(URL(string: "https://feeds.example.test/articles.xml"))
        let articleSession = articles.makeAddSession(
            classify: { _ in .podcastFeed }, linkDebounce: .zero, searchDebounce: .zero)
        articleSession.text = feed.absoluteString
        await articleSession.settle()
        XCTAssertEqual(articleSession.rows.map(\.action), [.followArticleFeed])
        XCTAssertEqual(articleSession.rows.first?.feedURL, feed)

        let podcasts = try await bootedModel("add-sheet-offer-podcast")
        let podcastSession = podcasts.makeAddSession(
            classify: { _ in .podcastFeed }, linkDebounce: .zero, searchDebounce: .zero)
        podcastSession.text = feed.absoluteString
        await podcastSession.settle()
        XCTAssertEqual(podcastSession.rows.map(\.action), [.subscribe])
    }

    func testDroppedEpubStartsAConversionAndShowsItsProgress() async throws {
        let model = try await bootedModel("add-sheet-epub")
        let book = wiltedTemporaryDirectory("add-sheet-epub-file").appendingPathComponent("Moby Dick.epub")
        let started = expectation(description: "conversion started")
        let release = AsyncGate()
        let converted = LockedURLs()
        let session = model.makeAddSession(
            convertBook: { url, progress in
                converted.append(url)
                progress(0.4, "Converting chapter 2 of 5")
                started.fulfill()
                await release.wait()
                return ([try ItemID.derive(from: XCTUnwrap(URL(string: "https://x.test/a")))], false)
            },
            importAudio: { _, _ in XCTFail("an EPUB is converted, not imported as audio"); throw CancellationError() },
            linkDebounce: .zero, searchDebounce: .zero)

        session.importBook(from: [book])
        await fulfillment(of: [started], timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(converted.values, [book])
        XCTAssertEqual(
            session.importState, WiltedMacAddSession.ImportState.working(fraction: 0.4, detail: "Converting chapter 2 of 5"))
        XCTAssertTrue(session.isImporting)
        await release.open()
        await session.settleImport()
        XCTAssertEqual(session.importState, WiltedMacAddSession.ImportState.finished("Imported. Find it in your library."))
        XCTAssertFalse(session.isImporting)
    }

    func testCancelStopsARunningImport() async throws {
        let model = try await bootedModel("add-sheet-import-cancel")
        let book = wiltedTemporaryDirectory("add-sheet-cancel-file").appendingPathComponent("Long.pdf")
        let started = expectation(description: "conversion started")
        let session = model.makeAddSession(
            convertBook: { _, _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw BookConversionError.cancelled
            },
            linkDebounce: .zero, searchDebounce: .zero)
        session.importBook(from: [book])
        await fulfillment(of: [started], timeout: 5)

        session.cancelImport()
        XCTAssertEqual(session.importState, WiltedMacAddSession.ImportState.cancelled)
        await session.settleImport()
        XCTAssertEqual(session.importState, WiltedMacAddSession.ImportState.cancelled)
        XCTAssertFalse(session.isImporting)
    }

    func testRefusalShowsTheImportersReasonInTheSheet() async throws {
        let model = try await bootedModel("add-sheet-import-refusal")
        let directory = wiltedTemporaryDirectory("add-sheet-refusal-files")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: notes)
        let session = model.makeAddSession(linkDebounce: .zero, searchDebounce: .zero)

        session.importBook(from: [notes])
        await session.settleImport()
        XCTAssertEqual(session.importState, WiltedMacAddSession.ImportState.refused("notes.txt cannot be read: it is not an audio file"))

        session.importBook(from: [])
        XCTAssertEqual(
            session.importState, WiltedMacAddSession.ImportState.refused("Choose audio files, a folder of audio files, an EPUB or a PDF."))
        session.importBook(from: [directory.appendingPathComponent("a.epub"), directory.appendingPathComponent("b.pdf")])
        XCTAssertEqual(session.importState, WiltedMacAddSession.ImportState.refused("Import one EPUB or PDF at a time, on its own."))
    }

    func testSubscribeThenRowReadsFollowing() async throws {
        let model = try await bootedModel("add-sheet-subscribe")
        let feed = try XCTUnwrap(URL(string: "https://feeds.example.test/new.xml"))
        let session = model.makeAddSession(
            search: { _ in [Self.show(7, "New show", feed: feed.absoluteString)] },
            linkDebounce: .zero, searchDebounce: .zero
        )
        session.text = "new show"
        await session.settle()
        XCTAssertEqual(session.rows.map(\.action), [.subscribe])

        session.subscribe(session.rows[0])
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.subscriptions.count, 1)
        XCTAssertEqual(session.rows.map(\.action), [.following])
    }

    func testAppleShowLinkResolvesToItsFeedAndTitle() async throws {
        let model = try await bootedModel("add-sheet-apple")
        let resolved = Self.show(9, "Apple show", feed: "https://feeds.example.test/apple.xml")
        let session = model.makeAddSession(
            classify: { _ in .podcastCatalogShow(resolved) }, linkDebounce: .zero, searchDebounce: .zero
        )
        session.text = "https://podcasts.apple.com/us/podcast/apple-show/id9"
        await session.settle()

        let row = try XCTUnwrap(session.rows.first)
        XCTAssertEqual(row.title, "Apple show")
        XCTAssertEqual(row.feedURL, resolved.feedURL, "the feed, not the pasted page, is what is followed")
    }

    func testArticlePageAdvertisingAFeedOffersTheFeedAsItsOwnRow() async throws {
        let model = try await bootedModel("add-sheet-advertised")
        let feed = try XCTUnwrap(URL(string: "https://blog.example.test/feed.xml"))
        let session = model.makeAddSession(
            classify: { _ in .articleAdvertisingFeed(feed) }, linkDebounce: .zero, searchDebounce: .zero
        )
        session.text = "https://blog.example.test/posts/one"
        await session.settle()
        XCTAssertEqual(session.rows.map(\.action), [.addArticle, .subscribe])
        XCTAssertEqual(session.rows.last?.feedURL, feed)
    }

    func testUnreachableAndEmptySearchStateTheOutcome() async throws {
        let model = try await bootedModel("add-sheet-errors")
        struct Offline: Error {}
        let session = model.makeAddSession(
            search: { _ in throw Offline() }, linkDebounce: .zero, searchDebounce: .zero
        )
        session.text = "anything"
        await session.settle()
        XCTAssertTrue(session.rows.isEmpty)
        XCTAssertEqual(session.query.state, .unreachable)
        XCTAssertNotNil(session.statusMessage)

        session.text = ""
        XCTAssertEqual(session.query.state, .idle)
    }

    func testViewsOfferNoRetiredEntryPoints() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("WiltedMac/Views")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for retired in ["wilted-add-feed-button", "wilted-add-link"] {
                XCTAssertFalse(source.contains(retired), "\(file.lastPathComponent) still names \(retired)")
            }
        }
    }

    /// ⌘N is the File > New command, which opens the Add sheet; the toolbar button does not duplicate it.
    func testCommandNOpensTheAddSheet() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacApp.swift"), encoding: .utf8)
        let group = try XCTUnwrap(app.range(of: "CommandGroup(replacing: .newItem)"))
        let body = String(app[group.upperBound...].prefix(220))
        XCTAssertTrue(body.contains("model.presentAddSheet()"))
        XCTAssertTrue(body.contains(".keyboardShortcut(\"n\", modifiers: .command)"))
        let rootView = try String(
            contentsOf: root.appendingPathComponent("WiltedMac/Views/WiltedMacRootView.swift"), encoding: .utf8)
        XCTAssertFalse(rootView.contains(".keyboardShortcut(\"n\""))
    }
}

/// A one-shot latch so a test can hold a fake import open.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    var values: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}
