import CoreFoundation
import CryptoKit
import Foundation
import WiltedDomain

/// A literal, bounded timing and wording hint for one recurring feed slot.
public struct PodcastAdProfileSlot: Codable, Equatable, Hashable, Sendable {
    public enum Position: String, Codable, Hashable, Sendable { case pre, mid, post }
    public let position: Position
    public let startBasisPoints: Int
    public let endBasisPoints: Int
    public let entryPhrases: [String]
    public let returnPhrases: [String]

    public init(position: Position, startBasisPoints: Int, endBasisPoints: Int,
                entryPhrases: [String], returnPhrases: [String]) {
        self.position = position
        self.startBasisPoints = startBasisPoints
        self.endBasisPoints = endBasisPoints
        self.entryPhrases = entryPhrases
        self.returnPhrases = returnPhrases
    }
}

/// A versioned profile encoded as the exact UTF-8 JSON string sent to the worker.
public struct PodcastAdProfileEnvelope: Codable, Equatable, Sendable {
    public let payload: String
    public let digest: String

    public init(payload: String, digest: String) {
        self.payload = payload
        self.digest = digest
    }

    /// Builds deterministic compact JSON and binds its exact bytes with SHA-256.
    public static func make(feedID: String, revision: Int, sampleCount: Int,
                            slots: [PodcastAdProfileSlot]) throws -> Self {
        let payload = PodcastAdProfilePayload(schemaVersion: 1, feedID: feedID, revision: revision,
                                              sampleCount: sampleCount, slots: slots)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(payload)
        guard bytes.count <= PodcastAdProfileValidation.maximumPayloadBytes,
              let string = String(data: bytes, encoding: .utf8),
              PodcastAdProfileValidation.valid(payload, expectedFeedID: feedID) else {
            throw PodcastAdProfileError.invalidEnvelope
        }
        return Self(payload: string, digest: Self.sha256(bytes))
    }

    /// Checks the exact bytes, schema, bounds, and feed binding before use.
    public func validatedPayload(expectedFeedID: String) -> PodcastAdProfilePayload? {
        guard payload.utf8.count <= PodcastAdProfileValidation.maximumPayloadBytes,
              digest == Self.sha256(Data(payload.utf8)),
              let bytes = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "feedID", "revision", "sampleCount", "slots"]),
              PodcastAdProfileValidation.jsonInteger(object["schemaVersion"]) == 1,
              let feedID = object["feedID"] as? String, feedID == expectedFeedID,
              let revision = PodcastAdProfileValidation.jsonInteger(object["revision"]),
              let sampleCount = PodcastAdProfileValidation.jsonInteger(object["sampleCount"]),
              let slotsRaw = object["slots"] as? [[String: Any]],
              slotsRaw.count <= PodcastAdProfileValidation.maximumSlots,
              slotsRaw.allSatisfy(PodcastAdProfileValidation.validSlotObject),
              let decoded = try? JSONDecoder().decode(PodcastAdProfilePayload.self, from: bytes),
              PodcastAdProfileValidation.valid(decoded, expectedFeedID: expectedFeedID),
              decoded.revision == revision, decoded.sampleCount == sampleCount else { return nil }
        return decoded
    }

    public static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Profile contents without storage or digest metadata.
public struct PodcastAdProfilePayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let feedID: String
    public let revision: Int
    public let sampleCount: Int
    public let slots: [PodcastAdProfileSlot]
}

/// Independent generic-classifier observations; never final recovered cuts.
public struct PodcastAdProfileObservation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let feedID: String
    public let episodeID: String
    public let sourceHash: String
    public let slots: [PodcastAdProfileSlot]

    public init(schemaVersion: Int = 1, feedID: String, episodeID: String, sourceHash: String,
                slots: [PodcastAdProfileSlot]) {
        self.schemaVersion = schemaVersion
        self.feedID = feedID
        self.episodeID = episodeID
        self.sourceHash = sourceHash
        self.slots = slots
    }

    public func isValid(feedID expectedFeedID: String, episodeID expectedEpisodeID: String,
                        sourceHash expectedSourceHash: String) -> Bool {
        guard schemaVersion == 1, feedID == expectedFeedID, episodeID == expectedEpisodeID,
              sourceHash == expectedSourceHash, sourceHash.range(of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression) != nil,
              let bytes = try? JSONEncoder().encode(self), bytes.count <= PodcastAdProfileValidation.maximumPayloadBytes,
              (try? ItemID(rawValue: feedID)) != nil, (try? ItemID(rawValue: episodeID)) != nil else { return false }
        return slots.count <= PodcastAdProfileValidation.maximumSlots && slots.allSatisfy(PodcastAdProfileValidation.valid)
    }
}

public struct PodcastAdProfileSnapshot: Sendable {
    public let subscriptionEpoch: Double
    public let envelope: PodcastAdProfileEnvelope?
}

public enum PodcastAdProfileError: Error, Equatable {
    case invalidEnvelope
    case storeUnavailable
    case storeTooLarge
    case feedLimitReached
    case inactiveSubscription
}

enum PodcastAdProfileValidation {
    static let maximumPayloadBytes = 8 * 1_024
    static let maximumSlots = 12
    static let maximumPhrases = 8
    static let maximumPhraseCharacters = 120

    static func jsonInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let numericType = String(cString: number.objCType)
        guard !["f", "d"].contains(numericType) else { return nil }
        return Int(number.stringValue)
    }

    static func valid(_ payload: PodcastAdProfilePayload, expectedFeedID: String) -> Bool {
        payload.schemaVersion == 1 && payload.feedID == expectedFeedID
            && (try? ItemID(rawValue: payload.feedID)) != nil
            && payload.revision >= 1
            && (1...20).contains(payload.sampleCount)
            && payload.slots.count <= maximumSlots && payload.slots.allSatisfy(valid)
    }

    static func valid(_ slot: PodcastAdProfileSlot) -> Bool {
        (0...10_000).contains(slot.startBasisPoints)
            && (0...10_000).contains(slot.endBasisPoints)
            && slot.startBasisPoints < slot.endBasisPoints
            && slot.entryPhrases.count <= maximumPhrases
            && slot.returnPhrases.count <= maximumPhrases
            && (slot.entryPhrases + slot.returnPhrases).allSatisfy(validLiteral)
    }

    static func validSlotObject(_ object: [String: Any]) -> Bool {
        guard Set(object.keys) == Set(["position", "startBasisPoints", "endBasisPoints", "entryPhrases", "returnPhrases"]),
              let position = object["position"] as? String,
              PodcastAdProfileSlot.Position(rawValue: position) != nil,
              let start = jsonInteger(object["startBasisPoints"]),
              let end = jsonInteger(object["endBasisPoints"]),
              let entry = object["entryPhrases"] as? [String],
              let returned = object["returnPhrases"] as? [String] else { return false }
        return valid(PodcastAdProfileSlot(position: PodcastAdProfileSlot.Position(rawValue: position)!,
                                          startBasisPoints: start, endBasisPoints: end,
                                          entryPhrases: entry, returnPhrases: returned))
    }

    private static func validLiteral(_ phrase: String) -> Bool {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              phrase.unicodeScalars.count <= maximumPhraseCharacters,
              phrase.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        let folded = phrase.lowercased()
        return !folded.contains("://") && !folded.contains("www.")
    }
}
