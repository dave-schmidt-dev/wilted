import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// Capture dispatch before entering the actor; fetch/decode traces separately measure actor work.
    nonisolated public func transcript(for itemID: ItemID, revisionID: RevisionID) async throws -> Transcript? {
        let requestedAt = LocalLibraryStoreStageTrace.start()
        return try await readPlaybackTranscript(for: itemID, revisionID: revisionID, requestedAt: requestedAt)
    }

    /// Read-only transcript interface consumed by platform presentation layers.
    func readPlaybackTranscript(for itemID: ItemID, revisionID: RevisionID, requestedAt: ContinuousClock.Instant?) throws -> Transcript? {
        if let requestedAt { LocalLibraryStoreStageTrace.record(.transcriptActorAdmission, since: requestedAt) }
        let fetchTrace = LocalLibraryStoreStageTrace.start()
        let context = ModelContext(container)
        let id = "\(itemID.rawValue)|\(revisionID.rawValue)"
        var descriptor = FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        let record = try context.fetch(descriptor).first
        if let fetchTrace { LocalLibraryStoreStageTrace.record(.transcriptFetch, since: fetchTrace) }
        guard let record else { return nil }
        let decodeTrace = LocalLibraryStoreStageTrace.start()
        let transcript = try decodeTranscript(record)
        if let decodeTrace { LocalLibraryStoreStageTrace.record(.transcriptDecode, since: decodeTrace) }
        return transcript
    }

}
