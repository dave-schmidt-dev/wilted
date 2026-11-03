import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// Reads only the transcript records named by `(itemID, revisionID)`.
    ///
    /// Missing transcripts are omitted. A corrupt requested record throws, matching the exact
    /// single-record playback-presentation read; unrelated transcript payloads are never decoded.
    public func transcripts(for revisions: [ItemID: RevisionID]) throws -> [ItemID: Transcript] {
        let requestedKeys = Set(revisions.map { "\($0.key.rawValue)|\($0.value.rawValue)" })
        guard !requestedKeys.isEmpty else { return [:] }
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>(
            predicate: #Predicate { requestedKeys.contains($0.id) }
        ))
        targetedTranscriptFetchCount += 1
        targetedTranscriptRowsRead += records.count
        var result: [ItemID: Transcript] = [:]
        for record in records {
            guard let itemID = try? ItemID(rawValue: record.itemID),
                  let revisionID = revisions[itemID], record.revisionID == revisionID.rawValue else { continue }
            transcriptDecodeAttemptCount += 1
            result[itemID] = try decodeTranscript(record)
        }
        return result
    }

    /// Preparation history rows for these dismissed episodes, decoding only their matching statuses.
    /// Scheduling markers are not preparation attempts, matching `preparationRuns()` semantics.
    public func preparationHistoryItemIDs(for itemIDs: [ItemID]) throws -> Set<ItemID> {
        let requested = Set(itemIDs.map(\.rawValue))
        guard !requested.isEmpty else { return [] }
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { requested.contains($0.itemID) }
        ))
        dismissedPreparationHistoryRowsRead += records.count
        let decoder = JSONDecoder()
        return Set(records.compactMap { record in
            guard !record.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix),
                  !record.requestID.hasPrefix(Self.resetPreparationRequestPrefix) else { return nil }
            preparationJournalDecodeAttemptCount += 1
            guard (try? decoder.decode(PreparationStatus.self, from: record.statusData)) != nil else { return nil }
            return try? ItemID(rawValue: record.itemID)
        })
    }
}
