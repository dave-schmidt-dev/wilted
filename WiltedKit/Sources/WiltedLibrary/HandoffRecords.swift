import Foundation
import WiltedDomain

/// Safe cross-device playback diagnostics. Item identifiers are converted to a
/// domain-separated digest so the phone and Mac can join checkpoints without
/// writing the library's identifiers, account names, or device names to logs.
public enum PlaybackJournalSource: String, Sendable {
    case phone
    case mac
}

public enum PlaybackJournalEvent: String, CaseIterable, Sendable {
    case start
    case pause
    case routeLost = "route-lost"
    case interruptionBegan = "interruption-began"
    case interruptionEnded = "interruption-ended"
    case bulletinResume = "bulletin-resume"
    case pausePublished = "pause-published"
    case pauseQueued = "pause-queued"
    case takeover
    case relinquish
    case peerCheckpoint = "peer-checkpoint"
}

public enum PlaybackJournalCause: String, CaseIterable, Sendable {
    case explicit
    case routeLoss = "route-loss"
    case interruption
    case relinquish
    case replacement
    case naturalEnd = "natural-end"
    case audioSession = "audio-session"
    case engineRefused = "engine-refused"
    case playbackInactive = "playback-inactive"
    case higherEpoch = "higher-epoch"
}

public enum PlaybackJournalResult: String, CaseIterable, Sendable {
    case playing
    case paused
    case started
    case skipped
    case failed
    case published
    case pending
    case observed
    case relinquished
}

public enum PlaybackJournalPositionSource: String, Sendable {
    case zero
    case own
    case otherDevice = "other-device"
    case unknown
}

/// A structured playback boundary with only values approved for diagnostic output.
public struct PlaybackJournalRecord: Sendable, Equatable {
    public let source: PlaybackJournalSource
    public let event: PlaybackJournalEvent
    public let itemID: ItemID?
    public let positionSeconds: Double?
    public let epoch: Int?
    public let cause: PlaybackJournalCause?
    public let result: PlaybackJournalResult?
    public let positionSource: PlaybackJournalPositionSource?
    public let isPlaying: Bool?
    public let speechHeld: Bool?

    public init(
        source: PlaybackJournalSource,
        event: PlaybackJournalEvent,
        itemID: ItemID? = nil,
        positionSeconds: Double? = nil,
        epoch: Int? = nil,
        cause: PlaybackJournalCause? = nil,
        result: PlaybackJournalResult? = nil,
        positionSource: PlaybackJournalPositionSource? = nil,
        isPlaying: Bool? = nil,
        speechHeld: Bool? = nil
    ) {
        self.source = source
        self.event = event
        self.itemID = itemID
        self.positionSeconds = positionSeconds
        self.epoch = epoch
        self.cause = cause
        self.result = result
        self.positionSource = positionSource
        self.isPlaying = isPlaying
        self.speechHeld = speechHeld
    }

    /// Renders a single-line record that contains no raw item, account, or device identifier.
    public var line: String {
        var fields = ["schema=2", "source=\(source.rawValue)", "event=\(event.rawValue)"]
        if let itemID { fields.append("item=\(Self.itemTag(itemID))") }
        if let positionSeconds, positionSeconds.isFinite, positionSeconds >= 0 {
            fields.append("position=\(String(format: "%.1f", positionSeconds))")
        }
        if let epoch, epoch >= 0 { fields.append("epoch=\(epoch)") }
        if let cause { fields.append("cause=\(cause.rawValue)") }
        if let result { fields.append("result=\(result.rawValue)") }
        if let positionSource { fields.append("position-source=\(positionSource.rawValue)") }
        if let isPlaying { fields.append("playing=\(isPlaying)") }
        if let speechHeld { fields.append("speech-held=\(speechHeld)") }
        return fields.joined(separator: " ")
    }

    /// Public OSLog body. Detailed position and the joinable item tag stay in the owner-private file.
    public var publicLogLine: String {
        var fields = ["schema=2", "source=\(source.rawValue)", "event=\(event.rawValue)"]
        if let cause { fields.append("cause=\(cause.rawValue)") }
        if let result { fields.append("result=\(result.rawValue)") }
        return fields.joined(separator: " ")
    }

    /// Stable across the phone and Mac, but distinct from hashes used for media content.
    public static func itemTag(_ itemID: ItemID) -> String {
        let digest = MediaHash.sha256(text: "wilted-playback-item-v1|\(itemID.rawValue)")
        return "item-" + String(digest.dropFirst(MediaHash.prefix.count).prefix(20))
    }
}

/// Redacts the older free-form phone journal API before either durable or OS logging.
public enum PlaybackJournalPrivacy {
    private static let events: Set<String> = [
        "launch", "confirmation-cancelled", "confirmation-confirmed", "confirmation-asked",
        "bulletin-resume", "stop", "start", "play", "playback-stop", "audio-session",
        "remote-command", "start-request", "finished-here", "remote-resume", "voice-action",
        "decision-cancelled", "decision-applied", "decision-declined", "decision-forgotten",
        "decision-pending-on-mac", "decision-begun", "decision-sent", "decision-send-failed",
        "voice-action-outcome", "auto-continue"
    ]
    private static let stringValues: [String: Set<String>] = [
        "action": ["remember", "forget", "markDone", "markCompleted", "skip", "pick", "remove"],
        "command": ["play", "pause", "toggle", "next", "previous", "seek", "skip-back", "skip-forward"],
        "event": ["interruption-began", "interruption-ended", "route-lost"],
        "failure": ["audio-session", "engine-refused", "unreadable-file", "unknown"],
        "kind": ["toggle", "select", "continue-from-mac", "remote", "queue"],
        "outcome": ["started", "skipped", "failed", "handled", "done", "nothing-to-resume"],
        "position-source": ["zero", "own", "other-device", "mac", "phone", "unknown"],
        "reason": ["replaced", "pause", "interruption", "routeLost", "route-loss", "withdraw", "unload", "natural-end", "fail", "finished-here", "audio-session", "engine-refused", "playback-no-longer-active"],
        "pause-reason": ["direct", "interruption", "routeLost", "relinquish", "remote"],
        "result": ["handled", "failed", "resumed", "nothing-to-resume", "already-loaded", "start-under-way", "paused", "started"],
        "trigger": [
            "queue-removed", "remote", "finished-here", "explicit-stop", "eligibility-changed",
            "media-unavailable", "media-not-prepared", "media-revoked", "account-unavailable",
            "account-changed", "playback-admission-denied", "seek-admission-denied"
        ],
        "why": ["finished-here", "user"]
    ]
    private static let booleanKeys: Set<String> = [
        "autoplay", "loaded", "playback-intended", "engine-playing", "speech-hold",
        "should-resume", "resume-requested", "item-loaded", "silent", "sent"
    ]

    /// Keeps only known diagnostic fields, hashes item IDs, and removes all quoted free text.
    public static func sanitizeLegacyLine(_ line: String) -> String {
        let tokens = splitTokens(line)
        guard let requestedEvent = tokens.first else { return "event=unknown" }
        let event = events.contains(requestedEvent) ? requestedEvent : "event-unknown"
        var fields = ["schema=2", event]
        for token in tokens.dropFirst() {
            guard let separator = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<separator])
            let value = String(token[token.index(after: separator)...])
            guard !value.hasPrefix("\""), !value.contains("\""), !value.contains("\\") else { continue }
            if key == "entry" || key == "item" {
                guard value != "none", !value.isEmpty else { continue }
                guard let id = try? ItemID(rawValue: value) else { continue }
                fields.append("item=\(PlaybackJournalRecord.itemTag(id))")
            } else if key == "position", let number = Double(value), number.isFinite, number >= 0 {
                fields.append("position=\(String(format: "%.1f", number))")
            } else if key == "epoch", let number = Int(value), number >= 0 {
                fields.append("epoch=\(number)")
            } else if booleanKeys.contains(key), value == "true" || value == "false" {
                fields.append("\(key)=\(value)")
            } else if let choices = stringValues[key], choices.contains(value) {
                fields.append("\(key)=\(value)")
            } else if key == "build", value.utf8.count <= 16,
                      value.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }) {
                fields.append("build=\(value)")
            }
        }
        return fields.joined(separator: " ")
    }

    /// Reduces a safe version-2 file body to the content-free fields approved for public OSLog.
    public static func publicLogLine(from safeFileLine: String) -> String {
        let tokens = splitTokens(safeFileLine)
        let eventToken = tokens.first(where: { $0.hasPrefix("event=") }).map { String($0.dropFirst("event=".count)) }
            ?? tokens.first(where: { $0 != "schema=2" && !$0.contains("=") })
        let approvedEvents = events.union(PlaybackJournalEvent.allCases.map(\.rawValue))
        let event = eventToken.flatMap { approvedEvents.contains($0) ? $0 : nil } ?? "event-unknown"
        let source = tokens.first(where: { $0.hasPrefix("source=") })
            .map { String($0.dropFirst("source=".count)) } ?? "phone"
        var fields = ["schema=2", "source=\(source)", "event=\(event)"]
        for (sourceKey, outputKey) in [("cause", "cause"), ("reason", "cause"), ("pause-reason", "cause"), ("outcome", "result"), ("result", "result")] {
            guard let token = tokens.first(where: { $0.hasPrefix(sourceKey + "=") }),
                  let value = token.split(separator: "=", maxSplits: 1).last else { continue }
            let choices = stringValues[sourceKey]
                ?? (outputKey == "cause" ? Set(PlaybackJournalCause.allCases.map(\.rawValue)) : Set(PlaybackJournalResult.allCases.map(\.rawValue)))
            let field = "\(outputKey)=\(value)"
            if choices.contains(String(value)), !fields.contains(field) { fields.append(field) }
        }
        return fields.joined(separator: " ")
    }

    private static func splitTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quoted {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                current.append(character)
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// Playback position written by exactly one device (single writer per record).
public struct DevicePlaybackPosition: Codable, Sendable, Equatable {
    public let deviceID: String
    public let entryID: ItemID
    public let revision: RevisionID
    public let positionSeconds: Double
    /// Playback rate; 1 is normal speed.
    public let rate: Double
    public let isPlaying: Bool
    /// Handoff epoch; a takeover sets it to the maximum seen plus one.
    public let epoch: Int
    /// The publishing device's own clock when it wrote the record. Absent on records from
    /// older builds. A reader compares it with the server modification date to derive that
    /// device's clock offset.
    public let publishedAt: Date?

    public init(
        deviceID: String,
        entryID: ItemID,
        revision: RevisionID,
        positionSeconds: Double,
        rate: Double = 1,
        isPlaying: Bool,
        epoch: Int,
        publishedAt: Date? = nil
    ) throws {
        guard !deviceID.isEmpty else { throw DomainError.invalidValue(field: "deviceID", reason: "must not be empty") }
        guard positionSeconds.isFinite, positionSeconds >= 0 else {
            throw DomainError.invalidValue(field: "positionSeconds", reason: "must be finite and non-negative")
        }
        guard rate.isFinite, rate > 0 else {
            throw DomainError.invalidValue(field: "rate", reason: "must be finite and positive")
        }
        guard epoch >= 0 else { throw DomainError.invalidValue(field: "epoch", reason: "must be non-negative") }
        self.deviceID = deviceID
        self.entryID = entryID
        self.revision = revision
        self.positionSeconds = positionSeconds
        self.rate = rate
        self.isPlaying = isPlaying
        self.epoch = epoch
        self.publishedAt = publishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, entryID, revision, positionSeconds, rate, isPlaying, epoch, publishedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            deviceID: c.decode(String.self, forKey: .deviceID),
            entryID: c.decode(ItemID.self, forKey: .entryID),
            revision: c.decode(RevisionID.self, forKey: .revision),
            positionSeconds: c.decode(Double.self, forKey: .positionSeconds),
            rate: c.decode(Double.self, forKey: .rate),
            isPlaying: c.decode(Bool.self, forKey: .isPlaying),
            epoch: c.decode(Int.self, forKey: .epoch),
            publishedAt: c.decodeIfPresent(Date.self, forKey: .publishedAt)
        )
    }
}

/// The one record per device describing what it is playing now.
public typealias NowPlayingRecord = DevicePlaybackPosition

/// Per-entry, per-device position record.
public typealias ProgressRecord = DevicePlaybackPosition

/// A record together with the server modification date the transport observed.
public struct ObservedPlayback: Sendable, Equatable {
    public let record: DevicePlaybackPosition
    public let serverModifiedAt: Date

    public init(record: DevicePlaybackPosition, serverModifiedAt: Date) {
        self.record = record
        self.serverModifiedAt = serverModifiedAt
    }
}
