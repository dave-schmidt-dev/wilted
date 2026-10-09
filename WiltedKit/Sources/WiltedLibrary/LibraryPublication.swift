import Foundation

/// A writer's acknowledged library publication, observed independently of mirror equality.
/// The date describes the captured Mac operation, never a reader's fetch or cache commit.
public struct LibraryPublication: Codable, Equatable, Sendable {
    public let id: String
    public let publishedAt: Date
    public let writerDeviceID: String

    public init(id: String, publishedAt: Date, writerDeviceID: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !writerDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryTransportError.transport("publication identity is empty")
        }
        guard publishedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryTransportError.transport("publication date is not finite")
        }
        self.id = id
        self.publishedAt = publishedAt
        self.writerDeviceID = writerDeviceID
    }

    private enum CodingKeys: String, CodingKey { case id, publishedAt, writerDeviceID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id),
                      publishedAt: values.decode(Date.self, forKey: .publishedAt),
                      writerDeviceID: values.decode(String.self, forKey: .writerDeviceID))
    }
}

/// Evidence from a completed fetch under an observed current owner. A nil provenance
/// remains unverifiable; a nil requested cursor alone never establishes a full bootstrap.
public struct LibraryFetchProvenance: Equatable, Sendable {
    public let ownerToken: String
    public let operationGeneration: UInt64
    public let isFullBootstrap: Bool

    public init(ownerToken: String, operationGeneration: UInt64, isFullBootstrap: Bool) {
        self.ownerToken = ownerToken
        self.operationGeneration = operationGeneration
        self.isFullBootstrap = isFullBootstrap
    }
}
