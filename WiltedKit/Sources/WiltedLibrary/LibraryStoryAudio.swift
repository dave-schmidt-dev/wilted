import Foundation
import WiltedDomain

/// A completed article narration that is available only to the device that requested it.
/// The original article URL and extracted text are deliberately absent from this media value.
public struct LibraryStoryAudioOffer: Codable, Sendable, Equatable, Identifiable {
    public let requestID: String
    public let storyID: String
    public let requesterDeviceID: String
    public let voiceID: String
    public let voiceRevision: String
    public let audioRevision: RevisionID
    public let contentHash: String
    public let byteCount: Int64
    public let mediaType: String
    public let durationSeconds: Double

    public var id: String { requestID }

    private enum CodingKeys: String, CodingKey {
        case requestID, storyID, requesterDeviceID, voiceID, voiceRevision
        case audioRevision, contentHash, byteCount, mediaType, durationSeconds
    }

    public init(
        requestID: String,
        storyID: String,
        requesterDeviceID: String,
        voiceID: String,
        voiceRevision: String,
        audioRevision: RevisionID,
        contentHash: String,
        byteCount: Int64,
        mediaType: String,
        durationSeconds: Double
    ) throws {
        guard !requestID.isEmpty else {
            throw DomainError.invalidValue(field: "requestID", reason: "must not be empty")
        }
        guard !storyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              storyID.count <= 1_024 else {
            throw DomainError.invalidValue(field: "storyID", reason: "must be a valid headline story id")
        }
        guard !requesterDeviceID.isEmpty else {
            throw DomainError.invalidValue(field: "requesterDeviceID", reason: "must not be empty")
        }
        guard !voiceID.isEmpty, !voiceRevision.isEmpty else {
            throw DomainError.invalidValue(field: "voice", reason: "voice id and revision must not be empty")
        }
        guard MediaHash.isWellFormed(contentHash) else {
            throw DomainError.invalidValue(field: "contentHash", reason: "must be sha256:<64 lowercase hex>")
        }
        guard byteCount > 0 else {
            throw DomainError.invalidValue(field: "byteCount", reason: "must be positive")
        }
        guard mediaType == "audio/mp4" else {
            throw DomainError.invalidValue(field: "mediaType", reason: "story audio must be AAC in an MP4 container")
        }
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw DomainError.invalidValue(field: "durationSeconds", reason: "must be finite and positive")
        }
        self.requestID = requestID
        self.storyID = storyID
        self.requesterDeviceID = requesterDeviceID
        self.voiceID = voiceID
        self.voiceRevision = voiceRevision
        self.audioRevision = audioRevision
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.durationSeconds = durationSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: values.decode(String.self, forKey: .requestID),
            storyID: values.decode(String.self, forKey: .storyID),
            requesterDeviceID: values.decode(String.self, forKey: .requesterDeviceID),
            voiceID: values.decode(String.self, forKey: .voiceID),
            voiceRevision: values.decode(String.self, forKey: .voiceRevision),
            audioRevision: values.decode(RevisionID.self, forKey: .audioRevision),
            contentHash: values.decode(String.self, forKey: .contentHash),
            byteCount: values.decode(Int64.self, forKey: .byteCount),
            mediaType: values.decode(String.self, forKey: .mediaType),
            durationSeconds: values.decode(Double.self, forKey: .durationSeconds)
        )
    }
}

/// Phone-visible progress from the Mac for one immutable Listen next request.
public struct LibraryListenNextStatus: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case preparing, ready, failed, cancelled
    }

    /// Only safe, fixed causes cross devices. Article content and arbitrary server errors stay local.
    public enum Failure: String, Codable, Sendable {
        case unsafeArticle, unavailableStory, missingVoice, narrationFailed, transferFailed
    }

    public let requestID: String
    public let storyID: String
    public let requesterDeviceID: String
    public let phase: Phase
    public let statusRevision: UInt64
    public let updatedAt: Date
    public let voiceID: String?
    public let voiceRevision: String?
    public let audioOffer: LibraryStoryAudioOffer?
    public let failure: Failure?

    public var id: String { requestID }

    public init(
        requestID: String,
        storyID: String,
        requesterDeviceID: String,
        phase: Phase,
        statusRevision: UInt64,
        updatedAt: Date,
        voiceID: String? = nil,
        voiceRevision: String? = nil,
        audioOffer: LibraryStoryAudioOffer? = nil,
        failure: Failure? = nil
    ) throws {
        guard !requestID.isEmpty, !requesterDeviceID.isEmpty, !storyID.isEmpty else {
            throw DomainError.invalidValue(field: "request", reason: "request, story and device ids must not be empty")
        }
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DomainError.invalidValue(field: "updatedAt", reason: "must be finite")
        }
        guard (voiceID == nil) == (voiceRevision == nil) else {
            throw DomainError.invalidValue(field: "voice", reason: "id and revision must appear together")
        }
        guard phase == .failed ? failure != nil : failure == nil else {
            throw DomainError.invalidValue(field: "failure", reason: "must match the request phase")
        }
        if phase == .ready {
            guard let audioOffer,
                  audioOffer.requestID == requestID,
                  audioOffer.storyID == storyID,
                  audioOffer.requesterDeviceID == requesterDeviceID,
                  audioOffer.voiceID == voiceID,
                  audioOffer.voiceRevision == voiceRevision else {
                throw DomainError.invalidValue(field: "audioOffer", reason: "must identify the ready request and voice")
            }
        } else if audioOffer != nil {
            throw DomainError.invalidValue(field: "audioOffer", reason: "is only valid for a ready request")
        }
        self.requestID = requestID
        self.storyID = storyID
        self.requesterDeviceID = requesterDeviceID
        self.phase = phase
        self.statusRevision = statusRevision
        self.updatedAt = updatedAt
        self.voiceID = voiceID
        self.voiceRevision = voiceRevision
        self.audioOffer = audioOffer
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, storyID, requesterDeviceID, phase, statusRevision, updatedAt
        case voiceID, voiceRevision, audioOffer, failure
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: values.decode(String.self, forKey: .requestID),
            storyID: values.decode(String.self, forKey: .storyID),
            requesterDeviceID: values.decode(String.self, forKey: .requesterDeviceID),
            phase: values.decode(Phase.self, forKey: .phase),
            statusRevision: values.decode(UInt64.self, forKey: .statusRevision),
            updatedAt: values.decode(Date.self, forKey: .updatedAt),
            voiceID: values.decodeIfPresent(String.self, forKey: .voiceID),
            voiceRevision: values.decodeIfPresent(String.self, forKey: .voiceRevision),
            audioOffer: values.decodeIfPresent(LibraryStoryAudioOffer.self, forKey: .audioOffer),
            failure: values.decodeIfPresent(Failure.self, forKey: .failure)
        )
    }
}

/// A durable local view of a Listen next request. This is never published as a CloudKit record.
public struct LibraryListenNextRequestSnapshot: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending, sent, preparing, ready, failed, cancelled, selected, playing, completed
    }

    public let requestID: String
    public let story: LibraryHeadlineStory
    public var storyID: String { story.id }
    public let requesterDeviceID: String
    public let ownerToken: String
    public let operationGeneration: UInt64
    public let anchorID: ItemID?
    public let createdAt: Date
    public let statusUpdatedAt: Date
    public let status: Status
    public let statusRevision: UInt64
    public let audioOffer: LibraryStoryAudioOffer?
    public let voiceID: String?
    public let voiceRevision: String?
    public let failure: LibraryListenNextStatus.Failure?

    public var id: String { requestID }
    public var isTerminal: Bool { status == .failed || status == .cancelled || status == .completed }
    public var isQueueable: Bool { status == .ready || status == .selected || status == .playing }

    private enum CodingKeys: String, CodingKey {
        case requestID, story, requesterDeviceID, ownerToken, operationGeneration, anchorID, createdAt
        case statusUpdatedAt, status, statusRevision, audioOffer, voiceID, voiceRevision, failure
    }

    public init(
        requestID: String,
        story: LibraryHeadlineStory,
        requesterDeviceID: String,
        ownerToken: String,
        operationGeneration: UInt64,
        anchorID: ItemID?,
        createdAt: Date,
        statusUpdatedAt: Date? = nil,
        status: Status,
        statusRevision: UInt64 = 0,
        audioOffer: LibraryStoryAudioOffer? = nil,
        voiceID: String? = nil,
        voiceRevision: String? = nil,
        failure: LibraryListenNextStatus.Failure? = nil
    ) throws {
        guard !requestID.isEmpty, !requesterDeviceID.isEmpty, !ownerToken.isEmpty else {
            throw DomainError.invalidValue(field: "request", reason: "ids and owner must not be empty")
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DomainError.invalidValue(field: "createdAt", reason: "must be finite")
        }
        let resolvedStatusUpdatedAt = statusUpdatedAt ?? createdAt
        guard resolvedStatusUpdatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DomainError.invalidValue(field: "statusUpdatedAt", reason: "must be finite")
        }
        guard (voiceID == nil) == (voiceRevision == nil) else {
            throw DomainError.invalidValue(field: "voice", reason: "id and revision must appear together")
        }
        if let audioOffer {
            guard audioOffer.requestID == requestID,
                  audioOffer.storyID == story.id,
                  audioOffer.requesterDeviceID == requesterDeviceID,
                  audioOffer.voiceID == voiceID,
                  audioOffer.voiceRevision == voiceRevision else {
                throw DomainError.invalidValue(field: "audioOffer", reason: "does not match the request")
            }
        }
        let requiresAudio = status == .ready || status == .selected || status == .playing || status == .completed
        guard requiresAudio == (audioOffer != nil) || (status == .cancelled && audioOffer != nil) else {
            throw DomainError.invalidValue(field: "audioOffer", reason: "must match the request's ready or terminal state")
        }
        guard status == .failed ? failure != nil : failure == nil else {
            throw DomainError.invalidValue(field: "failure", reason: "must match the request status")
        }
        self.requestID = requestID
        self.story = story
        self.requesterDeviceID = requesterDeviceID
        self.ownerToken = ownerToken
        self.operationGeneration = operationGeneration
        self.anchorID = anchorID
        self.createdAt = createdAt
        self.statusUpdatedAt = resolvedStatusUpdatedAt
        self.status = status
        self.statusRevision = statusRevision
        self.audioOffer = audioOffer
        self.voiceID = voiceID
        self.voiceRevision = voiceRevision
        self.failure = failure
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: values.decode(String.self, forKey: .requestID),
            story: values.decode(LibraryHeadlineStory.self, forKey: .story),
            requesterDeviceID: values.decode(String.self, forKey: .requesterDeviceID),
            ownerToken: values.decode(String.self, forKey: .ownerToken),
            operationGeneration: values.decode(UInt64.self, forKey: .operationGeneration),
            anchorID: values.decodeIfPresent(ItemID.self, forKey: .anchorID),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            statusUpdatedAt: values.decodeIfPresent(Date.self, forKey: .statusUpdatedAt),
            status: values.decode(Status.self, forKey: .status),
            statusRevision: values.decodeIfPresent(UInt64.self, forKey: .statusRevision) ?? 0,
            audioOffer: values.decodeIfPresent(LibraryStoryAudioOffer.self, forKey: .audioOffer),
            voiceID: values.decodeIfPresent(String.self, forKey: .voiceID),
            voiceRevision: values.decodeIfPresent(String.self, forKey: .voiceRevision),
            failure: values.decodeIfPresent(LibraryListenNextStatus.Failure.self, forKey: .failure)
        )
    }
}

/// Transfer operations for completed Listen next audio. Implementations must check the verified
/// library owner and exact offer identity on every operation. Fetches are bound to the current
/// device id, which must equal `offer.requesterDeviceID`.
public protocol LibraryStoryAudioTransport: Sendable {
    func publishStoryAudio(
        offer: LibraryStoryAudioOffer,
        fileURL: URL,
        expectedOwner: String
    ) async throws

    func fetchStoryAudio(
        _ offer: LibraryStoryAudioOffer,
        expectedOwner: String,
        progress: @escaping MediaProgressHandler
    ) async throws -> URL

    func removeStoryAudio(
        _ offer: LibraryStoryAudioOffer,
        expectedOwner: String
    ) async throws

    func publishListenNextStatus(_ status: LibraryListenNextStatus, expectedOwner: String) async throws

    func listenNextStatuses(
        requestIDs: Set<String>,
        expectedOwner: String
    ) async throws -> [LibraryListenNextStatus]
}
