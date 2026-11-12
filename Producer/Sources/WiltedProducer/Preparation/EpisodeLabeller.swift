import Foundation

/// One transcript line as the labelling model sees it.
public struct LabellerCue: Codable, Equatable, Sendable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: Int, start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

/// What kind of advertising a break is.
public enum LabelledBreakKind: String, Codable, Equatable, Sendable {
    case sponsor
    case networkPromo = "network-promo"
    case housePromo = "house-promo"
}

/// How confident the model is that a break should be cut.
public enum LabelledBreakLabel: String, Codable, Equatable, Sendable {
    case mustCut = "must-cut"
    case acceptableCut = "acceptable-cut"
}

/// A break the model returned that passed every check.
public struct LabelledBreak: Equatable, Sendable {
    public var kind: LabelledBreakKind
    public var label: LabelledBreakLabel
    public var advertisers: [String]
    public var startCue: Int
    public var endCue: Int
    /// The `start` of the start cue.
    public var startSeconds: Double
    /// The `end` of the end cue.
    public var endSeconds: Double

    public init(kind: LabelledBreakKind, label: LabelledBreakLabel, advertisers: [String],
                startCue: Int, endCue: Int, startSeconds: Double, endSeconds: Double) {
        self.kind = kind
        self.label = label
        self.advertisers = advertisers
        self.startCue = startCue
        self.endCue = endCue
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// Why one break was dropped while the rest of the reply was kept.
public enum RejectedBreakReason: String, Error, Equatable, Sendable {
    case unknownCueID = "unknown cue ID"
    case invertedRange = "inverted range"
    case tooLong = "longer than 600 s"
    case outsideEpisode = "outside the episode"
    case unknownKindOrLabel = "unknown kind or label"
}

/// A break dropped by validation, with the raw values the model sent.
public struct RejectedBreak: Equatable, Sendable {
    public var startSegment: Int
    public var endSegment: Int
    public var kind: String
    public var label: String
    public var advertisers: [String]
    public var reason: RejectedBreakReason

    public init(startSegment: Int, endSegment: Int, kind: String, label: String,
                advertisers: [String], reason: RejectedBreakReason) {
        self.startSegment = startSegment
        self.endSegment = endSegment
        self.kind = kind
        self.label = label
        self.advertisers = advertisers
        self.reason = reason
    }
}

/// A parsed labeller reply: accepted breaks plus the ones validation dropped.
public struct LabellerReply: Equatable, Sendable {
    public var breaks: [LabelledBreak]
    public var rejected: [RejectedBreak]

    public init(breaks: [LabelledBreak], rejected: [RejectedBreak]) {
        self.breaks = breaks
        self.rejected = rejected
    }
}

/// Why a labelling request produced no usable result.
public enum LabellerFailure: Error, Equatable, Sendable {
    case rateLimited(retryAfter: TimeInterval?)
    case temporary
    case keyRejected
    case modelUnavailable
    case usageLimit
    case unusableAnswer

    /// A stable short name for journals; carries no associated data.
    public var kind: String {
        switch self {
        case .rateLimited: "rate-limited"
        case .temporary: "temporary"
        case .keyRejected: "key-rejected"
        case .modelUnavailable: "model-unavailable"
        case .usageLimit: "usage-limit"
        case .unusableAnswer: "unusable-answer"
        }
    }
}

/// Builds the whole-episode labelling prompt and validates the model's reply.
public enum EpisodeLabeller {
    /// Identifies the exact prompt text; bump it whenever the text changes.
    public static let promptVersion = "labeller-prompt-v1"

    /// Longest break accepted, in seconds.
    static let maximumBreakSeconds = 600.0

    private static let instructionLines = [
        "You label advertising breaks in a podcast transcript. Do not use any tools; answer from the transcript below only.",
        "",
        "Each transcript line is `#<segment id> [<start seconds>-<end seconds>] <text>`. The show is: <SHOW TITLE>. Speech-to-text has errors and does not transcribe music.",
        "",
        "Find every advertising break in the whole episode. Advertising = third-party sponsor reads (including reads or skits voiced by the hosts), produced commercials, and promos for other shows or networks. Mark promotion of the show's own membership, merch or products as kind \"house-promo\". Not advertising: the show's own intro/outro, credits, listener participation, and ordinary discussion that merely names a product. A return to discussion after one sponsor may only introduce the next sponsor: check each break's end through the next call to action or a clear return to the show. An episode may have no advertising at all; then return an empty list.",
        "",
        "Reply with JSON only, no prose and no code fence:",
        "{\"breaks\":[{\"startSegment\":int,\"endSegment\":int,\"kind\":\"sponsor\"|\"network-promo\"|\"house-promo\",\"label\":\"must-cut\"|\"acceptable-cut\",\"advertisers\":[str]}]}",
        "One entry per contiguous break. Use \"must-cut\" only when the text clearly is advertising.",
        "",
        "TRANSCRIPT:",
    ]

    /// The full prompt: instructions, then one `#id [start-end] text` line per cue.
    public static func prompt(showTitle: String, cues: [LabellerCue]) -> String {
        let header = instructionLines.joined(separator: "\n")
            .replacingOccurrences(of: "<SHOW TITLE>", with: showTitle)
        let lines = cues.map { cue in
            "#\(cue.id) [\(seconds(cue.start))-\(seconds(cue.end))] "
                + cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return header + "\n" + lines.map { $0 + "\n" }.joined()
    }

    /// Parses and validates a model reply against the transcript cues.
    ///
    /// Anything other than one JSON object holding a `breaks` array is
    /// ``LabellerFailure/unusableAnswer``. Individual bad breaks are rejected
    /// and the rest kept.
    public static func parse(reply: String, cues: [LabellerCue],
                             duration: Double) -> Result<LabellerReply, LabellerFailure> {
        guard let data = unfenced(reply).data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .failure(.unusableAnswer)
        }
        var index: [Int: Int] = [:]
        for (position, cue) in cues.enumerated() where index[cue.id] == nil { index[cue.id] = position }

        var accepted: [LabelledBreak] = []
        var rejected: [RejectedBreak] = []
        for raw in envelope.breaks {
            switch validate(raw, cues: cues, index: index, duration: duration) {
            case .success(let value): accepted.append(value)
            case .failure(let reason):
                rejected.append(RejectedBreak(
                    startSegment: raw.startSegment, endSegment: raw.endSegment, kind: raw.kind,
                    label: raw.label, advertisers: raw.advertisers ?? [], reason: reason))
            }
        }
        return .success(LabellerReply(breaks: accepted, rejected: rejected))
    }

    // MARK: - Private

    private struct Envelope: Decodable {
        var breaks: [RawBreak]
    }

    private struct RawBreak: Decodable {
        var startSegment: Int
        var endSegment: Int
        var kind: String
        var label: String
        /// Optional so a reply that omits it is not thrown away whole.
        var advertisers: [String]?
    }

    private static func validate(_ raw: RawBreak, cues: [LabellerCue], index: [Int: Int],
                                 duration: Double) -> Result<LabelledBreak, RejectedBreakReason> {
        guard let startPosition = index[raw.startSegment], let endPosition = index[raw.endSegment] else {
            return .failure(.unknownCueID)
        }
        guard endPosition >= startPosition else { return .failure(.invertedRange) }
        let start = cues[startPosition].start
        let end = cues[endPosition].end
        guard end - start <= maximumBreakSeconds else { return .failure(.tooLong) }
        guard start >= 0, end <= duration else { return .failure(.outsideEpisode) }
        guard let kind = LabelledBreakKind(rawValue: raw.kind),
              let label = LabelledBreakLabel(rawValue: raw.label) else {
            return .failure(.unknownKindOrLabel)
        }
        return .success(LabelledBreak(
            kind: kind, label: label, advertisers: raw.advertisers ?? [], startCue: raw.startSegment,
            endCue: raw.endSegment, startSeconds: start, endSeconds: end))
    }

    /// Trims whitespace and removes one outer Markdown code fence, if present.
    private static func unfenced(_ reply: String) -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count >= 6 else { return trimmed }
        var body = String(trimmed.dropFirst(3).dropLast(3))
        if body.lowercased().hasPrefix("json") { body = String(body.dropFirst(4)) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
