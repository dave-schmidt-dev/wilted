import Foundation

/// A versioned control message from the watch to the phone.
public struct WatchCommand: Codable, Equatable, Sendable {
    /// Version of the command wire format this build writes.
    public static let currentVersion = 1

    /// A control action the watch can ask the phone to perform.
    public enum Action: Equatable, Sendable {
        /// Play the queue row with the given episode.
        case playRow(episodeID: String)
        /// Toggle between play and pause.
        case toggle
        /// Skip forward by the standard interval.
        case skipForward
        /// Skip back by the standard interval.
        case skipBack
        /// Set the playback rate.
        case setRate(Double)
        /// Start a sleep timer of the given length.
        case startSleep(minutes: Int)
        /// Start a sleep timer that stops at the end of the current episode.
        case startSleepEndOfEpisode
        /// Cancel any running sleep timer.
        case cancelSleep
    }

    /// Version of the wire format this value uses.
    public let version: Int
    /// The action to perform.
    public let action: Action

    public init(version: Int = WatchCommand.currentVersion, action: Action) {
        self.version = version
        self.action = action
    }
}

extension WatchCommand.Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case episodeID
        case rate
        case minutes
    }

    private enum Kind: String, Codable {
        case playRow
        case toggle
        case skipForward
        case skipBack
        case setRate
        case startSleep
        case startSleepEndOfEpisode
        case cancelSleep
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .playRow:
            let episodeID = try container.decode(String.self, forKey: .episodeID)
            self = .playRow(episodeID: episodeID)
        case .toggle:
            self = .toggle
        case .skipForward:
            self = .skipForward
        case .skipBack:
            self = .skipBack
        case .setRate:
            let rate = try container.decode(Double.self, forKey: .rate)
            self = .setRate(rate)
        case .startSleep:
            let minutes = try container.decode(Int.self, forKey: .minutes)
            self = .startSleep(minutes: minutes)
        case .startSleepEndOfEpisode:
            self = .startSleepEndOfEpisode
        case .cancelSleep:
            self = .cancelSleep
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .playRow(episodeID):
            try container.encode(Kind.playRow, forKey: .type)
            try container.encode(episodeID, forKey: .episodeID)
        case .toggle:
            try container.encode(Kind.toggle, forKey: .type)
        case .skipForward:
            try container.encode(Kind.skipForward, forKey: .type)
        case .skipBack:
            try container.encode(Kind.skipBack, forKey: .type)
        case let .setRate(rate):
            try container.encode(Kind.setRate, forKey: .type)
            try container.encode(rate, forKey: .rate)
        case let .startSleep(minutes):
            try container.encode(Kind.startSleep, forKey: .type)
            try container.encode(minutes, forKey: .minutes)
        case .startSleepEndOfEpisode:
            try container.encode(Kind.startSleepEndOfEpisode, forKey: .type)
        case .cancelSleep:
            try container.encode(Kind.cancelSleep, forKey: .type)
        }
    }
}
