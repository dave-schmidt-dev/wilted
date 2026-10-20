import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// One item's newest generation and, when it differs, the generation that
    /// proves its current Ready revision.
    typealias MaintenanceGeneration = (
        rows: [LocalLibrarySchemaV3Models.PreparationRecord],
        entries: [PreparationJournalEntry], itemID: ItemID
    )

    /// Newest rows used to name generations without decoding their bodies.
    static let maintenanceDiscoveryWindow = 64
    /// Ascending rows read around the outcome's `producedAt` when no window
    /// generation proves the Ready revision.
    static let maintenanceReadyProofAnchorRows = 32
    /// A generation is one pipeline run; this ceiling only stops a corrupt or
    /// externally written row set from materializing without bound.
    static let maintenanceGenerationRowCeiling = 4_096

    /// Parses `requestID|generation-S-A|event`; legacy or malformed ids name
    /// no generation.
    static func maintenanceGeneration(of rowID: String, requestID: String) -> PreparationAttemptIdentity? {
        let prefix = requestID + "|generation-"
        guard rowID.hasPrefix(prefix) else { return nil }
        let remainder = rowID.dropFirst(prefix.count)
        guard let boundary = remainder.firstIndex(of: "|") else { return nil }
        let parts = remainder[..<boundary].split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let sequence = Int(parts[0]), let attemptCount = Int(parts[1]) else { return nil }
        return try? PreparationAttemptIdentity(requestSequence: sequence, attemptCount: attemptCount)
    }

    /// Durable recovery markers, read by request-id prefix rather than by
    /// scanning the journal.
    func maintenanceInvalidationMarkers(
        in context: ModelContext
    ) throws -> [LocalLibrarySchemaV3Models.PreparationRecord] {
        let forced = Self.forcedRedownloadRequestPrefix
        let reset = Self.resetPreparationRequestPrefix
        let rows = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.requestID.starts(with: forced) || $0.requestID.starts(with: reset) }
        ))
        preparationMaintenanceRowsRead += rows.count
        return rows
    }

    /// Reads only the generations maintenance can act on: the newest and the
    /// one that proves the Ready revision. Discovery, each complete generation
    /// read and the anchored proof lookup are all row-bounded.
    func maintenanceCandidateGenerations(
        for itemID: ItemID, ticketAttempt: PreparationAttemptIdentity?,
        readyRevisionID: String?, currentOutcomeProducedAt: Date?,
        in context: ModelContext, decoder: JSONDecoder
    ) throws -> [MaintenanceGeneration] {
        let requestID = PodcastPreparationPipeline.requestID(for: itemID)
        var windowQuery = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.requestID == requestID },
            sortBy: [SortDescriptor(\.emittedAt, order: .reverse), SortDescriptor(\.id, order: .reverse)]
        )
        windowQuery.fetchLimit = Self.maintenanceDiscoveryWindow
        let windowRows = try context.fetch(windowQuery)
        preparationMaintenanceRowsRead += windowRows.count

        func decodedEntry(
            _ row: LocalLibrarySchemaV3Models.PreparationRecord
        ) -> (entry: PreparationJournalEntry, attempt: PreparationAttemptIdentity?)? {
            guard let status = try? decoder.decode(PreparationStatus.self, from: row.statusData),
                  let rowItemID = try? ItemID(rawValue: row.itemID) else { return nil }
            return (PreparationJournalEntry(id: row.id, itemID: rowItemID,
                                            requestID: row.requestID, status: status), status.attempt)
        }

        var cached: [PreparationAttemptIdentity?: MaintenanceGeneration] = [:]
        var absent = Set<PreparationAttemptIdentity?>()
        func completeRead(_ key: PreparationAttemptIdentity?) throws -> MaintenanceGeneration? {
            if let hit = cached[key] { return hit }
            if absent.contains(key) { return nil }
            var query: FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>
            if let key {
                let prefix = requestID + "|" + key.key + "|"
                query = FetchDescriptor(
                    predicate: #Predicate { $0.requestID == requestID && $0.id.starts(with: prefix) },
                    sortBy: [SortDescriptor(\.emittedAt, order: .reverse)]
                )
            } else {
                let boundPrefix = requestID + "|generation-"
                query = FetchDescriptor(
                    predicate: #Predicate { $0.requestID == requestID && $0.id.starts(with: boundPrefix) == false },
                    sortBy: [SortDescriptor(\.emittedAt, order: .reverse)]
                )
            }
            query.fetchLimit = Self.maintenanceGenerationRowCeiling
            let rows = try context.fetch(query)
            preparationMaintenanceRowsRead += rows.count
            var keptRows: [LocalLibrarySchemaV3Models.PreparationRecord] = []
            var entries: [PreparationJournalEntry] = []
            for row in rows {
                guard let decoded = decodedEntry(row), decoded.attempt == key else { continue }
                keptRows.append(row); entries.append(decoded.entry)
            }
            entries.sort(by: preparationEntryPrecedes)
            guard let first = entries.first else {
                absent.insert(key)
                return nil
            }
            let generation: MaintenanceGeneration = (keptRows, entries, first.itemID)
            cached[key] = generation
            return generation
        }

        func keyDescends(_ lhs: PreparationAttemptIdentity?, _ rhs: PreparationAttemptIdentity?) -> Bool {
            switch (lhs, rhs) {
            case let (left?, right?):
                if left.requestSequence != right.requestSequence {
                    return left.requestSequence > right.requestSequence
                }
                return left.attemptCount > right.attemptCount
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }

        var windowKeys = Set<PreparationAttemptIdentity>()
        var windowHasLegacy = false
        for row in windowRows {
            if let key = Self.maintenanceGeneration(of: row.id, requestID: requestID) {
                windowKeys.insert(key)
            } else { windowHasLegacy = true }
        }

        var candidateKeys = windowKeys
        if let ticketAttempt { candidateKeys.insert(ticketAttempt) }
        var newest: MaintenanceGeneration?
        var newestReads = 0
        for key in candidateKeys.sorted(by: keyDescends) {
            if newestReads >= 2 { break }
            let wasRead = cached[key] != nil || absent.contains(key)
            let generation = try completeRead(key)
            if !wasRead { newestReads += 1 }
            if let generation {
                newest = generation
                break
            }
        }
        if newest == nil, windowHasLegacy {
            newest = try completeRead(nil)
        }

        func proves(_ generation: MaintenanceGeneration) -> Bool {
            let terminal = generation.entries.last(where: { $0.status.terminal })?.status.terminalResult
            return terminal?.outcome == .succeeded && terminal?.revisionID?.rawValue == readyRevisionID
        }

        func windowGeneration(
            for key: PreparationAttemptIdentity?,
            rows: [LocalLibrarySchemaV3Models.PreparationRecord]
        ) -> MaintenanceGeneration? {
            var keptRows: [LocalLibrarySchemaV3Models.PreparationRecord] = []
            var entries: [PreparationJournalEntry] = []
            for row in rows {
                guard let decoded = decodedEntry(row), decoded.attempt == key else { continue }
                keptRows.append(row); entries.append(decoded.entry)
            }
            entries.sort(by: preparationEntryPrecedes)
            guard let first = entries.first else { return nil }
            return (keptRows, entries, first.itemID)
        }

        var readyProving: MaintenanceGeneration?
        if readyRevisionID != nil, let producedAt = currentOutcomeProducedAt {
            if let newest, proves(newest) {
                readyProving = newest
            } else {
                let windowByKey = Dictionary(grouping: windowRows) {
                    Self.maintenanceGeneration(of: $0.id, requestID: requestID)
                }
                for key in windowByKey.keys.sorted(by: keyDescends) {
                    guard let rows = windowByKey[key],
                          let generation = windowGeneration(for: key, rows: rows),
                          proves(generation) else { continue }
                    readyProving = try completeRead(key)
                    break
                }
                if readyProving == nil {
                    var anchorQuery = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
                        predicate: #Predicate { $0.requestID == requestID && $0.emittedAt >= producedAt },
                        sortBy: [SortDescriptor(\.emittedAt, order: .forward), SortDescriptor(\.id, order: .forward)]
                    )
                    anchorQuery.fetchLimit = Self.maintenanceReadyProofAnchorRows
                    let anchorRows = try context.fetch(anchorQuery)
                    preparationMaintenanceRowsRead += anchorRows.count
                    let anchorByKey = Dictionary(grouping: anchorRows) {
                        Self.maintenanceGeneration(of: $0.id, requestID: requestID)
                    }
                    for key in anchorByKey.keys.sorted(by: keyDescends) {
                        guard let rows = anchorByKey[key],
                              let generation = windowGeneration(for: key, rows: rows),
                              proves(generation) else { continue }
                        readyProving = try completeRead(key)
                        break
                    }
                }
            }
        }

        var result: [MaintenanceGeneration] = []
        var seen = Set<PreparationAttemptIdentity?>()
        if let newest, seen.insert(newest.entries.first?.status.attempt).inserted {
            result.append(newest)
        }
        if let readyProving, seen.insert(readyProving.entries.first?.status.attempt).inserted {
            result.append(readyProving)
        }
        return result
    }
}
