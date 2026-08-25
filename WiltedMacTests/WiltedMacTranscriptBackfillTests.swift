import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The producer's transcript backfill reports failures in the player itself, so
/// whatever it writes is user-facing copy. It previously wrote
/// `String(describing: error)`, which renders `Error Domain=NSURLErrorDomain
/// Code=-1009 ...` into the window.
@MainActor
final class WiltedMacTranscriptBackfillTests: XCTestCase {
    func testExtractionFailuresReportTheirOwnSentence() {
        XCTAssertEqual(
            WiltedMacModel.backfillFailureMessage(ArticleExtractionError.invalidURL),
            "Enter a complete HTTPS article URL."
        )
        XCTAssertEqual(
            WiltedMacModel.backfillFailureMessage(ArticleExtractionError.emptyContent),
            "Wilted could not find readable article text."
        )
    }

    func testTransportAndUnknownFailuresStayReadable() {
        // A synthesized URLError has no `NSLocalizedDescriptionKey`, so rendering
        // its `localizedDescription` would print `(NSURLErrorDomain error -1009.)`.
        // Matching on the code is what keeps this a sentence.
        let offline = WiltedMacModel.backfillFailureMessage(URLError(.notConnectedToInternet))
        XCTAssertEqual(offline, "Wilted could not reach the article. Check your connection and try again.")
        XCTAssertEqual(
            WiltedMacModel.backfillFailureMessage(URLError(.timedOut)),
            "The article server did not respond in time. Try again."
        )
        for message in [offline, WiltedMacModel.backfillFailureMessage(URLError(.cannotFindHost))] {
            XCTAssertFalse(message.contains("NSURLErrorDomain"), message)
            XCTAssertFalse(message.contains("Error Domain"), message)
        }

        struct Opaque: Error { let payload = "Error Domain=Wilted Code=-1" }
        let unknown = WiltedMacModel.backfillFailureMessage(Opaque())
        XCTAssertEqual(unknown, "Could not fetch the article text. Check the link and try again.")
        XCTAssertFalse(unknown.contains("Opaque"))
        XCTAssertFalse(unknown.contains("payload"))
    }
}

/// The library's only destructive path. `removeArticle` marks the stored article
/// deleted and records a tombstone; the row must actually leave the list.
@MainActor
final class WiltedMacArticleRemovalTests: XCTestCase {
    func testRemovingAnArticleClearsItFromTheLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-removal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: directory
        )
        try await poll("fixture article never reached the library") { !model.articles.isEmpty }
        let article = try XCTUnwrap(model.articles.first)

        model.removeArticle(article)
        try await poll("removeArticle left the article in the library") { model.articles.isEmpty }
    }

    private func poll(
        _ message: String,
        timeout: TimeInterval = 5,
        until condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail(message)
    }
}
