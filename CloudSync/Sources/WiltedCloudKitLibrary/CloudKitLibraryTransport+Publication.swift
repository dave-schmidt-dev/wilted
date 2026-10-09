import CloudKit
import Foundation
import WiltedLibrary

extension CloudKitLibraryTransport {
    /// Saves a dedicated author receipt only after an exact named-record acknowledgement.
    public func publishPublication(_ publication: LibraryPublication) async throws {
        guard isLibraryWriter, publication.writerDeviceID == deviceID else {
            throw LibraryTransportError.ownershipViolation("only the library writer may publish a receipt")
        }
        let generation = operationGenerationValue
        try await observeCurrentOwner(generation: generation)
        let owner = observedOwnerToken
        try await write(name: mapper.publicationRecordID.recordName, conflictIsSuccess: false, context: (generation, owner)) { base in
            try self.mapper.record(publication: publication, existing: base)
        }
        try await observeCurrentOwner(generation: generation)
        try verifyFetchContext(generation: generation, owner: owner)
    }

    /// Named author observation; nil when absent or malformed. It says nothing about mirror equality.
    public func readPublication() async throws -> LibraryPublication? {
        let generation = operationGenerationValue
        try await observeCurrentOwner(generation: generation)
        let owner = observedOwnerToken
        let records = try await fetchPresent([mapper.publicationRecordID])
        try await observeCurrentOwner(generation: generation)
        try verifyFetchContext(generation: generation, owner: owner)
        for record in records {
            if case let .publication(value)? = try? mapper.decode(record) { return value }
        }
        return nil
    }
}
