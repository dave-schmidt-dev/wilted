import Foundation
import WiltedDomain

/// Append-only request from a follower device to the library's single writer.
///
/// `id` is the idempotency key: the writer applies each id at most once.
public struct LibraryIntent: Codable, Sendable, Equatable, Identifiable {
    public enum Action: Codable, Sendable, Equatable {
        /// Ask the Mac to make audio for `entryID` available to this device.
        case requestMedia(entryID: ItemID)
        /// This device verified and cached the audio for one revision, so the Mac may stop
        /// holding it once every requester has said so. `deviceID` is the acknowledging device.
        case mediaCached(entryID: ItemID, revisionID: RevisionID, deviceID: String)
        /// Keep a new episode: the Mac's feed Keep (queue it and download).
        case keep(entryID: ItemID)
        /// Skip a new episode: the Mac's feed Skip.
        case skip(entryID: ItemID)
        /// Mark a started Larder episode done (the Larder skip).
        case markDone(entryID: ItemID)
        /// Bring a retired entry back.
        case restore(entryID: ItemID)
        /// Move a queued entry to just after `afterEntryID`; nil moves it to the front. The Mac
        /// converts this entry-relative request to its own index-based queue move.
        case reorder(entryID: ItemID, afterEntryID: ItemID?)

        /// The entry this action is about.
        public var entryID: ItemID {
            switch self {
            case let .requestMedia(entryID), let .mediaCached(entryID, _, _), let .keep(entryID), let .skip(entryID),
                 let .markDone(entryID), let .restore(entryID), let .reorder(entryID, _):
                return entryID
            }
        }

        /// True for the decision actions the Mac answers with an `IntentOutcome`.
        public var isDecision: Bool {
            switch self {
            case .keep, .skip, .markDone, .restore, .reorder: return true
            case .requestMedia, .mediaCached: return false
            }
        }
    }

    public let id: String
    public let deviceID: String
    public let createdAt: Date
    public let action: Action

    public init(id: String, deviceID: String, createdAt: Date, action: Action) throws {
        guard !id.isEmpty else { throw DomainError.invalidValue(field: "id", reason: "must not be empty") }
        guard !deviceID.isEmpty else { throw DomainError.invalidValue(field: "deviceID", reason: "must not be empty") }
        if case let .reorder(entryID, after) = action, after == entryID {
            throw DomainError.invalidValue(field: "afterEntryID", reason: "an entry cannot be placed after itself")
        }
        self.id = id
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.action = action
    }

    /// Request for media with a fresh idempotency id.
    public static func requestMedia(
        entryID: ItemID,
        deviceID: String,
        createdAt: Date = Date(),
        id: String = UUID().uuidString
    ) throws -> LibraryIntent {
        try LibraryIntent(id: id, deviceID: deviceID, createdAt: createdAt, action: .requestMedia(entryID: entryID))
    }

    /// Acknowledgement that `deviceID` cached `revisionID` of `entryID`, with a fresh idempotency id.
    public static func mediaCached(
        entryID: ItemID,
        revisionID: RevisionID,
        deviceID: String,
        createdAt: Date = Date(),
        id: String = UUID().uuidString
    ) throws -> LibraryIntent {
        try LibraryIntent(
            id: id, deviceID: deviceID, createdAt: createdAt,
            action: .mediaCached(entryID: entryID, revisionID: revisionID, deviceID: deviceID)
        )
    }

    /// A decision intent with a fresh idempotency id and creation time.
    public static func keep(entryID: ItemID, deviceID: String, createdAt: Date = Date(), id: String = UUID().uuidString) throws -> LibraryIntent {
        try LibraryIntent(id: id, deviceID: deviceID, createdAt: createdAt, action: .keep(entryID: entryID))
    }

    public static func skip(entryID: ItemID, deviceID: String, createdAt: Date = Date(), id: String = UUID().uuidString) throws -> LibraryIntent {
        try LibraryIntent(id: id, deviceID: deviceID, createdAt: createdAt, action: .skip(entryID: entryID))
    }

    public static func markDone(entryID: ItemID, deviceID: String, createdAt: Date = Date(), id: String = UUID().uuidString) throws -> LibraryIntent {
        try LibraryIntent(id: id, deviceID: deviceID, createdAt: createdAt, action: .markDone(entryID: entryID))
    }

    public static func restore(entryID: ItemID, deviceID: String, createdAt: Date = Date(), id: String = UUID().uuidString) throws -> LibraryIntent {
        try LibraryIntent(id: id, deviceID: deviceID, createdAt: createdAt, action: .restore(entryID: entryID))
    }

    public static func reorder(
        entryID: ItemID, afterEntryID: ItemID?, deviceID: String, createdAt: Date = Date(), id: String = UUID().uuidString
    ) throws -> LibraryIntent {
        try LibraryIntent(id: id, deviceID: deviceID, createdAt: createdAt, action: .reorder(entryID: entryID, afterEntryID: afterEntryID))
    }

    private enum CodingKeys: String, CodingKey { case id, deviceID, createdAt, action }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            deviceID: c.decode(String.self, forKey: .deviceID),
            createdAt: c.decode(Date.self, forKey: .createdAt),
            action: c.decode(Action.self, forKey: .action)
        )
    }
}

/// The Mac's answer to one intent. Only the library writer publishes outcomes; a follower
/// reads them to confirm or roll back what it showed optimistically. An outcome is immutable:
/// the first one published for an intent id stands.
public struct IntentOutcome: Codable, Sendable, Equatable {
    public enum Disposition: String, Codable, Sendable { case applied, rejected }

    /// Reasons the Mac gives; a reader treats any other text as an opaque rejection.
    public static let reasonExpired = "expired"
    public static let reasonUnknownEntry = "unknownEntry"
    public static let reasonNotApplicable = "notApplicable"
    public static let reasonFailed = "failed"

    public let intentID: String
    /// The device that sent the intent, so it finds its outcomes by its own name.
    public let deviceID: String
    public let disposition: Disposition
    /// Present exactly when `disposition` is `.rejected`.
    public let reason: String?
    public let decidedAt: Date

    public var isApplied: Bool { disposition == .applied }

    public init(intentID: String, deviceID: String, disposition: Disposition, reason: String? = nil, decidedAt: Date) throws {
        guard !intentID.isEmpty else { throw DomainError.invalidValue(field: "intentID", reason: "must not be empty") }
        guard !deviceID.isEmpty else { throw DomainError.invalidValue(field: "deviceID", reason: "must not be empty") }
        switch disposition {
        case .applied:
            guard reason == nil else { throw DomainError.invalidValue(field: "reason", reason: "an applied outcome has no reason") }
        case .rejected:
            guard let reason, !reason.isEmpty else { throw DomainError.invalidValue(field: "reason", reason: "a rejection needs a reason") }
        }
        self.intentID = intentID
        self.deviceID = deviceID
        self.disposition = disposition
        self.reason = reason
        self.decidedAt = decidedAt
    }

    public static func applied(for intent: LibraryIntent, at decidedAt: Date = Date()) throws -> IntentOutcome {
        try IntentOutcome(intentID: intent.id, deviceID: intent.deviceID, disposition: .applied, decidedAt: decidedAt)
    }

    public static func rejected(for intent: LibraryIntent, reason: String, at decidedAt: Date = Date()) throws -> IntentOutcome {
        try IntentOutcome(intentID: intent.id, deviceID: intent.deviceID, disposition: .rejected, reason: reason, decidedAt: decidedAt)
    }

    private enum CodingKeys: String, CodingKey { case intentID, deviceID, disposition, reason, decidedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            intentID: c.decode(String.self, forKey: .intentID),
            deviceID: c.decode(String.self, forKey: .deviceID),
            disposition: c.decode(Disposition.self, forKey: .disposition),
            reason: c.decodeIfPresent(String.self, forKey: .reason),
            decidedAt: c.decode(Date.self, forKey: .decidedAt)
        )
    }
}

/// When an intent stops being worth applying, and when a phone may forget one.
public enum IntentRetention {
    /// The Mac rejects an intent older than this without applying it.
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    public static func isExpired(_ intent: LibraryIntent, now: Date) -> Bool {
        now.timeIntervalSince(intent.createdAt) > maximumAge
    }

    /// The rejection the Mac publishes for an expired decision intent, or nil while it is still live.
    public static func expiryOutcome(for intent: LibraryIntent, now: Date) throws -> IntentOutcome? {
        guard isExpired(intent, now: now) else { return nil }
        return try .rejected(for: intent, reason: IntentOutcome.reasonExpired, at: now)
    }

    /// The intents `deviceID` sent that have an outcome, which are the only ones it may delete.
    /// Age never qualifies an intent: without an outcome the phone keeps it until one arrives.
    public static func deletableIntents(_ intents: [LibraryIntent], deviceID: String, outcomes: [IntentOutcome]) -> [LibraryIntent] {
        let answered = Set(outcomes.filter { $0.deviceID == deviceID }.map(\.intentID))
        return intents.filter { $0.deviceID == deviceID && answered.contains($0.id) }
    }
}
