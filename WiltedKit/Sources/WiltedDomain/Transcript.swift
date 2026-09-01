import Foundation

/// The durable state of transcript content for one immutable audio revision.
public enum TranscriptAvailability: String, Codable, CaseIterable, Sendable {
    case absent
    case available
    case stale
    case oversized
    case malformed
}

/// The text representation stored and synced by the transcript contract.
public enum TranscriptFormat: String, Codable, CaseIterable, Sendable {
    case plainText = "text/plain"
}

/// Where a transcript's cue timing came from.
///
/// This is a provenance field, not a formatting hint. A publisher's WebVTT and
/// our own speech-to-text both produce real timing measured against real audio;
/// a paragraph split with a words-per-minute guess does not, and must never be
/// presented as a reading position or used to cut audio. Anything without
/// evidence of timing is `none` and carries no cues at all.
public enum TranscriptTiming: String, Codable, CaseIterable, Sendable {
    /// Plain text only. Every schema-version-1 record, and every transcript
    /// whose source published no usable timing.
    case none
    /// The feed's own timed transcript (WebVTT, SRT, or podcast JSON).
    case published
    /// Produced by Wilted's speech-to-text against this exact audio revision.
    case aligned
}

/// One timed span of transcript text, in seconds from the start of the audio
/// revision the transcript is bound to.
///
/// Cues are bound to a `RevisionID`, so cutting audio produces a new revision
/// with its own remapped cues rather than invalidating these in place.
public struct TranscriptCue: Codable, Equatable, Sendable {
    public static let maximumTextUTF8Bytes = 8_192

    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) throws {
        guard startSeconds.isFinite, endSeconds.isFinite else {
            throw DomainError.invalidValue(field: "transcriptCue.time", reason: "must be finite")
        }
        guard startSeconds >= 0 else {
            throw DomainError.invalidValue(field: "transcriptCue.startSeconds", reason: "must not be negative")
        }
        guard endSeconds >= startSeconds else {
            throw DomainError.invalidValue(field: "transcriptCue.endSeconds", reason: "must not precede startSeconds")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DomainError.invalidValue(field: "transcriptCue.text", reason: "must not be empty")
        }
        guard trimmed.utf8.count <= Self.maximumTextUTF8Bytes else {
            throw DomainError.invalidValue(field: "transcriptCue.text", reason: "exceeds the 8192-byte cue limit")
        }
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = trimmed
    }

    private enum CodingKeys: CodingKey {
        case startSeconds, endSeconds, text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            startSeconds: container.decode(Double.self, forKey: .startSeconds),
            endSeconds: container.decode(Double.self, forKey: .endSeconds),
            text: container.decode(String.self, forKey: .text)
        )
    }
}

/// A read-only transcript bound to Wilted's existing item and audio revision identity.
public struct Transcript: Codable, Equatable, Sendable {
    /// Version two adds `timing` and `cues`. Version-one records still decode:
    /// they carry no timing, which is exactly what `TranscriptTiming.none`
    /// means, so the upgrade needs no data rewrite.
    public static let currentSchemaVersion = 2
    public static let supportedSchemaVersions = 1...2
    public static let maximumTextUTF8Bytes = 500_000

    /// Cue ceilings, sized against real material rather than a round number.
    /// The longest feed in the 2026-08-31 survey is a three-hour TWiT episode;
    /// sentence-split speech-to-text puts that near 10,000 cues and 450 KB of
    /// encoded JSON. The limits leave headroom above that and still refuse a
    /// runaway transcript before it reaches the store or the sync transport.
    public static let maximumCueCount = 20_000
    public static let maximumCuesEncodedBytes = 1_000_000

    public let itemID: ItemID
    public let revisionID: RevisionID
    public let availability: TranscriptAvailability
    public let text: String?
    public let format: TranscriptFormat
    public let languageCode: String?
    public let timing: TranscriptTiming
    public let cues: [TranscriptCue]?
    public let updatedAt: Timestamp
    public let schemaVersion: Int

    public init(
        itemID: ItemID,
        revisionID: RevisionID,
        availability: TranscriptAvailability,
        text: String? = nil,
        format: TranscriptFormat = .plainText,
        languageCode: String? = nil,
        timing: TranscriptTiming = .none,
        cues: [TranscriptCue]? = nil,
        updatedAt: Timestamp,
        schemaVersion: Int = Transcript.currentSchemaVersion
    ) throws {
        guard Self.supportedSchemaVersions.contains(schemaVersion) else {
            throw DomainError.invalidValue(field: "transcript.schemaVersion", reason: "must be version 1 or 2")
        }
        if let languageCode {
            guard languageCode.utf8.count <= 35,
                  languageCode.range(of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
                throw DomainError.invalidValue(field: "transcript.languageCode", reason: "must be a BCP 47 language tag")
            }
        }
        switch availability {
        case .available, .stale:
            guard let text, !text.isEmpty else {
                throw DomainError.invalidValue(field: "transcript.text", reason: "must be present for available or stale content")
            }
            guard text.utf8.count <= Self.maximumTextUTF8Bytes else {
                throw DomainError.invalidValue(field: "transcript.text", reason: "exceeds the 500000-byte transport limit")
            }
        case .absent, .oversized, .malformed:
            guard text == nil else {
                throw DomainError.invalidValue(field: "transcript.text", reason: "must be absent for unavailable content")
            }
        }
        // Timing and cues are one fact stated twice, so they must agree. A
        // reader that trusts `timing` alone would otherwise scroll against
        // nothing, and cues with `none` timing would claim evidence they lack.
        switch (timing, cues) {
        case (.none, nil):
            break
        case (.none, .some):
            throw DomainError.invalidValue(field: "transcript.cues", reason: "must be absent when timing is none")
        case (_, nil):
            throw DomainError.invalidValue(field: "transcript.cues", reason: "must be present for timed content")
        case let (_, cues?):
            guard availability == .available || availability == .stale else {
                throw DomainError.invalidValue(field: "transcript.cues", reason: "must be absent for unavailable content")
            }
            guard !cues.isEmpty else {
                throw DomainError.invalidValue(field: "transcript.cues", reason: "must not be empty for timed content")
            }
            guard cues.count <= Self.maximumCueCount else {
                throw DomainError.invalidValue(field: "transcript.cues", reason: "exceeds the 20000-cue limit")
            }
            // Starts must not go backwards. Overlapping cues are tolerated
            // because published captions routinely overlap by design; a
            // reader picking the last cue whose start has passed still lands
            // on the right one.
            for (previous, next) in zip(cues, cues.dropFirst()) where next.startSeconds < previous.startSeconds {
                throw DomainError.invalidValue(field: "transcript.cues", reason: "must be ordered by startSeconds")
            }
            let encoded = try JSONEncoder().encode(cues)
            guard encoded.count <= Self.maximumCuesEncodedBytes else {
                throw DomainError.invalidValue(field: "transcript.cues", reason: "exceeds the 1000000-byte transport limit")
            }
        }
        self.itemID = itemID
        self.revisionID = revisionID
        self.availability = availability
        self.text = text
        self.format = format
        self.languageCode = languageCode
        self.timing = timing
        self.cues = cues
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: CodingKey {
        case itemID, revisionID, availability, text, format, languageCode, timing, cues, updatedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            itemID: container.decode(ItemID.self, forKey: .itemID),
            revisionID: container.decode(RevisionID.self, forKey: .revisionID),
            availability: container.decode(TranscriptAvailability.self, forKey: .availability),
            text: container.decodeIfPresent(String.self, forKey: .text),
            format: container.decode(TranscriptFormat.self, forKey: .format),
            languageCode: container.decodeIfPresent(String.self, forKey: .languageCode),
            timing: container.decodeIfPresent(TranscriptTiming.self, forKey: .timing) ?? .none,
            cues: container.decodeIfPresent([TranscriptCue].self, forKey: .cues),
            updatedAt: container.decode(Timestamp.self, forKey: .updatedAt),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion)
        )
    }
}

public extension Transcript {
    /// The cue covering `seconds`, for a reader following the playback clock.
    ///
    /// Returns the last cue whose start has passed, which is the honest answer
    /// for overlapping published captions and for the gaps between cues where
    /// nothing is being said. Nil before the first cue starts, and nil for any
    /// transcript with no timing evidence.
    func cue(at seconds: Double) -> TranscriptCue? {
        guard let cues, seconds.isFinite else { return nil }
        var low = 0
        var high = cues.count - 1
        var found: TranscriptCue?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].startSeconds <= seconds {
                found = cues[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

/// Moves cues across a transport that carries bytes rather than structure.
///
/// Cue JSON is highly repetitive — two numbers and a key per line — so it
/// compresses several times over. That matters because a three-hour episode's
/// cues are the single largest thing a transcript record carries, and a
/// CloudKit record has a byte budget the plain text is already spending.
public enum TranscriptCueCodec {
    /// The ceiling applied to the decoded payload before it is parsed. It
    /// matches the contract's own cue limit, so a hostile or corrupt archive
    /// cannot expand past what a valid transcript could have written.
    public static let maximumDecodedBytes = Transcript.maximumCuesEncodedBytes

    public static func encode(_ cues: [TranscriptCue]) throws -> Data {
        let json = try JSONEncoder().encode(cues)
        guard json.count <= Transcript.maximumCuesEncodedBytes else {
            throw DomainError.invalidValue(field: "transcript.cues", reason: "exceeds the 1000000-byte transport limit")
        }
        return try (json as NSData).compressed(using: .zlib) as Data
    }

    public static func decode(_ payload: Data) throws -> [TranscriptCue] {
        guard !payload.isEmpty else {
            throw DomainError.invalidValue(field: "transcript.cues", reason: "payload is empty")
        }
        let json: Data
        do {
            json = try (payload as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw DomainError.invalidValue(field: "transcript.cues", reason: "payload is not zlib data")
        }
        guard json.count <= maximumDecodedBytes else {
            throw DomainError.invalidValue(field: "transcript.cues", reason: "decoded payload exceeds the 1000000-byte limit")
        }
        return try JSONDecoder().decode([TranscriptCue].self, from: json)
    }
}
