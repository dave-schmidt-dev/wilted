import Foundation

/// One timed word unit within a transcript cue, carrying second-resolution
/// timing from speech-to-text alignment and optional source token details.
public struct TranscriptWord: Codable, Equatable, Sendable {
    public static let maximumTextUTF8Bytes = 1_024

    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let rawText: String?

    public init(
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        rawText: String? = nil
    ) throws {
        guard startSeconds.isFinite, endSeconds.isFinite else {
            throw DomainError.invalidValue(field: "transcriptWord.time", reason: "must be finite")
        }
        guard startSeconds >= 0 else {
            throw DomainError.invalidValue(field: "transcriptWord.startSeconds", reason: "must not be negative")
        }
        guard endSeconds >= startSeconds else {
            throw DomainError.invalidValue(field: "transcriptWord.endSeconds", reason: "must not precede startSeconds")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DomainError.invalidValue(field: "transcriptWord.text", reason: "must not be empty")
        }
        guard trimmed.utf8.count <= Self.maximumTextUTF8Bytes else {
            throw DomainError.invalidValue(field: "transcriptWord.text", reason: "exceeds the 1024-byte limit")
        }
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = trimmed

        if let raw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard raw.utf8.count <= Self.maximumTextUTF8Bytes else {
                throw DomainError.invalidValue(field: "transcriptWord.rawText", reason: "exceeds the 1024-byte limit")
            }
            self.rawText = raw
        } else {
            self.rawText = nil
        }
    }

    private enum CodingKeys: CodingKey {
        case startSeconds, endSeconds, text, rawText, token, tokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            startSeconds: container.decode(Double.self, forKey: .startSeconds),
            endSeconds: container.decode(Double.self, forKey: .endSeconds),
            text: container.decode(String.self, forKey: .text),
            rawText: container.decodeIfPresent(String.self, forKey: .rawText)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startSeconds, forKey: .startSeconds)
        try container.encode(endSeconds, forKey: .endSeconds)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(rawText, forKey: .rawText)
    }
}
