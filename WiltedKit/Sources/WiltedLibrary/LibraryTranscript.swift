import Foundation
import WiltedDomain

/// One timed span of a published transcript, in seconds from the start of the revision's audio.
public struct LibraryTranscriptCue: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    /// Who is speaking, when the Mac's transcript names anyone (an older Mac, or speech-to-text alone, sends none).
    /// Optional and absent from the JSON when nil, so an older reader ignores it and an older writer decodes to nil.
    public let speaker: String?

    public init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// The Mac's compact transcript for one prepared audio revision, as published to other devices.
///
/// The Mac is the only writer (W-INV-005); a phone reads it beside the audio and never derives
/// or re-times it. The value carries either timed `cues` or, when the Mac holds no timing
/// evidence, a `plainText` fallback, never both. The whole encoded value is capped at
/// `maximumEncodedBytes`; content past the cap is dropped from the end and `isTruncated` says so,
/// so a reader can tell a short transcript from a cut one.
///
/// It is bound to `revisionID` because cue times are only meaningful against that exact audio.
/// Unknown JSON keys are ignored and missing optional keys decode to their defaults, so a field
/// added later never breaks an older reader.
public struct LibraryTranscript: Codable, Equatable, Sendable {
    /// Cap on the JSON-encoded value (512 KB). A transcript that would exceed it is truncated.
    public static let maximumEncodedBytes = 512 * 1024

    public let entryID: ItemID
    public let revisionID: RevisionID
    /// Timed cues in start order; empty when the transcript is plain text.
    public let cues: [LibraryTranscriptCue]
    /// Untimed transcript text; nil when `cues` is non-empty.
    public let plainText: String?
    /// True when content was dropped to fit `maximumEncodedBytes`.
    public let isTruncated: Bool
    public let languageCode: String?

    /// Validating initializer. Throws when the content is empty, holds both cues and text, has an
    /// invalid cue, or encodes above the cap; use `capped(...)` to truncate instead of failing.
    public init(
        entryID: ItemID,
        revisionID: RevisionID,
        cues: [LibraryTranscriptCue] = [],
        plainText: String? = nil,
        isTruncated: Bool = false,
        languageCode: String? = nil
    ) throws {
        let text = plainText.flatMap { $0.isEmpty ? nil : $0 }
        guard cues.isEmpty != (text == nil) else {
            throw DomainError.invalidValue(field: "libraryTranscript", reason: "needs exactly one of cues or plain text")
        }
        for cue in cues {
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end >= cue.start,
                  !cue.text.isEmpty
            else { throw DomainError.invalidValue(field: "libraryTranscript.cues", reason: "a cue is invalid") }
        }
        for (previous, next) in zip(cues, cues.dropFirst()) where next.start < previous.start {
            throw DomainError.invalidValue(field: "libraryTranscript.cues", reason: "must be ordered by start")
        }
        self.entryID = entryID
        self.revisionID = revisionID
        self.cues = cues
        self.plainText = text
        self.isTruncated = isTruncated
        self.languageCode = languageCode
        guard (try? JSONEncoder().encode(self).count) ?? .max <= Self.maximumEncodedBytes else {
            throw DomainError.invalidValue(field: "libraryTranscript", reason: "exceeds the \(Self.maximumEncodedBytes)-byte cap")
        }
    }

    public var isTimed: Bool { !cues.isEmpty }

    /// The cue covering `seconds`: the last one whose start has passed. Nil before the first cue.
    public func cue(at seconds: Double) -> LibraryTranscriptCue? {
        guard seconds.isFinite else { return nil }
        var low = 0, high = cues.count - 1
        var found: LibraryTranscriptCue?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= seconds { found = cues[mid]; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    // MARK: Building within the cap

    /// Builds a transcript from timed cues (preferred) or plain text, truncating from the end to
    /// fit `maximumEncodedBytes`. Returns nil when there is nothing usable to publish.
    public static func capped(
        entryID: ItemID,
        revisionID: RevisionID,
        cues: [LibraryTranscriptCue] = [],
        plainText: String? = nil,
        languageCode: String? = nil
    ) -> LibraryTranscript? {
        let usable = cues.filter { !$0.text.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }
        let ordered = usable.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        if !ordered.isEmpty {
            let count = largestFit(in: ordered.count) { n in
                try? LibraryTranscript(entryID: entryID, revisionID: revisionID, cues: Array(ordered.prefix(n)),
                                       isTruncated: n < ordered.count, languageCode: languageCode)
            }
            guard count > 0 else { return nil }
            return try? LibraryTranscript(entryID: entryID, revisionID: revisionID, cues: Array(ordered.prefix(count)),
                                          isTruncated: count < ordered.count, languageCode: languageCode)
        }
        guard let plainText, !plainText.isEmpty else { return nil }
        let characters = Array(plainText)
        let count = largestFit(in: characters.count) { n in
            try? LibraryTranscript(entryID: entryID, revisionID: revisionID, plainText: String(characters.prefix(n)),
                                   isTruncated: n < characters.count, languageCode: languageCode)
        }
        guard count > 0 else { return nil }
        return try? LibraryTranscript(entryID: entryID, revisionID: revisionID, plainText: String(characters.prefix(count)),
                                      isTruncated: count < characters.count, languageCode: languageCode)
    }

    /// Maps the Mac's stored transcript for a prepared revision onto the wire value. Only an
    /// `available` transcript is published; timed cues are used when the store holds real timing
    /// evidence (`published` or `aligned`), otherwise the plain text is the fallback.
    public static func capped(entryID: ItemID, from transcript: Transcript) -> LibraryTranscript? {
        guard transcript.availability == .available else { return nil }
        let language = transcript.languageCode
        if transcript.timing != .none, let cues = transcript.cues, !cues.isEmpty {
            let mapped = cues.map { LibraryTranscriptCue(start: $0.startSeconds, end: $0.endSeconds, text: $0.text, speaker: $0.speaker) }
            return capped(entryID: entryID, revisionID: transcript.revisionID, cues: mapped, languageCode: language)
        }
        return capped(entryID: entryID, revisionID: transcript.revisionID, plainText: transcript.text, languageCode: language)
    }

    /// The largest `n` in `0...total` for which `build(n)` succeeds; encoded size only grows with `n`.
    private static func largestFit(in total: Int, _ build: (Int) -> LibraryTranscript?) -> Int {
        guard total > 0 else { return 0 }
        if build(total) != nil { return total }
        var low = 0, high = total - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if build(mid) != nil { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case entryID, revisionID, cues, plainText, truncated, languageCode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            entryID: c.decode(ItemID.self, forKey: .entryID),
            revisionID: c.decode(RevisionID.self, forKey: .revisionID),
            cues: c.decodeIfPresent([LibraryTranscriptCue].self, forKey: .cues) ?? [],
            plainText: c.decodeIfPresent(String.self, forKey: .plainText),
            isTruncated: c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false,
            languageCode: c.decodeIfPresent(String.self, forKey: .languageCode)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entryID, forKey: .entryID)
        try c.encode(revisionID, forKey: .revisionID)
        if !cues.isEmpty { try c.encode(cues, forKey: .cues) }
        try c.encodeIfPresent(plainText, forKey: .plainText)
        if isTruncated { try c.encode(true, forKey: .truncated) }
        try c.encodeIfPresent(languageCode, forKey: .languageCode)
    }
}
