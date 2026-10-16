import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    #if DEBUG
    @TaskLocal static var preparationPublicationReadObserver: (@Sendable (String, Int) -> Void)?
    #endif

    /// A display projection of one acknowledged ticket and its exact journal generation.
    public struct CurrentPreparationStatus: Sendable, Equatable {
        public let requestSequence: Int
        public let attemptCount: Int
        public let state: WorkTicketState
        public let updatedAt: Timestamp
        public let status: PreparationStatus?

        public init(requestSequence: Int, attemptCount: Int, state: WorkTicketState,
                    updatedAt: Timestamp, status: PreparationStatus? = nil) {
            self.requestSequence = requestSequence; self.attemptCount = attemptCount
            self.state = state; self.updatedAt = updatedAt; self.status = status
        }
    }

    /// Reads preparation tickets in one kind batch, then filters exact allowed
    /// backing identities before bounded generation/Ready reads; never run history.
    public func currentPreparationStatuses(for itemIDs: [ItemID]) throws -> [ItemID: CurrentPreparationStatus] {
        let allowedItems = Set(itemIDs)
        guard !allowedItems.isEmpty else { return [:] }
        let preparationKind = WorkTicketKind.podcastPreparation.rawValue
        let context = ModelContext(container)
        let query = FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>(
            predicate: #Predicate { $0.kind == preparationKind }
        )
        let tickets = try context.fetch(query)
        #if DEBUG
        Self.preparationPublicationReadObserver?("tickets", tickets.count)
        #endif
        var result: [ItemID: CurrentPreparationStatus] = [:]
        for ticket in tickets {
            guard let itemID = try? ItemID(rawValue: ticket.subjectID), allowedItems.contains(itemID),
                  let state = WorkTicketState(rawValue: ticket.state) else { continue }
            let attempt = try? PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
            let entries = try attempt.map { try preparationJournal(for: PodcastPreparationPipeline.requestID(for: itemID), attempt: $0) } ?? []
            let latest = entries.last?.status
            // A ticket or terminal alone cannot clear status. Success must name this
            // item's current Ready revision and its current durable preparation outcome.
            let boundSuccessRevision = latest?.terminalResult.flatMap {
                $0.outcome == .succeeded ? $0.revisionID : nil
            }
            // A completed ticket with no bound terminal can defer to existing
            // Ready/current outcome proof (upgrade or lost terminal journal save).
            // Explicit bound failure/cancellation or revision mismatch still refuses.
            let completedWithoutBoundTerminal = state == .succeeded && latest?.terminalResult == nil
            if (state == .running || state == .succeeded),
               boundSuccessRevision != nil || completedWithoutBoundTerminal {
                #if DEBUG
                Self.preparationPublicationReadObserver?("ready", 1)
                #endif
                guard let ready = try readyRevision(for: itemID),
                      boundSuccessRevision == nil || ready.revisionID == boundSuccessRevision else {
                    result[itemID] = CurrentPreparationStatus(requestSequence: ticket.requestSequence,
                        attemptCount: ticket.attemptCount, state: state,
                        updatedAt: latest?.emittedAt ?? Timestamp(ticket.updatedAt), status: latest)
                    continue
                }
                let outcomeID = itemID.rawValue + "|" + ready.revisionID.rawValue
                var outcomeQuery = FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>(
                    predicate: #Predicate { $0.id == outcomeID }
                )
                outcomeQuery.fetchLimit = 1
                if let outcome = try context.fetch(outcomeQuery).first,
                   outcome.eligibility == PodcastPreparationEligibility.current.rawValue { continue }
            }
            result[itemID] = CurrentPreparationStatus(
                requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount, state: state,
                updatedAt: latest?.emittedAt ?? Timestamp(ticket.updatedAt), status: latest
            )
        }
        return result
    }

    public func preparationJournal(for requestID: String, attempt: PreparationAttemptIdentity) throws -> [PreparationJournalEntry] {
        let context = ModelContext(container)
        let prefix = requestID + "|" + attempt.key + "|"
        var query = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.requestID == requestID && $0.id.starts(with: prefix) },
            sortBy: [SortDescriptor(\.emittedAt, order: .reverse)]
        )
        query.fetchLimit = 256
        let rows = try context.fetch(query)
        preparationJournalLookupRowsRead += rows.count
        #if DEBUG
        Self.preparationPublicationReadObserver?("journal", rows.count)
        #endif
        return rows.compactMap { row in
            guard let status = try? JSONDecoder().decode(PreparationStatus.self, from: row.statusData),
                  status.attempt == attempt, let itemID = try? ItemID(rawValue: row.itemID) else { return nil }
            return PreparationJournalEntry(id: row.id, itemID: itemID, requestID: requestID, status: status)
        }.sorted(by: preparationEntryPrecedes)
    }

    /// Appends an interrupted closure to a proven inactive generation at restart.
    /// This is not a callback write: the ticket must name a newer generation or
    /// the same non-running generation, with unchanged nonterminal journal proof.
    /// No ticket, prepared outcome or media state is mutated.
    public func closeInactivePreparationRun(
        _ run: PreparationRunSummary, at now: Timestamp, detail: String
    ) throws -> Bool {
        guard !run.isTerminal, let expected = run.entries.last,
              let attempt = expected.status.attempt,
              run.requestID == PodcastPreparationPipeline.requestID(for: run.itemID),
              run.entries.allSatisfy({ $0.itemID == run.itemID && $0.requestID == run.requestID && $0.status.attempt == attempt }) else { return false }
        let context = ModelContext(container)
        let ticketID = WorkTicketKind.podcastPreparation.rawValue + "|" + run.itemID.rawValue
        var ticketQuery = FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>(
            predicate: #Predicate { $0.id == ticketID }
        )
        ticketQuery.fetchLimit = 1
        guard let ticket = try context.fetch(ticketQuery).first else { return false }
        let sameGeneration = ticket.requestSequence == attempt.requestSequence && ticket.attemptCount == attempt.attemptCount
        let superseded = ticket.requestSequence > attempt.requestSequence
            || (ticket.requestSequence == attempt.requestSequence && ticket.attemptCount > attempt.attemptCount)
        guard superseded || (sameGeneration && ticket.state != WorkTicketState.running.rawValue) else { return false }
        if sameGeneration, let ready = try readyRevision(for: run.itemID) {
            let outcomeID = run.itemID.rawValue + "|" + ready.revisionID.rawValue
            var outcomeQuery = FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>(
                predicate: #Predicate { $0.id == outcomeID }
            )
            outcomeQuery.fetchLimit = 1
            if let outcome = try context.fetch(outcomeQuery).first,
               outcome.eligibility == PodcastPreparationEligibility.current.rawValue,
               outcome.producedAt >= run.startedAt.date { return false }
        }
        let prefix = run.requestID + "|" + attempt.key + "|"
        let terminalID = prefix + "terminal"
        let interruptedID = prefix + "interrupted"
        var terminalQuery = FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.id == terminalID || $0.id == interruptedID }
        )
        terminalQuery.fetchLimit = 2
        guard try context.fetch(terminalQuery).isEmpty else { return false }
        let entries = try preparationJournal(for: run.requestID, attempt: attempt)
        guard !entries.isEmpty, !entries.contains(where: { $0.status.terminal }),
              let latest = entries.last, latest.id == expected.id, latest.status == expected.status else { return false }
        let error = try ProducerError(code: .failed, message: detail, retryable: true, stage: "interrupted")
        let status = try PreparationStatus(stage: .failed, detail: detail, cancellable: false,
            terminalResult: PreparationTerminalResult(outcome: .failed, error: error),
            emittedAt: max(now, latest.status.emittedAt), attempt: attempt)
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(PreparationJournalEntry(
            id: interruptedID, itemID: run.itemID, requestID: run.requestID, status: status)))
        try context.save()
        return true
    }

    /// Fences a terminal ticket write in the same actor turn as its generation check.
    public func finishPreparationAttempt(
        subjectID: String, attempt: PreparationAttemptIdentity, state: WorkTicketState,
        failureKind: String? = nil, lastFailureMessage: String? = nil, at now: Timestamp
    ) throws -> WorkTicket? {
        guard let ticket = try workTicket(kind: .podcastPreparation, subjectID: subjectID),
              ticket.requestSequence == attempt.requestSequence, ticket.attemptCount == attempt.attemptCount,
              ticket.state == .running else { return nil }
        return try applyWorkTicketTransition(kind: .podcastPreparation, subjectID: subjectID,
            requestSequence: attempt.requestSequence, to: state, failureKind: failureKind,
            lastFailureMessage: lastFailureMessage, at: now)
    }
}
