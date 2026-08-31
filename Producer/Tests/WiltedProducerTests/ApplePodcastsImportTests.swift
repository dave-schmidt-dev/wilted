import Foundation
import SQLite3
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Apple Podcasts import")
struct ApplePodcastsImportTests {
    /// The play-state filter is the whole point of the import: the listener
    /// asked for the episodes still waiting, not the ones already heard.
    /// State 0 is played or marked played, 1 is in progress, 2 is unplayed.
    @Test func readsOnlyDownloadedEpisodesTheListenerHasNotFinished() throws {
        let source = try fixture(rows: [
            .init(feed: "Show A", feedURL: "https://a.example.test/feed.xml", guid: "a-unplayed",
                  title: "Unplayed", playState: 2, downloaded: true),
            .init(feed: "Show A", feedURL: "https://a.example.test/feed.xml", guid: "a-progress",
                  title: "In progress", playState: 1, downloaded: true),
            .init(feed: "Show A", feedURL: "https://a.example.test/feed.xml", guid: "a-played",
                  title: "Played", playState: 0, downloaded: true),
            // Not downloaded, so out of scope no matter what its play state is.
            .init(feed: "Show A", feedURL: "https://a.example.test/feed.xml", guid: "a-remote",
                  title: "Streaming only", playState: 2, downloaded: false),
        ])
        defer { try? FileManager.default.removeItem(at: source) }

        let feeds = try ApplePodcastsLibrary.read(at: source)
        #expect(feeds.count == 1)
        #expect(feeds[0].unfinished.map(\.guid).sorted() == ["a-progress", "a-unplayed"])
        #expect(feeds[0].playedCount == 1)
    }

    /// A podcast the listener unsubscribed from is not theirs to import, even
    /// when its episodes are still on disk.
    @Test func ignoresUnsubscribedPodcasts() throws {
        let source = try fixture(rows: [
            .init(feed: "Kept", feedURL: "https://kept.example.test/feed.xml", guid: "kept-1",
                  title: "Kept", playState: 2, downloaded: true),
            .init(feed: "Dropped", feedURL: "https://dropped.example.test/feed.xml", guid: "dropped-1",
                  title: "Dropped", playState: 2, downloaded: true, subscribed: false),
        ])
        defer { try? FileManager.default.removeItem(at: source) }

        #expect(try ApplePodcastsLibrary.read(at: source).map(\.title) == ["Kept"])
    }

    /// Apple stores dates against Core Data's 2001 epoch. Reading them as Unix
    /// seconds would place every episode 31 years early and quietly defeat any
    /// recency rule downstream.
    @Test func convertsCoreDataDatesAndOptionalMetadata() throws {
        let published = Date(timeIntervalSince1970: 1_756_600_000)
        let source = try fixture(rows: [
            .init(feed: "Show", feedURL: "https://show.example.test/feed.xml", guid: "dated",
                  title: "Dated", playState: 2, downloaded: true,
                  publishedAt: published, duration: 1_800, byteCount: 4_096),
            .init(feed: "Show", feedURL: "https://show.example.test/feed.xml", guid: "bare",
                  title: "Bare", playState: 2, downloaded: true,
                  publishedAt: nil, duration: 0, byteCount: 0),
        ])
        defer { try? FileManager.default.removeItem(at: source) }

        let episodes = try ApplePodcastsLibrary.read(at: source)[0].unfinished
        let dated = try #require(episodes.first { $0.guid == "dated" })
        let bare = try #require(episodes.first { $0.guid == "bare" })
        #expect(abs(try #require(dated.publishedAt).timeIntervalSince(published)) < 1)
        #expect(dated.durationSeconds == 1_800)
        #expect(dated.byteCount == 4_096)
        // Apple writes zero rather than null for unknown duration and size.
        #expect(bare.publishedAt == nil)
        #expect(bare.durationSeconds == nil)
        #expect(bare.byteCount == nil)
    }

    /// Episode identity includes the canonical feed URL, and a feed that
    /// redirects resolves to a different one than Apple stored. Rebuilding
    /// against the loaded feed is what keeps a rebuilt episode addressable by
    /// the same identity a later refresh will derive.
    @Test func rebuildsAgainstTheLoadedFeedIdentity() throws {
        let canonical = URL(string: "https://cdn.example.test/redirected/feed.xml")!
        let feed = try PodcastFeed(
            itemID: ItemID.derivePodcastFeed(from: canonical), canonicalURL: canonical,
            title: "Show", artworkURL: URL(string: "https://cdn.example.test/art.jpg"),
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let apple = ApplePodcastsLibrary.Episode(
            guid: "rolled-off", title: "Rolled off the feed",
            enclosureURL: "https://cdn.example.test/media/rolled-off.m4a",
            publishedAt: Date(timeIntervalSince1970: 1_756_600_000), durationSeconds: 900, byteCount: 2_048
        )

        let rebuilt = try ApplePodcastsLibrary.rebuild(
            apple, into: feed, createdAt: Date(timeIntervalSince1970: 1_756_700_000)
        )
        #expect(rebuilt.feedID == feed.itemID)
        #expect(rebuilt.feedURL == canonical)
        #expect(rebuilt.itemID == (try ItemID.derivePodcastEpisode(
            feedURL: canonical, rssGUID: "rolled-off",
            enclosureURL: URL(string: "https://cdn.example.test/media/rolled-off.m4a")!
        )))
        #expect(rebuilt.enclosureMediaType == "audio/mp4")
        #expect(rebuilt.artworkURL == feed.artworkURL)
    }

    @Test func refusesToRebuildAnEpisodeWithoutAnHTTPSEnclosure() throws {
        let canonical = URL(string: "https://cdn.example.test/feed.xml")!
        let feed = try PodcastFeed(
            itemID: ItemID.derivePodcastFeed(from: canonical), canonicalURL: canonical,
            title: "Show", createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        for enclosure in ["http://cdn.example.test/a.mp3", "not a url at all", ""] {
            let apple = ApplePodcastsLibrary.Episode(
                guid: "g", title: "T", enclosureURL: enclosure,
                publishedAt: nil, durationSeconds: nil, byteCount: nil
            )
            #expect(throws: ApplePodcastsLibrary.ReadError.self) {
                try ApplePodcastsLibrary.rebuild(apple, into: feed, createdAt: Date())
            }
        }
    }

    @Test func infersAudioMediaTypeFromTheEnclosureExtension() {
        let cases = [
            "https://c.example.test/a.mp3": "audio/mpeg",
            "https://c.example.test/a.m4a": "audio/mp4",
            "https://c.example.test/a.M4A": "audio/mp4",
            "https://c.example.test/a.opus": "audio/opus",
            "https://c.example.test/a.wav": "audio/wav",
            // No extension at all still has to yield a type the domain accepts.
            "https://c.example.test/stream": "audio/mpeg",
        ]
        for (raw, expected) in cases {
            #expect(ApplePodcastsLibrary.inferredMediaType(for: URL(string: raw)!) == expected)
        }
    }

    @Test func reportsAnUnreadableSourceRatherThanReturningNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-absent-\(UUID().uuidString).sqlite")
        #expect(throws: ApplePodcastsLibrary.ReadError.self) { try ApplePodcastsLibrary.read(at: missing) }
    }

    // MARK: - Fixture

    private struct Row {
        var feed: String
        var feedURL: String
        var guid: String
        var title: String
        var playState: Int
        var downloaded: Bool
        var subscribed = true
        var publishedAt: Date?
        var duration: Double = 0
        var byteCount: Int64 = 0
    }

    /// Builds the two Apple Podcasts tables this reader touches, with the
    /// columns it reads. Only the shape matters, so the fixture stays small.
    private func fixture(rows: [Row], function: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-apple-fixture-\(function)-\(UUID().uuidString).sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let database = handle else {
            throw ApplePodcastsLibrary.ReadError.open("fixture")
        }
        defer { sqlite3_close(database) }
        func run(_ sql: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw ApplePodcastsLibrary.ReadError.query(String(cString: sqlite3_errmsg(database)))
            }
        }
        try run("CREATE TABLE ZMTPODCAST (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZFEEDURL TEXT, ZSUBSCRIBED INTEGER)")
        try run("""
            CREATE TABLE ZMTEPISODE (Z_PK INTEGER PRIMARY KEY, ZPODCAST INTEGER, ZGUID TEXT, ZTITLE TEXT,
                                     ZPLAYSTATE INTEGER, ZASSETURL TEXT, ZENCLOSUREURL TEXT,
                                     ZPUBDATE REAL, ZDURATION REAL, ZBYTESIZE INTEGER)
            """)

        var podcastKeys: [String: Int] = [:]
        func escaped(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        for row in rows {
            let key: Int
            if let existing = podcastKeys[row.feedURL] {
                key = existing
            } else {
                key = podcastKeys.count + 1
                podcastKeys[row.feedURL] = key
                try run("INSERT INTO ZMTPODCAST VALUES (\(key), \(escaped(row.feed)), "
                    + "\(escaped(row.feedURL)), \(row.subscribed ? 1 : 0))")
            }
            let asset = row.downloaded ? escaped("file:///downloads/\(row.guid).mp3") : "NULL"
            let published = row.publishedAt.map {
                String($0.timeIntervalSince1970 - ApplePodcastsLibrary.coreDataEpochOffset)
            } ?? "NULL"
            try run("INSERT INTO ZMTEPISODE VALUES (NULL, \(key), \(escaped(row.guid)), \(escaped(row.title)), "
                + "\(row.playState), \(asset), \(escaped("https://cdn.example.test/\(row.guid).mp3")), "
                + "\(published), \(row.duration), \(row.byteCount))")
        }
        return url
    }
}
