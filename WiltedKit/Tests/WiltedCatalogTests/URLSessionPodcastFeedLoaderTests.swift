import Foundation
import Testing
@testable import WiltedCatalog

@Suite("URLSession podcast feed loader")
struct URLSessionPodcastFeedLoaderTests {
    @Test func URLSessionLoaderEnforcesDeclaredAndStreamedLimits() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedURLProtocol.self]
        let loader = URLSessionPodcastFeedLoader(configuration: configuration)
        await expect(.responseTooLarge) {
            try await loader.load(URL(string: "https://podcasts.example.test/feed.xml?case=header")!, maximumBytes: 1)
        }
        await expect(.responseTooLarge) {
            try await loader.load(URL(string: "https://podcasts.example.test/feed.xml?case=stream")!, maximumBytes: 1)
        }
    }

    @Test func URLSessionLoaderAllowsHTTPSRedirectsAndRejectsDowngrades() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedURLProtocol.self]
        let loader = URLSessionPodcastFeedLoader(configuration: configuration)
        let response = try await loader.load(URL(string: "https://podcasts.example.test/feed.xml?case=redirect")!, maximumBytes: 1_024)
        #expect(response.url.query == "case=success")
        await expect(.redirectDowngrade) {
            try await loader.load(URL(string: "https://podcasts.example.test/feed.xml?case=downgrade")!, maximumBytes: 1_024)
        }
    }

    @Test func URLSessionLoaderDoesNotStartRequestAfterCancellation() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedURLProtocol.self]
        let gate = RequestStartGate()
        let loader = URLSessionPodcastFeedLoader(configuration: configuration) {
            await gate.waitForRelease()
        }
        FeedURLProtocol.resetCancellationRequestCount()
        let task = Task {
            try await loader.load(URL(string: "https://podcasts.example.test/feed.xml?case=cancel")!, maximumBytes: 1_024)
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        await expect(.cancelled) { _ = try await task.value }
        #expect(FeedURLProtocol.cancellationRequestCount == 0)
    }

    private func expect<T: Sendable>(_ expected: PodcastFeedClientError, _ operation: @escaping @Sendable () async throws -> T) async {
        do { _ = try await operation(); Issue.record("Expected \(expected)") }
        catch let error as PodcastFeedClientError { #expect(error == expected) }
        catch { Issue.record("Unexpected error: \(error)") }
    }
}

private final class FeedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let cancellationRequests = RequestCounter()

    static var cancellationRequestCount: Int { cancellationRequests.value }
    static func resetCancellationRequestCount() { cancellationRequests.reset() }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "podcasts.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let requestCase = request.url?.query ?? ""
        if requestCase == "case=cancel" { Self.cancellationRequests.increment() }
        if requestCase == "case=redirect" || requestCase == "case=downgrade" {
            let target = URL(string: requestCase == "case=redirect"
                ? "https://podcasts.example.test/feed.xml?case=success"
                : "http://podcasts.example.test/feed.xml?case=success")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        let isHeaderCase = requestCase == "case=header"
        let headers = isHeaderCase ? ["Content-Length": "2"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if requestCase == "case=success" {
            client?.urlProtocol(self, didLoad: Data("<rss><channel><title>Show</title></channel></rss>".utf8))
        } else if !isHeaderCase {
            client?.urlProtocol(self, didLoad: Data([0]))
            client?.urlProtocol(self, didLoad: Data([1]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}

private actor RequestStartGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
