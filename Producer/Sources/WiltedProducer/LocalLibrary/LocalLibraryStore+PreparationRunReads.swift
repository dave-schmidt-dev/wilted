import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    private struct PreparationRunReadCandidate {
        let key: String
        let requestID: String
        let attempt: PreparationAttemptIdentity?
        let latest: PreparationJournalEntry
    }

    private struct PreparationRunReadSelection {
        let candidates: [PreparationRunReadCandidate]
        let discoveredEntriesByID: [String: PreparationJournalEntry]
    }

    /// Builds full details only for the newest requested run identities.
    ///
    /// Identity discovery is newest-first and paged. Once identities are
    /// selected, one batched request-ID query loads their event rows; bound
    /// runs are filtered by attempt prefix before JSON decoding. The schema
    /// has no attempt index, so this reduces materialization and decoding but
    /// does not claim to remove SQLite scans.
    func preparationRunSummaries(limit: Int, in context: ModelContext) throws -> [PreparationRunSummary] {
        guard limit > 0 else { return [] }
        let selection = try recentPreparationRunCandidates(limit: limit, in: context)
        let candidates = selection.candidates
        guard !candidates.isEmpty else { return [] }

        let selectedByKey = Dictionary(uniqueKeysWithValues: candidates.map { ($0.key, $0) })
        var requestIDs = Set<String>()
        var legacyRequestIDs = Set<String>()
        var attemptKeysByRequest: [String: Set<String>] = [:]
        var requestPrefixesByRequest: [String: String] = [:]
        for candidate in candidates {
            requestIDs.insert(candidate.requestID)
            requestPrefixesByRequest[candidate.requestID] = candidate.requestID + "|"
            if let attempt = candidate.attempt {
                attemptKeysByRequest[candidate.requestID, default: []].insert(attempt.key)
            } else {
                legacyRequestIDs.insert(candidate.requestID)
            }
        }

        let decoder = JSONDecoder()
        var entriesByRun: [String: [PreparationJournalEntry]] = [:]
        for entry in selection.discoveredEntriesByID.values {
            let key = preparationRunIdentityKey(requestID: entry.requestID, attempt: entry.status.attempt)
            guard selectedByKey[key] != nil else { continue }
            entriesByRun[key, default: []].append(entry)
        }
        let pageSize = 256
        var pageOffset = 0
        while true {
            var query = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
                predicate: #Predicate { requestIDs.contains($0.requestID) },
                sortBy: [SortDescriptor(\.id, order: .forward)]
            )
            query.fetchOffset = pageOffset
            query.fetchLimit = pageSize
            let records = try context.fetch(query)
            preparationRunRowsRead += records.count
            preparationRunMaximumBatchRows = max(preparationRunMaximumBatchRows, records.count)
            guard !records.isEmpty else { break }
            pageOffset += records.count
            for record in records {
                let recordID = record.id
                let requestID = record.requestID
                guard !isPreparationMarker(requestID) else { continue }
                if let discovered = selection.discoveredEntriesByID[recordID] {
                    // Candidate discovery already decoded this immutable row
                    // in the same context. The selected-key filter above
                    // admitted it only after checking its decoded attempt.
                    guard discovered.requestID == requestID else { continue }
                    continue
                }
                let isLegacySelected = legacyRequestIDs.contains(requestID)
                if !isLegacySelected {
                    guard let attemptKeys = attemptKeysByRequest[requestID],
                          let requestPrefix = requestPrefixesByRequest[requestID],
                          recordID.hasPrefix(requestPrefix) else { continue }
                    let eventIdentity = recordID.dropFirst(requestPrefix.count)
                    guard let separator = eventIdentity.firstIndex(of: "|"),
                          attemptKeys.contains(String(eventIdentity[..<separator])) else { continue }
                }
                preparationJournalDecodeAttemptCount += 1
                guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                      let itemID = try? ItemID(rawValue: record.itemID) else { continue }
                let key = preparationRunIdentityKey(requestID: requestID, attempt: status.attempt)
                guard selectedByKey[key] != nil else { continue }
                entriesByRun[key, default: []].append(PreparationJournalEntry(
                    id: recordID, itemID: itemID, requestID: requestID, status: status
                ))
            }
            if records.count < pageSize { break }
        }

        return candidates.compactMap { candidate in
            guard let entries = entriesByRun[candidate.key],
                  let summary = preparationRunSummary(entries) else {
                return nil
            }
            return summary
        }
    }

    private func recentPreparationRunCandidates(
        limit: Int, in context: ModelContext
    ) throws -> PreparationRunReadSelection {
        let pageSize = 256
        let decoder = JSONDecoder()
        var candidates: [String: PreparationRunReadCandidate] = [:]
        var discoveredEntriesByID: [String: PreparationJournalEntry] = [:]
        var pageOffset = 0
        var pendingTimestamp: Timestamp?
        var pendingEntries: [PreparationJournalEntry] = []

        func absorb(_ entries: [PreparationJournalEntry]) {
            for entry in entries.sorted(by: preparationEntryPrecedes).reversed() {
                let key = preparationRunIdentityKey(requestID: entry.requestID, attempt: entry.status.attempt)
                guard candidates[key] == nil else { continue }
                candidates[key] = PreparationRunReadCandidate(
                    key: key, requestID: entry.requestID, attempt: entry.status.attempt, latest: entry
                )
            }
        }

        while candidates.count < limit {
            var query = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
                sortBy: [SortDescriptor(\.emittedAt, order: .reverse), SortDescriptor(\.id, order: .forward)]
            )
            query.fetchOffset = pageOffset
            query.fetchLimit = pageSize
            let page = try context.fetch(query)
            preparationRunRowsRead += page.count
            preparationRunMaximumBatchRows = max(preparationRunMaximumBatchRows, page.count)
            guard !page.isEmpty else {
                absorb(pendingEntries)
                break
            }
            pageOffset += page.count

            var reachedLimitAtBoundary = false
            for row in page {
                guard !isPreparationMarker(row.requestID) else { continue }
                preparationJournalDecodeAttemptCount += 1
                guard let status = try? decoder.decode(PreparationStatus.self, from: row.statusData),
                      let itemID = try? ItemID(rawValue: row.itemID) else { continue }
                let entry = PreparationJournalEntry(
                    id: row.id, itemID: itemID, requestID: row.requestID, status: status
                )
                discoveredEntriesByID[entry.id] = entry
                if let timestamp = pendingTimestamp, timestamp != status.emittedAt {
                    absorb(pendingEntries)
                    if candidates.count >= limit {
                        reachedLimitAtBoundary = true
                        break
                    }
                    pendingEntries = [entry]
                    pendingTimestamp = status.emittedAt
                } else {
                    if pendingTimestamp == nil { pendingTimestamp = status.emittedAt }
                    pendingEntries.append(entry)
                }
            }
            if reachedLimitAtBoundary { break }
            if page.count < pageSize {
                absorb(pendingEntries)
                break
            }
        }

        let selectedCandidates = Array(candidates.values.sorted(by: preparationRunCandidatePrecedes).prefix(limit))
        let selectedKeys = Set(selectedCandidates.map(\.key))
        var selectedEntries: [String: PreparationJournalEntry] = [:]
        for (id, entry) in discoveredEntriesByID {
            let key = preparationRunIdentityKey(requestID: entry.requestID, attempt: entry.status.attempt)
            guard selectedKeys.contains(key) else { continue }
            if let attempt = entry.status.attempt,
               !entry.id.hasPrefix(entry.requestID + "|" + attempt.key + "|") { continue }
            selectedEntries[id] = entry
        }
        return PreparationRunReadSelection(
            candidates: selectedCandidates, discoveredEntriesByID: selectedEntries
        )
    }

    private func preparationRunCandidatePrecedes(
        _ lhs: PreparationRunReadCandidate, _ rhs: PreparationRunReadCandidate
    ) -> Bool {
        if preparationEntryPrecedes(lhs.latest, rhs.latest) { return false }
        if preparationEntryPrecedes(rhs.latest, lhs.latest) { return true }
        return lhs.key < rhs.key
    }

    private func preparationRunIdentityKey(requestID: String, attempt: PreparationAttemptIdentity?) -> String {
        requestID + (attempt.map { "|" + $0.key } ?? "")
    }

    private func isPreparationMarker(_ requestID: String) -> Bool {
        requestID.hasPrefix(Self.forcedRedownloadRequestPrefix)
            || requestID.hasPrefix(Self.resetPreparationRequestPrefix)
    }

    /// Latest status for each requested attempt, decoding only the newest
    /// timestamp group that contains a valid status. Canonical terminal IDs
    /// are fetched by their unique key first; nonterminal fallbacks share one
    /// request-ID batch rather than issuing an unindexed history query per item.
    func latestPreparationEntries(
        for attempts: [ItemID: PreparationAttemptIdentity], in context: ModelContext
    ) throws -> [ItemID: PreparationJournalEntry] {
        guard !attempts.isEmpty else { return [:] }
        var requestIDByItem: [ItemID: String] = [:]
        var itemByTerminalID: [String: ItemID] = [:]
        var prefixesByRequest: [String: [(ItemID, String)]] = [:]
        for (itemID, attempt) in attempts {
            let requestID = PodcastPreparationPipeline.requestID(for: itemID)
            requestIDByItem[itemID] = requestID
            let prefix = requestID + "|" + attempt.key + "|"
            prefixesByRequest[requestID, default: []].append((itemID, prefix))
            itemByTerminalID[prefix + "terminal"] = itemID
            itemByTerminalID[prefix + "interrupted"] = itemID
        }

        let terminalIDs = Set(itemByTerminalID.keys)
        let orderedTerminalIDs = terminalIDs.sorted()
        var terminalRows: [LocalLibrarySchemaV3Models.PreparationRecord] = []
        let terminalQueryBatchSize = 400
        for lowerBound in stride(from: 0, to: orderedTerminalIDs.count, by: terminalQueryBatchSize) {
            let upperBound = min(lowerBound + terminalQueryBatchSize, orderedTerminalIDs.count)
            let idBatch = Set(orderedTerminalIDs[lowerBound..<upperBound])
            let rows = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
                predicate: #Predicate { idBatch.contains($0.id) }
            ))
            preparationStatusRowsRead += rows.count
            preparationStatusMaximumBatchRows = max(preparationStatusMaximumBatchRows, rows.count)
            terminalRows.append(contentsOf: rows)
        }

        var result: [ItemID: PreparationJournalEntry] = [:]
        var exactEntriesByID: [String: PreparationJournalEntry] = [:]
        var invalidExactIDs: Set<String> = []
        var decodeCount = 0
        let decoder = JSONDecoder()
        for record in terminalRows {
            guard let itemID = itemByTerminalID[record.id],
                  record.itemID == itemID.rawValue,
                  record.requestID == requestIDByItem[itemID] else { continue }
            decodeCount += 1
            preparationJournalDecodeAttemptCount += 1
            guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                  status.attempt == attempts[itemID] else {
                invalidExactIDs.insert(record.id)
                continue
            }
            let entry = PreparationJournalEntry(
                id: record.id, itemID: itemID, requestID: record.requestID, status: status
            )
            exactEntriesByID[record.id] = entry
            // Canonical terminal IDs are proof only when their status actually
            // carries a terminal result. If both IDs exist, retain the later
            // event by the journal's stable same-time comparator.
            if status.terminal,
               result[itemID].map({ preparationEntryPrecedes($0, entry) }) ?? true {
                result[itemID] = entry
            }
        }

        let fallbackRequestIDs = Set(prefixesByRequest.keys.filter { requestID in
            prefixesByRequest[requestID]?.contains(where: { result[$0.0] == nil }) == true
        })
        if !fallbackRequestIDs.isEmpty {
            if fallbackRequestIDs.count == 1,
               let requestID = fallbackRequestIDs.first,
               let candidates = prefixesByRequest[requestID], candidates.count == 1,
               let (itemID, prefix) = candidates.first(where: { result[$0.0] == nil }),
               let attempt = attempts[itemID] {
                if let entry = try latestPreparationEntry(
                    for: itemID, attempt: attempt, requestID: requestID, prefix: prefix,
                    exactEntriesByID: exactEntriesByID, invalidExactIDs: invalidExactIDs,
                    decodeCount: &decodeCount, in: context
                ) {
                    result[itemID] = entry
                }
                #if DEBUG
                Self.preparationPublicationReadObserver?("journal", decodeCount)
                #endif
                return result
            }

            var bestByItem: [ItemID: PreparationJournalEntry] = [:]
            for entry in exactEntriesByID.values where !entry.status.terminal {
                let itemID = entry.itemID
                if let previous = bestByItem[itemID], !preparationEntryPrecedes(previous, entry) { continue }
                bestByItem[itemID] = entry
            }
            var finishedItems: Set<ItemID> = []
            let fallbackItemIDs = Set(prefixesByRequest.values.flatMap { values in values.map { $0.0 } }
                .filter { result[$0] == nil })
            let pageSize = 256
            var pageOffset = 0
            while finishedItems.count < fallbackItemIDs.count {
                var query = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
                    predicate: #Predicate { fallbackRequestIDs.contains($0.requestID) },
                    sortBy: [SortDescriptor(\.emittedAt, order: .reverse), SortDescriptor(\.id, order: .forward)]
                )
                query.fetchOffset = pageOffset
                query.fetchLimit = pageSize
                let rows = try context.fetch(query)
                preparationStatusRowsRead += rows.count
                preparationStatusMaximumBatchRows = max(preparationStatusMaximumBatchRows, rows.count)
                guard !rows.isEmpty else { break }
                pageOffset += rows.count

                for record in rows {
                    guard let candidates = prefixesByRequest[record.requestID],
                          let (itemID, _) = candidates.first(where: { record.id.hasPrefix($0.1) }),
                          record.itemID == itemID.rawValue,
                          result[itemID] == nil, !finishedItems.contains(itemID),
                          !invalidExactIDs.contains(record.id) else { continue }
                    let entry: PreparationJournalEntry
                    if let exact = exactEntriesByID[record.id] {
                        entry = exact
                    } else {
                        decodeCount += 1
                        preparationJournalDecodeAttemptCount += 1
                        guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                              status.attempt == attempts[itemID],
                              let decodedItemID = try? ItemID(rawValue: record.itemID), decodedItemID == itemID else {
                            continue
                        }
                        entry = PreparationJournalEntry(
                            id: record.id, itemID: itemID, requestID: record.requestID, status: status
                        )
                    }

                    guard let previous = bestByItem[itemID] else {
                        bestByItem[itemID] = entry
                        continue
                    }
                    if entry.status.emittedAt.date > previous.status.emittedAt.date {
                        bestByItem[itemID] = entry
                    } else if entry.status.emittedAt.date == previous.status.emittedAt.date {
                        if preparationEntryPrecedes(previous, entry) { bestByItem[itemID] = entry }
                    } else {
                        // Persisted dates are millisecond-rounded in statusData;
                        // keep reading while the decoded timestamp ties, even
                        // when raw Date values differ below that precision.
                        finishedItems.insert(itemID)
                    }
                }
                if rows.count < pageSize { break }
            }
            for (itemID, entry) in bestByItem where result[itemID] == nil {
                result[itemID] = entry
            }
        }

        #if DEBUG
        Self.preparationPublicationReadObserver?("journal", decodeCount)
        #endif
        return result
    }

    /// Reads one current attempt through its exact ID prefix. Request ID alone
    /// can cover thousands of retained attempts; the prefix keeps returned
    /// rows bounded in the common single-item status lookup. The schema still
    /// lacks an index for this predicate, so the counter records rows returned
    /// rather than claiming to count SQLite's physical scan work.
    private func latestPreparationEntry(
        for itemID: ItemID,
        attempt: PreparationAttemptIdentity,
        requestID: String,
        prefix: String,
        exactEntriesByID: [String: PreparationJournalEntry],
        invalidExactIDs: Set<String>,
        decodeCount: inout Int,
        in context: ModelContext
    ) throws -> PreparationJournalEntry? {
        let pageSize = 256
        let decoder = JSONDecoder()
        var best: PreparationJournalEntry?
        var pageOffset = 0
        while true {
            var query = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
                predicate: #Predicate { $0.requestID == requestID && $0.id.starts(with: prefix) },
                sortBy: [SortDescriptor(\.emittedAt, order: .reverse), SortDescriptor(\.id, order: .forward)]
            )
            query.fetchOffset = pageOffset
            query.fetchLimit = pageSize
            let rows = try context.fetch(query)
            preparationStatusRowsRead += rows.count
            preparationStatusMaximumBatchRows = max(preparationStatusMaximumBatchRows, rows.count)
            guard !rows.isEmpty else { break }
            pageOffset += rows.count

            var reachedOlderTimestamp = false
            for record in rows {
                guard record.itemID == itemID.rawValue, !invalidExactIDs.contains(record.id) else { continue }
                let entry: PreparationJournalEntry
                if let exact = exactEntriesByID[record.id] {
                    entry = exact
                } else {
                    decodeCount += 1
                    preparationJournalDecodeAttemptCount += 1
                    guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                          status.attempt == attempt else { continue }
                    entry = PreparationJournalEntry(
                        id: record.id, itemID: itemID, requestID: record.requestID, status: status
                    )
                }

                guard let previous = best else {
                    best = entry
                    continue
                }
                if entry.status.emittedAt.date > previous.status.emittedAt.date {
                    best = entry
                } else if entry.status.emittedAt.date == previous.status.emittedAt.date {
                    if preparationEntryPrecedes(previous, entry) { best = entry }
                } else {
                    // Keep the complete decoded timestamp group: serialized
                    // status times have millisecond precision while the raw
                    // SwiftData Date can retain submillisecond differences.
                    reachedOlderTimestamp = true
                    break
                }
            }
            if reachedOlderTimestamp || rows.count < pageSize { break }
        }
        return best
    }
}
