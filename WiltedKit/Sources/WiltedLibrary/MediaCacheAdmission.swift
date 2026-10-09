import Foundation
import WiltedDomain

/// A cache-issued live permission, distinct from durable preparation provenance.
public struct MediaCacheAdmission: Sendable, Equatable {
    public let entryID: ItemID
    public let ownerToken: String
    public let libraryScope: String
    public let ownerEpoch: UUID
    public let entryRevocationEpoch: UInt64
    public let cacheGeneration: UUID
    public let transportGeneration: UInt64

    public init(entryID: ItemID, ownerToken: String, libraryScope: String, ownerEpoch: UUID,
                entryRevocationEpoch: UInt64, cacheGeneration: UUID, transportGeneration: UInt64) {
        self.entryID = entryID; self.ownerToken = ownerToken; self.libraryScope = libraryScope
        self.ownerEpoch = ownerEpoch; self.entryRevocationEpoch = entryRevocationEpoch
        self.cacheGeneration = cacheGeneration; self.transportGeneration = transportGeneration
    }
}
