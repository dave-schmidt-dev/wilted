import Foundation
import Testing
import WiltedDomain
import WiltedCatalog
import WiltedLibrary
@testable import WiltedProducer

private struct StaticPodcastChapterLoader: PodcastChapterDocumentLoading {
    let data: Data
    func load(_ url: URL, maximumBytes: Int) async throws -> Data { data }
}

private struct FailingPodcastChapterLoader: PodcastChapterDocumentLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> Data { throw URLError(.cannotLoadFromNetwork) }
}

private struct StaticFeedResponseLoader: PodcastFeedLoading {
    let data: Data
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: url, statusCode: 200, data: data)
    }
}

private struct ChapterDNSFixture: ArticleAddressResolving {
    let answers: [String: [String]]
    func addresses(for host: String) async throws -> [String] { answers[host] ?? [] }
}

private actor ChapterTransferFixture: PinnedArticleTransferring {
    private var responses: [Data]
    private(set) var requests: [PinnedArticleTransferRequest] = []

    init(_ responses: [Data]) { self.responses = responses }

    func transfer(_ request: PinnedArticleTransferRequest) async throws -> Data {
        requests.append(request)
        guard !responses.isEmpty else { throw PublicHTTPSArticleError.transferFailed }
        return responses.removeFirst()
    }
}

@Suite("Podcast chapters")
struct PodcastChapterTests {
    private let feedURL = URL(string: "https://feeds.example.test/show.xml")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func capturesOnlyLinkedPodcastingJSONChapterSources() async throws {
        let loaded = try await PodcastFeedClient(loader: StaticFeedResponseLoader(data: Data(#"""
        <rss xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Show</title><item>
          <title>Episode</title>
          <podcast:chapters url="chapters.json" type="application/json+chapters" />
          <enclosure url="https://cdn.example.test/episode.mp3" type="audio/mpeg" />
        </item></channel></rss>
        """#.utf8)), now: { now }).load(feedURL)
        #expect(loaded.episodes.first?.chapterSource?.url.absoluteString == "https://feeds.example.test/chapters.json")

        let unsupported = try await PodcastFeedClient(loader: StaticFeedResponseLoader(data: Data(#"""
        <rss xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Show</title><item>
          <title>Episode</title>
          <podcast:chapters url="http://private.example/chapters.json" type="application/json+chapters" />
          <podcast:chapters url="https://cdn.example.test/chapters.json" type="application/json" />
          <enclosure url="https://cdn.example.test/episode.mp3" type="audio/mpeg" />
        </item></channel></rss>
        """#.utf8)), now: { now }).load(feedURL)
        #expect(unsupported.episodes.first?.chapterSource == nil)
    }

    @Test func parsesBoundedOrderedJSONAndFiltersNonTOCMarkers() throws {
        let data = Data(#"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Intro"},{"startTime":2,"title":"Part A","toc":false},{"startTime":4,"title":"Part B","toc":true}]}"#.utf8)
        #expect(PodcastChapterDocument.parse(data) == [
            PodcastChapterMark(title: "Intro", startSeconds: 0),
            PodcastChapterMark(title: "Part B", startSeconds: 4)
        ])
        #expect(PodcastChapterDocument.parse(Data(#"{"version":"1","chapters":[{"startTime":0,"toc":1}]}"#.utf8)) == nil)
        #expect(PodcastChapterDocument.parse(Data(#"{"version":"1","chapters":[{"startTime":2},{"startTime":1}]}"#.utf8)) == nil)
        #expect(PodcastChapterDocument.parse(Data(#"{"version":"2","chapters":[{"startTime":0}]}"#.utf8)) == nil)
        #expect(PodcastChapterDocument.parse(Data(repeating: 0x20, count: PodcastChapterDocument.maximumDocumentBytes + 1)) == nil)
    }

    @Test func publicChapterLoaderRequiresExactMIMEAndRechecksRedirectHost() async throws {
        let transfer = ChapterTransferFixture([
            Self.response(302, headers: "Location: https://cdn.example.test/chapter.json\r\n"),
            Self.response(200, headers: "Content-Type: application/json+chapters; charset=utf-8\r\n", body: "{}")
        ])
        let loader = PublicHTTPSPodcastChapterLoader(
            resolver: ChapterDNSFixture(answers: ["feeds.example.test": ["1.1.1.1"], "cdn.example.test": ["8.8.8.8"]]),
            transferClient: transfer)
        let data = try await loader.load(URL(string: "https://feeds.example.test/chapter.json")!, maximumBytes: 128)
        #expect(String(decoding: data, as: UTF8.self) == "{}")
        let requests = await transfer.requests
        #expect(requests.map(\.address) == ["1.1.1.1", "8.8.8.8"])

        let wrongType = PublicHTTPSPodcastChapterLoader(
            resolver: ChapterDNSFixture(answers: ["feeds.example.test": ["1.1.1.1"]]),
            transferClient: ChapterTransferFixture([
                Self.response(200, headers: "Content-Type: application/json\r\n", body: "{}")
            ]))
        do {
            _ = try await wrongType.load(URL(string: "https://feeds.example.test/chapter.json")!, maximumBytes: 128)
            Issue.record("A generic JSON response must not be accepted as Podcasting 2.0 chapters")
        } catch let error as PublicHTTPSArticleError {
            #expect(error == .invalidResponse)
        }
    }

    @Test func mapsCutsSilenceCollapsedStartsAndDropsRemovedTail() {
        let kept = [
            PodcastKeepInterval(startSeconds: 0, endSeconds: 2, outputStartSeconds: 0),
            PodcastKeepInterval(startSeconds: 5, endSeconds: 10, outputStartSeconds: 2),
            PodcastKeepInterval(startSeconds: 12, endSeconds: 14, outputStartSeconds: 7)
        ]
        let mapped = PodcastChapterMapping.map([
            PodcastChapterMark(title: "Kept", startSeconds: 1),
            PodcastChapterMark(title: "Ad topic A", startSeconds: 2.5),
            PodcastChapterMark(title: "Ad topic B", startSeconds: 4),
            PodcastChapterMark(title: "Silence", startSeconds: 11),
            PodcastChapterMark(title: "After silence", startSeconds: 12.5),
            PodcastChapterMark(title: "Removed tail", startSeconds: 14)
        ], through: kept)
        #expect(mapped == [
            PodcastChapterMark(title: "Kept", startSeconds: 1),
            PodcastChapterMark(title: "Ad topic A", startSeconds: 2),
            PodcastChapterMark(title: "Ad topic B", startSeconds: 2),
            PodcastChapterMark(title: "Silence", startSeconds: 7),
            PodcastChapterMark(title: "After silence", startSeconds: 7.5)
        ])
    }

    @Test func parsesID3v23AndV24CHAPFramesFromLocalFixture() throws {
        for version in [UInt8(3), UInt8(4)] {
            let file = OwnedTestTemp.root.appendingPathComponent("chapter-id3-\(version)-\(UUID().uuidString).mp3")
            try Self.id3Tag(version: version, chapters: [("Opening", 0), ("Interview", 12_500)]).write(to: file)
            let chapters = try #require(ID3PodcastChapterReader.read(from: file))
            #expect(chapters == [
                PodcastChapterMark(title: "Opening", startSeconds: 0),
                PodcastChapterMark(title: "Interview", startSeconds: 12.5)
            ])
        }
    }

    @Test func jsonChapterSourceWinsAndFailedOptionalFetchFallsBackToID3() async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        try Self.id3Tag(version: 4, chapters: [("ID3 chapter", 3_000)]).write(to: fixture.audioURL)
        let source = try PodcastChapterSource(
            url: URL(string: "https://feeds.example.test/chapters.json")!, mediaType: PodcastChapterSource.jsonMediaType)
        let episode = try Self.episode(fixture, chapterSource: source)

        let json = Data(#"{"version":"1","chapters":[{"startTime":7,"title":"JSON chapter"}]}"#.utf8)
        let jsonPipeline = PodcastPreparationPipeline(store: fixture.store, workDirectory: fixture.workDirectory,
            chapterLoader: StaticPodcastChapterLoader(data: json), removeAds: false, allowSpeechToText: false)
        let jsonMarks = try await jsonPipeline.chapterMarks(for: episode, audioURL: fixture.audioURL)
        #expect(jsonMarks == [PodcastChapterMark(title: "JSON chapter", startSeconds: 7)])

        let fallbackPipeline = PodcastPreparationPipeline(store: fixture.store, workDirectory: fixture.workDirectory,
            chapterLoader: FailingPodcastChapterLoader(), removeAds: false, allowSpeechToText: false)
        let fallbackMarks = try await fallbackPipeline.chapterMarks(for: episode, audioURL: fixture.audioURL)
        #expect(fallbackMarks == [PodcastChapterMark(title: "ID3 chapter", startSeconds: 3)])
    }

    @Test func sourceAndPreparedChapterSidecarsPersistAndPublishOnlyForCurrentRevision() async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        let source = try PodcastChapterSource(
            url: URL(string: "https://feeds.example.test/chapters.json")!, mediaType: PodcastChapterSource.jsonMediaType)
        try await fixture.store.save(episode: Self.episode(fixture, chapterSource: source))
        try await fixture.store.savePreparedPodcastChapters(
            [PodcastChapterMark(title: "Published chapter", startSeconds: 1)],
            for: fixture.episodeID, revisionID: fixture.revisionID)
        let reopenedEpisode = try #require(try await fixture.store.podcastEpisode(for: fixture.episodeID))
        #expect(reopenedEpisode.chapterSource == source)
        let published = try await fixture.store.podcastLibrarySnapshot(profile: .publication)
        #expect(published.episodes.first?.chapterSource == source)
        #expect(published.preparedPodcastChapters[fixture.episodeID]?.revisionID == fixture.revisionID)
        #expect(published.preparedPodcastChapters[fixture.episodeID]?.chapters.first?.title == "Published chapter")
        let nextRevision = try RevisionID(rawValue: "replacement-revision")
        let nextURL = fixture.audioURL.deletingLastPathComponent().appendingPathComponent("replacement-revision.mp3")
        let nextBytes = Data("replacement prepared audio".utf8)
        try nextBytes.write(to: nextURL)
        try await fixture.store.saveReadyRevision(try AudioRevision(
            itemID: fixture.episodeID, revisionID: nextRevision, durationSeconds: 12,
            byteCount: Int64(nextBytes.count), contentHash: "sha256:" + String(repeating: "b", count: 64),
            mediaType: "audio/mpeg", createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_101)),
            schemaVersion: 3), mediaURL: nextURL)
        let chaptersForNext = await fixture.store.preparedPodcastChapters(for: fixture.episodeID, revisionID: nextRevision)
        #expect(chaptersForNext == nil)
        let replacementSnapshot = try await fixture.store.podcastLibrarySnapshot(profile: .publication)
        #expect(replacementSnapshot.preparedPodcastChapters[fixture.episodeID] == nil)
    }

    private static func episode(
        _ fixture: PodcastPreparationPipelineTests.Fixture,
        chapterSource: PodcastChapterSource
    ) throws -> PodcastEpisode {
        let feedURL = URL(string: PodcastPreparationPipelineTests.Fixture.feedAddress)!
        let enclosureURL = URL(string: "https://cdn.example.test/e1.mp3")!
        return try PodcastEpisode(
            itemID: fixture.episodeID, feedID: try ItemID.derivePodcastFeed(from: feedURL), feedURL: feedURL,
            rssGUID: "e1", title: "Episode", enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
            chapterSource: chapterSource, createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private static func response(_ status: Int, headers: String = "", body: String = "") -> Data {
        Data("HTTP/1.1 \(status) Test\r\n\(headers)\r\n\(body)".utf8)
    }

    private static func id3Tag(version: UInt8, chapters: [(String, UInt32)]) -> Data {
        let frames = chapters.enumerated().map { index, chapter in
            let (title, milliseconds) = chapter
            var body = Data("chapter-\(index)".utf8)
            body.append(0)
            body.append(contentsOf: bigEndian(milliseconds))
            body.append(contentsOf: bigEndian(UInt32.max))
            body.append(contentsOf: bigEndian(UInt32.max))
            body.append(contentsOf: bigEndian(UInt32.max))
            var titleBody = Data([3])
            titleBody.append(contentsOf: title.utf8)
            let titleFrame = frame(id: "TIT2", body: titleBody, version: version)
            body.append(titleFrame)
            return frame(id: "CHAP", body: body, version: version)
        }.reduce(into: Data()) { $0.append($1) }
        var tag = Data([0x49, 0x44, 0x33, version, 0, 0])
        tag.append(contentsOf: synchsafe(UInt32(frames.count)))
        tag.append(frames)
        return tag
    }

    private static func frame(id: String, body: Data, version: UInt8) -> Data {
        var result = Data(id.utf8)
        result.append(contentsOf: version == 4 ? synchsafe(UInt32(body.count)) : bigEndian(UInt32(body.count)))
        result.append(contentsOf: [0, 0])
        result.append(body)
        return result
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private static func synchsafe(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 21) & 0x7f), UInt8((value >> 14) & 0x7f), UInt8((value >> 7) & 0x7f), UInt8(value & 0x7f)]
    }
}
