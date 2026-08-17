import Foundation
import Testing
@testable import WiltedProducer

@Suite("Native article extraction")
struct ArticleExtractionTests {
    @Test func extractsFixtureArticleAndEmitsProgress() async throws {
        let html = try fixture("simple-article.html")
        let url = try #require(URL(string: "https://example.test/articles/simple"))
        let stages = StageRecorder()
        let result = try await NativeArticleExtractor().extract(url, html: html) { stage, _ in stages.append(stage) }
        #expect(result.title == "Garden Notes")
        #expect(result.body.contains("first synthetic paragraph"))
        #expect(stages.values == [.decodingHTML, .readingMetadata, .selectingContent, .finished])
    }

    @Test func rejectsNonHTTPSBeforeLoading() async {
        let loader = CountingLoader()
        do {
            _ = try await NativeArticleExtractor(loader: loader).extract(URL(string: "http://example.test")!)
            Issue.record("Expected invalid URL")
        } catch let error as ArticleExtractionError { #expect(error == .invalidURL) }
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(await loader.count == 0)
    }

    @Test func cancellationIsObservedAtStageBoundary() async throws {
        let task = Task {
            try await NativeArticleExtractor().extract(URL(string: "https://example.test")!, html: try fixture("simple-article.html")) { stage, _ in
                if stage == .decodingHTML { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func controlledUnsupportedFixturesFailClosed() async throws {
        for (name, reason) in [("script-rendered.html", "JavaScript required"), ("consent-wall.html", "consent wall"), ("paywall-headline-only.html", "paywall")] {
            do {
                _ = try await NativeArticleExtractor().extract(URL(string: "https://example.test/\(name)")!, html: try fixture(name))
                Issue.record("Expected unsupported result for \(name)")
            } catch let error as ArticleExtractionError { #expect(error == .unsupported(reason)) }
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appending(path: "Probes/ArticleExtractionProbe/Fixtures/\(name)"))
    }
}

private actor CountingLoader: ArticleLoading {
    private(set) var count = 0
    func load(_ url: URL, maximumBytes: Int, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> Data {
        count += 1
        return Data()
    }
}

private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ArticleExtractionStage] = []
    var values: [ArticleExtractionStage] { lock.withLock { storage } }
    func append(_ value: ArticleExtractionStage) { lock.withLock { storage.append(value) } }
}
