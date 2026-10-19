import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

private let secretToken = "SECRET-TOKEN"
private let secretURL = URL(string: "https://cdn.example.test/ep.mp3?token=SECRET-TOKEN")!

@Suite("LogSafeError descriptions")
struct LogSafeErrorBehaviorTests {
    @Test func urlErrorKeepsOnlyDomainCodeAndHost() {
        let url = secretURL
        let underlying = NSError(
            domain: "kCFErrorDomainCFNetwork", code: -1009,
            userInfo: [NSURLErrorFailingURLStringErrorKey: url.absoluteString]
        )
        let error = URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSURLErrorFailingURLStringErrorKey: url.absoluteString,
            NSUnderlyingErrorKey: underlying,
        ])
        let description = LogSafeError.describe(error)
        #expect(description == "NSURLErrorDomain/-1009 host=cdn.example.test")
        #expect(!description.contains(secretToken))
    }

    @Test func urlErrorWithoutUserInfoKeepsDomainAndCode() {
        #expect(LogSafeError.describe(URLError(.timedOut)) == "NSURLErrorDomain/-1001")
    }

    @Test func wrapperErrorScrubsNestedURL() {
        let error = NSError(
            domain: "Wrapper", code: 7,
            userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet, userInfo: [
                NSURLErrorFailingURLErrorKey: secretURL,
                NSURLErrorFailingURLStringErrorKey: secretURL.absoluteString,
            ])]
        )
        let description = LogSafeError.describe(error)
        #expect(description.contains("Wrapper"))
        #expect(!description.contains(secretToken))
        #expect(!description.contains("?token"))
        #expect(!description.contains("/ep.mp3"))
    }

    @Test func payloadStringCannotCarrySecretURL() {
        let description = LogSafeError.describe(PayloadError.failed(secretURL.absoluteString))
        #expect(!description.contains(secretToken))
        #expect(!description.contains("?"))
    }

    @Test func scrubbingReducesEveryURLToSchemeAndHost() {
        #expect(
            LogSafeError.scrubbingURLs("see https://a.example/x?y=1, then file:///Users/me/z")
                == "see https://a.example, then file://"
        )
    }

    @Test func coordinatorTransportFailureDoesNotPersistSecretURL() async throws {
        let fixture = try await SecretURLFixture()
        defer { fixture.remove() }
        let urlError = URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorFailingURLErrorKey: fixture.enclosureURL,
            NSURLErrorFailingURLStringErrorKey: fixture.enclosureURL.absoluteString,
        ])
        let coordinator = PodcastDownloadCoordinator(
            store: fixture.store, libraryDirectory: fixture.libraryDirectory,
            transport: URLErrorTransport(error: urlError), mediaValidator: FixedDurationValidator()
        )
        do {
            _ = try await coordinator.download(episodeID: fixture.episodeID)
            Issue.record("expected transport failure")
        } catch {
            guard let coordinatorError = error as? PodcastDownloadCoordinatorError,
                  case let .transport(payload) = coordinatorError
            else {
                Issue.record("expected transport error, got \(error)")
                return
            }
            #expect(!payload.contains(secretToken))
            #expect(payload.contains("cdn.example.test"))
            #expect(!String(describing: error).contains(secretToken))
        }
    }
}

private enum PayloadError: Error {
    case failed(String)
}

private struct SecretURLFixture {
    let root: URL
    let libraryDirectory: URL
    let store: LocalLibraryStore
    let episodeID: ItemID
    let enclosureURL: URL

    init() async throws {
        root = OwnedTestTemp.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        enclosureURL = URL(string: "https://cdn.example.test/ep.mp3?token=SECRET-TOKEN")!
        let feedURL = URL(string: "https://podcasts.example.test/feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "episode-1", enclosureURL: enclosureURL
        )
        try await store.save(episode: PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-1", title: "Episode",
            enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", enclosureByteCount: nil,
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct URLErrorTransport: PodcastDownloadTransporting, @unchecked Sendable {
    let error: URLError

    func events(for _: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

private struct FixedDurationValidator: PodcastMediaValidating {
    func duration(of _: URL, onStatus: @escaping @Sendable (String) -> Void) async throws -> Double {
        onStatus("validating")
        return 12
    }
}
