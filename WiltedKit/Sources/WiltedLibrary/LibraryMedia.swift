import Foundation
import WiltedDomain

/// Preparation-event provenance for the exact identity enclosing this proof.
/// Unknown versions are retained for compatibility but never authorize playback.
public struct LibraryMediaPreparation: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let preparedAt: Timestamp

    public init(schemaVersion: Int = 1, preparedAt: Timestamp) {
        self.schemaVersion = schemaVersion
        self.preparedAt = preparedAt
    }
}

/// The Mac's statement about audio for one entry: a verified, transferable file (`ready`),
/// audio the Mac has prepared but not uploaded (`available`), or the fact that no ready
/// revision exists (`notReady`). The Mac is the only writer of offers; a follower never
/// triggers preparation by asking, and asking an `available` entry is what triggers the upload.
public struct LibraryMediaOffer: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case ready, notReady
        /// Prepared on the Mac and queued, with no audio uploaded yet: revision, size, type and
        /// duration are known. Certified offers include the exact hash; legacy offers may have an empty hash. A reader may list it and request it, but
        /// cannot fetch it until the offer turns `ready`.
        case available

        /// A state this reader does not know degrades to `notReady`: nothing to fetch, no crash.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .notReady
        }
    }

    public let entryID: ItemID
    /// The revision the file belongs to. Nil only for `notReady`, where none exists.
    public let revisionID: RevisionID?
    /// `sha256:<64 lowercase hex>` of the exact bytes delivered; empty for `notReady`, and for
    /// legacy `available` offers without certification.
    public let contentHash: String
    public let byteCount: Int64
    public let mediaType: String
    public let durationSeconds: Double?
    public let state: State
    public let preparation: LibraryMediaPreparation?

    public init(
        entryID: ItemID,
        revisionID: RevisionID?,
        contentHash: String,
        byteCount: Int64,
        mediaType: String,
        durationSeconds: Double? = nil,
        state: State = .ready,
        preparation: LibraryMediaPreparation? = nil
    ) throws {
        if let durationSeconds {
            guard durationSeconds.isFinite, durationSeconds >= 0 else {
                throw DomainError.invalidValue(field: "durationSeconds", reason: "must be finite and non-negative")
            }
        }
        if state == .ready || state == .available {
            guard revisionID != nil else {
                throw DomainError.invalidValue(field: "revisionID", reason: "a ready or available offer needs a revision")
            }
            // Legacy hashless available offers remain decodable, but cannot be certified.
            guard MediaHash.isWellFormed(contentHash) || (state == .available && contentHash.isEmpty) else {
                throw DomainError.invalidValue(field: "contentHash", reason: "must be sha256:<64 lowercase hex>")
            }
            guard byteCount > 0 else {
                throw DomainError.invalidValue(field: "byteCount", reason: "must be positive")
            }
            guard !mediaType.isEmpty else {
                throw DomainError.invalidValue(field: "mediaType", reason: "must not be empty")
            }
        }
        self.entryID = entryID
        self.revisionID = revisionID
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.durationSeconds = durationSeconds
        self.state = state
        self.preparation = preparation
    }

    /// True when the audio is prepared on the Mac, whether or not it is uploaded yet.
    public var isPrepared: Bool {
        (state == .ready || state == .available) && preparation?.schemaVersion == 1
            && revisionID != nil && MediaHash.isWellFormed(contentHash) && byteCount > 0 && !mediaType.isEmpty
    }

    /// Offer stating that no ready audio exists for `entryID`.
    public static func notReady(entryID: ItemID) -> LibraryMediaOffer {
        LibraryMediaOffer(notReadyEntryID: entryID)
    }

    private init(notReadyEntryID entryID: ItemID) {
        self.entryID = entryID
        revisionID = nil
        contentHash = ""
        byteCount = 0
        mediaType = ""
        durationSeconds = nil
        state = .notReady
        preparation = nil
    }

    private enum CodingKeys: String, CodingKey {
        case entryID, revisionID, contentHash, byteCount, mediaType, durationSeconds, state, preparation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            entryID: c.decode(ItemID.self, forKey: .entryID),
            revisionID: c.decodeIfPresent(RevisionID.self, forKey: .revisionID),
            contentHash: c.decode(String.self, forKey: .contentHash),
            byteCount: c.decode(Int64.self, forKey: .byteCount),
            mediaType: c.decode(String.self, forKey: .mediaType),
            durationSeconds: c.decodeIfPresent(Double.self, forKey: .durationSeconds),
            state: c.decode(State.self, forKey: .state),
            preparation: try? c.decode(LibraryMediaPreparation.self, forKey: .preparation)
        )
    }
}

/// Why a media transfer ended without a cached file.
public enum MediaFailureReason: Sendable, Equatable {
    /// No progress for the whole watchdog interval.
    case timedOut
    case byteCountMismatch(expected: Int64, actual: Int64)
    case hashMismatch
    /// The transport delivered nothing usable, or the delivered file could not be read.
    case deliveryFailed(String)
    case cacheFailed(String)
}

/// One step of an on-demand media transfer as a UI sees it.
public enum MediaTransferState: Sendable, Equatable {
    /// The intent was sent; the Mac has not answered.
    case requested
    /// The offer is known and the fetch is about to start.
    case awaiting
    case downloading(bytes: Int64, total: Int64)
    case verifying
    case cached
    case failed(MediaFailureReason)
    /// The Mac has no ready audio for this entry.
    case notReady
}

/// Destination for verified media. Content is keyed by the offer, and `adopt` moves the
/// delivered file in; a partial file must never be visible under a cached name.
public protocol MediaCacheStore: Sendable {
    /// The cached file for exactly this offer (entry, revision and hash), if present.
    func cachedFile(for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async -> URL?
    /// Atomically moves `verifiedFile` into the cache and returns its final location.
    /// Adopting an offer already cached keeps the existing file and discards `verifiedFile`.
    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async throws -> URL
    /// Rechecks the cache-issued owner and entry epoch before any cache effect.
    func permits(_ admission: MediaCacheAdmission, for offer: LibraryMediaOffer) async -> Bool
    /// Removes every cached revision of `entryID`.
    func remove(entryID: ItemID) async throws
}
