import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// Applies retention to the snapshot bootstrap already needs for interrupted-run
    /// recovery. Selection and deletion share one actor turn and model context.
    public func prunePreparationHistoryAndFetchOpenRuns() throws -> [PreparationRunSummary] {
        let context = ModelContext(container)
        let (records, runs, unreadableRows) = try preparationRunSnapshotChecked(in: context)
        let podcasts = runs.filter { $0.requestID == PodcastPreparationPipeline.requestID(for: $0.itemID) }
        let open = runs.filter { !$0.isTerminal }
        // A lone generation is always protected as the newest.
        let histories = Dictionary(grouping: podcasts, by: \.itemID).filter {
            $0.value.count > 1 && $0.value.contains(where: \.isTerminal)
        }
        guard !histories.isEmpty else { return open }

        let (ready, unreadableRevisions) = try newestReadyRevisionsChecked(in: context)
        let current = PodcastPreparationEligibility.current.rawValue
        let outcomes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>(
            predicate: #Predicate { $0.eligibility == current }
        ))
        let currentOutcomes = Set(outcomes.map(\.id))
        let tickets = try context.fetch(FetchDescriptor<LocalLibrarySchemaV22Models.WorkTicketRecord>())
        var revisionOwners: [String: Set<String>] = [:]
        for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()) {
            revisionOwners[row.id, default: []].insert(row.itemID)
        }
        // Protection is read from four places. If any input for an episode cannot be read, or
        // contradicts another, nothing is pruned for any episode it names.
        var protection = PreparationProtection(blocked: unreadableRevisions)
        protection.readJournal(unreadable: unreadableRows, runs: runs)
        protection.readOutcomes(outcomes, revisionOwners: revisionOwners)
        protection.readTickets(tickets)
        let blocked = protection.blocked
        let ticketAttempts = protection.ticketAttempts

        var removals = Set<String>()
        for (item, history) in histories where !blocked.contains(item.rawValue) {
            let revision = ready[item.rawValue]?.revisionID
            let currentRevision = revision.flatMap { currentOutcomes.contains(item.rawValue + "|" + $0.rawValue) ? $0 : nil }
            // A ready revision with no readable current outcome cannot be matched to the success
            // that proves it, so that history is left whole.
            if revision != nil, currentRevision == nil { continue }
            removals.formUnion(Self.prunablePreparationIDs(
                in: history, hasReadyRevision: revision != nil, currentRevision: currentRevision,
                ticket: ticketAttempts[item.rawValue]))
        }
        if !removals.isEmpty {
            for record in records where removals.contains(record.id) { context.delete(record) }
            try context.save()
        }
        return open
    }

    /// Selects deletable event IDs from one item's complete recovery snapshot.
    static func prunablePreparationIDs(
        in runs: [PreparationRunSummary], hasReadyRevision: Bool,
        currentRevision: RevisionID?, ticket: PreparationAttemptIdentity?
    ) -> Set<String> {
        func attempt(_ run: PreparationRunSummary) -> PreparationAttemptIdentity? {
            run.entries.first?.status.attempt
        }
        // Request sequence and retry count are numeric; legacy unbound history is oldest.
        let ordered = runs.sorted {
            let left = attempt($0), right = attempt($1)
            return (left?.requestSequence ?? -1, left?.attemptCount ?? -1)
                > (right?.requestSequence ?? -1, right?.attemptCount ?? -1)
        }
        let proofIndex = currentRevision.flatMap { revision in
            ordered.firstIndex { run in
                run.outcome == .succeeded
                    && run.entries.last(where: { $0.status.terminal })?.status.terminalResult?.revisionID == revision
            }
        }
        let keepLegacy = hasReadyRevision && proofIndex.flatMap { attempt(ordered[$0]) } == nil
        var failures = 0
        var removals = Set<String>()
        for (index, run) in ordered.enumerated() {
            if run.outcome == .failed { failures += 1 }
            guard index > 0, index != proofIndex, run.isTerminal else { continue }
            if let key = attempt(run) {
                guard key != ticket else { continue }
            } else if keepLegacy { continue }

            let olderThanProof = proofIndex.map { index > $0 } ?? true
            let pruneWholeRun = olderThanProof && (run.outcome != .failed || failures > 3)
            for entry in run.entries where pruneWholeRun || entry.id.hasSuffix("#heartbeat") {
                guard entry.requestID == run.requestID, entry.itemID == run.itemID,
                      entry.id.hasPrefix(run.id + "|"),
                      maintenanceGeneration(of: entry.id, requestID: run.requestID) == attempt(run)
                else { continue }
                removals.insert(entry.id)
            }
        }
        return removals
    }
}
