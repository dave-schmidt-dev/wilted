import Foundation
import SQLite3
import WiltedDomain

/// Reads an Apple Podcasts library so its subscriptions can be brought into
/// Wilted.
///
/// Nothing personal lives in this file: every feed URL and episode identity is
/// read at run time from the database the caller points at. The library is
/// opened through a throwaway copy, so a running Podcasts app is never
/// disturbed and this code can never write to it.
public enum ApplePodcastsLibrary {
    /// Default location of the Apple Podcasts library on macOS.
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
            "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents/MTLibrary.sqlite"
        )
    }

    /// `ZMTEPISODE.ZPLAYSTATE` values that mean the listener is not finished
    /// with an episode.
    ///
    /// Determined from the listener's own library on 2026-08-31 rather than
    /// assumed: across 48 downloaded episodes, every row with state 0 carried a
    /// `ZLASTDATEPLAYED` and 18 of 21 also carried a
    /// `ZLASTUSERMARKEDASPLAYEDDATE`, while every row with state 2 had neither
    /// and a playhead at zero. State 0 is played or marked played, 1 is in
    /// progress, 2 is unplayed. `ZHASBEENPLAYED` was null on all 48 and is not
    /// a usable signal.
    public static let unfinishedPlayStates: Set<Int> = [1, 2]

    /// Core Data stores dates as seconds from its own 2001-01-01 epoch.
    static let coreDataEpochOffset: TimeInterval = 978_307_200

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case open(String)
        case query(String)
        case unusableEpisode(String)

        public var description: String {
            switch self {
            case .open(let detail): "cannot open the Apple Podcasts library: \(detail)"
            case .query(let detail): "the Apple Podcasts library query failed: \(detail)"
            case .unusableEpisode(let detail): "cannot rebuild episode: \(detail)"
            }
        }
    }

    /// One downloaded episode as Apple Podcasts recorded it.
    ///
    /// Wilted prefers the feed's own copy of an episode. This is the fallback
    /// for the ones a feed no longer carries: a bonus item, a cross-promotion,
    /// or an episode past the window the publisher serves.
    public struct Episode: Equatable, Sendable {
        public let guid: String
        public let title: String
        public let enclosureURL: String
        public let publishedAt: Date?
        public let durationSeconds: Double?
        public let byteCount: Int64?
    }

    public struct Feed: Equatable, Sendable {
        public let title: String
        public let feedURL: String
        /// Downloaded episodes the listener has not finished with.
        public internal(set) var unfinished: [Episode]
        /// Downloaded episodes excluded because the listener already played
        /// them or marked them played.
        public internal(set) var playedCount: Int
    }

    /// Every subscribed feed, with its downloaded episodes partitioned by
    /// whether the listener is finished with them. Feeds are ordered by title.
    public static func read(at source: URL) throws -> [Feed] {
        let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "wilted-apple-podcasts-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).sqlite"
        )
        // The write-ahead log and shared-memory sidecars come along because the
        // library is a WAL database: without them the copy is missing the most
        // recent commits.
        let sidecars = ["", "-wal", "-shm"]
        defer {
            for suffix in sidecars {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        do { try FileManager.default.copyItem(at: source, to: copy) }
        catch { throw ReadError.open(error.localizedDescription) }
        for suffix in sidecars.dropFirst() {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            try? FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
        }

        // The copy is opened read-write so SQLite may replay the write-ahead log
        // into it. Read-only would refuse the log and report the database as
        // unopenable. The original is never touched either way.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = handle else {
            throw ReadError.open(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
        }
        defer { sqlite3_close(database) }

        var feeds: [String: Feed] = [:]
        var order: [String] = []
        try eachRow(database, """
            SELECT ZTITLE, ZFEEDURL FROM ZMTPODCAST
            WHERE ZSUBSCRIBED = 1 AND ZFEEDURL IS NOT NULL ORDER BY ZTITLE
            """) { statement in
            guard let feedURL = text(statement, 1) else { return }
            guard feeds[feedURL] == nil else { return }
            feeds[feedURL] = Feed(
                title: text(statement, 0) ?? "Untitled podcast", feedURL: feedURL,
                unfinished: [], playedCount: 0
            )
            order.append(feedURL)
        }

        try eachRow(database, """
            SELECT p.ZFEEDURL, e.ZGUID, e.ZPLAYSTATE, e.ZTITLE, e.ZENCLOSUREURL,
                   e.ZPUBDATE, e.ZDURATION, e.ZBYTESIZE
            FROM ZMTEPISODE e JOIN ZMTPODCAST p ON e.ZPODCAST = p.Z_PK
            WHERE p.ZSUBSCRIBED = 1 AND e.ZASSETURL IS NOT NULL AND e.ZASSETURL <> ''
            """) { statement in
            guard let feedURL = text(statement, 0), var feed = feeds[feedURL] else { return }
            defer { feeds[feedURL] = feed }
            guard unfinishedPlayStates.contains(Int(sqlite3_column_int64(statement, 2))) else {
                feed.playedCount += 1
                return
            }
            guard let guid = text(statement, 1), let title = text(statement, 3),
                  let enclosureURL = text(statement, 4) else { return }
            let duration = sqlite3_column_double(statement, 6)
            let bytes = sqlite3_column_int64(statement, 7)
            feed.unfinished.append(Episode(
                guid: guid, title: title, enclosureURL: enclosureURL,
                publishedAt: sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5) + coreDataEpochOffset),
                durationSeconds: duration > 0 ? duration : nil,
                byteCount: bytes > 0 ? bytes : nil
            ))
        }

        return order.compactMap { feeds[$0] }
    }

    /// Rebuilds an episode Wilted can store from Apple's row.
    ///
    /// Identity is derived from the feed Wilted actually loaded, never from the
    /// URL string Apple stored: a feed that redirects resolves to a different
    /// canonical URL, and episode identity includes it. `PodcastEpisode`
    /// re-derives and rejects a mismatch, so a wrong feed here fails loudly
    /// instead of writing an episode no feed owns.
    public static func rebuild(
        _ episode: Episode, into feed: PodcastFeed, createdAt: Date
    ) throws -> PodcastEpisode {
        guard let enclosureURL = URL(string: episode.enclosureURL),
              enclosureURL.scheme?.lowercased() == "https", enclosureURL.host != nil else {
            throw ReadError.unusableEpisode("\(episode.title) has no HTTPS enclosure URL")
        }
        return try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(
                feedURL: feed.canonicalURL, rssGUID: episode.guid, enclosureURL: enclosureURL
            ),
            feedID: feed.itemID,
            feedURL: feed.canonicalURL,
            rssGUID: episode.guid,
            title: episode.title,
            publishedTime: episode.publishedAt.map(Timestamp.init),
            enclosureURL: enclosureURL,
            enclosureMediaType: inferredMediaType(for: enclosureURL),
            enclosureByteCount: episode.byteCount,
            durationSeconds: episode.durationSeconds,
            artworkURL: feed.artworkURL,
            createdAt: Timestamp(createdAt)
        )
    }

    /// Best-effort audio MIME type for an episode the feed no longer carries.
    ///
    /// Apple records only that the download is audio, not which audio. A feed's
    /// own value always wins; this runs only for rebuilt episodes, where the
    /// file extension is the only evidence available.
    public static func inferredMediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4", "m4b": "audio/mp4"
        case "aac": "audio/aac"
        case "opus": "audio/opus"
        case "ogg", "oga": "audio/ogg"
        case "wav": "audio/wav"
        case "flac": "audio/flac"
        default: "audio/mpeg"
        }
    }

    private static func eachRow(
        _ database: OpaquePointer, _ sql: String, _ body: (OpaquePointer) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadError.query(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { body(statement) }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
}
