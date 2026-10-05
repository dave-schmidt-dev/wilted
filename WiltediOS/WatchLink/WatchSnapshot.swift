import Foundation

/// One queued episode the watch may start, without any phone-only payloads.
public struct UpNextRow: Codable, Equatable, Sendable {
    /// Identifier of the queued episode.
    public let episodeID: String
    /// Episode title.
    public let title: String
    /// Title of the show that owns the episode.
    public let showTitle: String
    /// Episode duration in seconds, when the phone knows it.
    public let durationSeconds: Double?

    public init(episodeID: String, title: String, showTitle: String, durationSeconds: Double? = nil) {
        self.episodeID = episodeID
        self.title = title
        self.showTitle = showTitle
        self.durationSeconds = durationSeconds
    }
}

/// The episode the phone is playing, reduced to watch-sized fields.
public struct NowPlaying: Codable, Equatable, Sendable {
    /// Identifier of the playing episode.
    public let episodeID: String
    /// Episode title.
    public let title: String
    /// Title of the show that owns the episode.
    public let showTitle: String
    /// Playback position in seconds.
    public let positionSeconds: Double
    /// Episode duration in seconds, when the phone knows it.
    public let durationSeconds: Double?
    /// Whether the phone is playing rather than paused.
    public let isPlaying: Bool

    public init(
        episodeID: String,
        title: String,
        showTitle: String,
        positionSeconds: Double,
        durationSeconds: Double? = nil,
        isPlaying: Bool
    ) {
        self.episodeID = episodeID
        self.title = title
        self.showTitle = showTitle
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.isPlaying = isPlaying
    }
}

/// The phone's sleep-timer state, mirrored so the watch can render it.
public enum SleepState: Equatable, Sendable {
    /// No sleep timer is running.
    case off
    /// Playback stops at the given date.
    case untilDate(Date)
    /// Playback stops when the current episode ends.
    case endOfEpisode
}

extension SleepState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case date
    }

    private enum Kind: String, Codable {
        case off
        case untilDate
        case endOfEpisode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .off:
            self = .off
        case .untilDate:
            let date = try container.decode(Date.self, forKey: .date)
            self = .untilDate(date)
        case .endOfEpisode:
            self = .endOfEpisode
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .off:
            try container.encode(Kind.off, forKey: .kind)
        case let .untilDate(date):
            try container.encode(Kind.untilDate, forKey: .kind)
            try container.encode(date, forKey: .date)
        case .endOfEpisode:
            try container.encode(Kind.endOfEpisode, forKey: .kind)
        }
    }
}

/// A versioned snapshot of phone playback state, published in the watch's
/// application context.
public struct WatchSnapshot: Codable, Equatable, Sendable {
    /// Version of the snapshot wire format this build writes.
    public static let currentVersion = 1
    /// Most up-next rows a snapshot carries.
    public static let upNextLimit = 25

    /// Version of the wire format this value uses.
    public let version: Int
    /// The playing episode, or nil when the phone is idle.
    public let nowPlaying: NowPlaying?
    /// Upcoming queue rows, never more than `upNextLimit`.
    public let upNext: [UpNextRow]
    /// Current playback rate.
    public let rate: Double
    /// Current sleep-timer state.
    public let sleep: SleepState
    /// When the phone produced this snapshot.
    public let publishedAt: Date

    public init(
        version: Int = WatchSnapshot.currentVersion,
        nowPlaying: NowPlaying? = nil,
        upNext: [UpNextRow] = [],
        rate: Double = 1,
        sleep: SleepState = .off,
        publishedAt: Date = Date()
    ) {
        self.version = version
        self.nowPlaying = nowPlaying
        self.upNext = Array(upNext.prefix(Self.upNextLimit))
        self.rate = rate
        self.sleep = sleep
        self.publishedAt = publishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case nowPlaying
        case upNext
        case rate
        case sleep
        case publishedAt
    }

    /// Decodes a snapshot and re-applies the up-next cap, so a remote writer
    /// cannot grow the list past `upNextLimit`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        nowPlaying = try container.decodeIfPresent(NowPlaying.self, forKey: .nowPlaying)
        let rows = try container.decode([UpNextRow].self, forKey: .upNext)
        upNext = Array(rows.prefix(Self.upNextLimit))
        rate = try container.decode(Double.self, forKey: .rate)
        sleep = try container.decode(SleepState.self, forKey: .sleep)
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
    }
}
