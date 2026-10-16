import Foundation
import WiltedDomain

/// Optional, producer-owned display contract for an entry's preparation progress.
///
/// It is presentation only: it never authorizes playback, media admission, or a phone
/// command, and an absent or malformed value leaves the entry fully usable. The Mac is
/// the only writer. Unknown versions, unknown states and out-of-bounds metadata decode as
/// absent so an older reader keeps the entry; an unknown bounded stage stays generic text.
/// `updatedAt` dates the last producer report, not a heartbeat or proof the Mac is
/// online. The producer reconciles attempts on restart and clears successful or
/// withdrawn work; readers must not derive media authority or liveness from it.
public struct LibraryPreparationStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case queued, active, failed, cancelled
    }

    public static let currentVersion = 1
    public static let maximumAttemptIDBytes = 128
    public static let maximumStageBytes = 64
    public static let maximumDetailBytes = 240

    public let version: Int
    public let attemptID: String
    public let state: State
    public let stage: String
    public let detail: String
    public let fraction: Double?
    public let updatedAt: Date
    public let revisionID: RevisionID?

    public init(
        version: Int = LibraryPreparationStatus.currentVersion,
        attemptID: String,
        state: State,
        stage: String,
        detail: String,
        fraction: Double? = nil,
        updatedAt: Date,
        revisionID: RevisionID? = nil
    ) throws {
        guard version == Self.currentVersion else {
            throw DomainError.invalidValue(field: "preparationStatus.version", reason: "must be \(Self.currentVersion)")
        }
        guard !attemptID.isEmpty, attemptID.utf8.count <= Self.maximumAttemptIDBytes else {
            throw DomainError.invalidValue(
                field: "preparationStatus.attemptID",
                reason: "must be nonempty and at most \(Self.maximumAttemptIDBytes) bytes"
            )
        }
        guard stage.utf8.count <= Self.maximumStageBytes else {
            throw DomainError.invalidValue(
                field: "preparationStatus.stage",
                reason: "must be at most \(Self.maximumStageBytes) bytes"
            )
        }
        guard detail.utf8.count <= Self.maximumDetailBytes else {
            throw DomainError.invalidValue(
                field: "preparationStatus.detail",
                reason: "must be at most \(Self.maximumDetailBytes) bytes"
            )
        }
        guard updatedAt.timeIntervalSince1970.isFinite else {
            throw DomainError.invalidValue(field: "preparationStatus.updatedAt", reason: "must be a finite date")
        }
        self.version = version
        self.attemptID = attemptID
        self.state = state
        self.stage = stage
        self.detail = detail
        self.fraction = Self.validFraction(fraction)
        self.updatedAt = updatedAt
        self.revisionID = revisionID
    }

    /// A fraction outside finite 0...1 is dropped, leaving the rest of the status valid.
    private static func validFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case version, attemptID, state, stage, detail, fraction, updatedAt, revisionID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The entry catches malformed status as a whole. Only a successfully
        // decoded numeric fraction outside the supported range becomes nil.
        let fraction = try c.decodeIfPresent(Double.self, forKey: .fraction)
        let revisionID = try c.decodeIfPresent(RevisionID.self, forKey: .revisionID)
        try self.init(
            version: c.decode(Int.self, forKey: .version),
            attemptID: c.decode(String.self, forKey: .attemptID),
            state: c.decode(State.self, forKey: .state),
            stage: c.decode(String.self, forKey: .stage),
            detail: c.decode(String.self, forKey: .detail),
            fraction: fraction,
            updatedAt: c.decode(Date.self, forKey: .updatedAt),
            revisionID: revisionID
        )
    }
}
