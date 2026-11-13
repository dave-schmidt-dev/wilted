import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// Parks one running preparation attempt until `nextEligibleAt`, for a
    /// wait the attempt itself decided on (a labelling provider that asked it
    /// to come back later). This is the only path from `.running` back to
    /// `.deferred`; `WorkTicketState.canTransition` still refuses that move,
    /// so every other writer -- including a late `.pending` admission write --
    /// cannot drag a running ticket backward.
    ///
    /// The caller names the generation it owns. A ticket that is no longer
    /// running, or whose `(requestSequence, attemptCount)` differs, belongs to
    /// a newer request or attempt (or has already finished), so the call
    /// returns nil and changes nothing. On success the ticket keeps its
    /// `requestSequence`, `requestedAt`, `attemptCount` and admitted policy;
    /// `firstDeferredAt` is set once per request and `deferralCount` adds one.
    /// The reason is stored in `failureKind` and stays there after the wait
    /// until a later failure or a newer request replaces it.
    ///
    /// Restart (W-INV-036): a generation that went running and is now
    /// deferred is not an interrupted run. Its journal stays open and
    /// unpublished across a relaunch -- `closeInactivePreparationRun` refuses
    /// to close it, reconciliation leaves the ticket deferred with its time,
    /// and publication shows it as queued -- until the same request finishes
    /// on resume or its wait ends. Resuming enters `.running` through the
    /// ordinary admission write, which spends one attempt and so opens a new
    /// generation; only then does restart closure treat the parked generation
    /// as superseded and append its interrupted entry.
    ///
    /// Queue fairness: a deferred ticket keeps its original request sequence,
    /// so the preparation gate, which admits in request-sequence order, puts
    /// it back ahead of later requests once its time has passed. Until then
    /// the scheduler skips it and prepares other tickets; it never preempts a
    /// preparation already running.
    @discardableResult
    public func deferRunningWorkTicket(
        subjectID: String, requestSequence: Int, attemptCount: Int,
        until nextEligibleAt: Timestamp, reason: WorkTicketDeferralReason,
        at now: Timestamp = Timestamp(Date())
    ) throws -> WorkTicket? {
        let context = ModelContext(container)
        let id = "\(WorkTicketKind.podcastPreparation.rawValue)|\(subjectID)"
        guard let record = try workTicketRecord(id: id, in: context),
              record.requestSequence == requestSequence, record.attemptCount == attemptCount,
              record.state == WorkTicketState.running.rawValue,
              var ticket = Self.decodeWorkTicket(record) else { return nil }
        ticket.state = .deferred
        ticket.nextEligibleAt = nextEligibleAt
        ticket.failureKind = reason.rawValue
        ticket.firstDeferredAt = ticket.firstDeferredAt ?? now
        ticket.deferralCount = (ticket.deferralCount ?? 0) + 1
        ticket.updatedAt = now
        record.apply(ticket)
        try context.save()
        return ticket
    }

    /// The deferred tickets of one kind, through a targeted query, so a
    /// scheduler tick does not decode a long settled history to find them.
    public func deferredWorkTickets(kind: WorkTicketKind) throws -> [WorkTicket] {
        let kindValue = kind.rawValue
        let deferred = WorkTicketState.deferred.rawValue
        let query = FetchDescriptor<LocalLibrarySchemaV22Models.WorkTicketRecord>(
            predicate: #Predicate { $0.kind == kindValue && $0.state == deferred }
        )
        let records = try ModelContext(container).fetch(query)
        targetedWorkTicketRowsRead += records.count
        return records.compactMap(Self.decodeWorkTicket)
    }
}
