import Foundation
import SwiftData
import WiltedDomain

/// What retention may trust. Protection for an episode is spread over the journal, the revision rows,
/// the current outcome and the work ticket. Every row that names an episode, by its item ID, its
/// request ID, its revision or its ticket key, is checked against the others. A row that cannot be
/// read, or that contradicts another, blocks pruning for every episode it names: a proof that cannot
/// be seen must never look like no proof, and a damaged row must not leave a second episode exposed.
struct PreparationProtection {
    /// Episodes (raw item IDs) nothing may be pruned for.
    var blocked: Set<String> = []
    /// The generation each episode's running work ticket owns.
    var ticketAttempts: [String: PreparationAttemptIdentity] = [:]

    private static let podcastRequestPrefix = "podcast-prepare|"

    /// The episode a podcast preparation request ID names, or nil for any other request.
    static func podcastItemID(fromRequestID requestID: String) -> String? {
        guard requestID.hasPrefix(podcastRequestPrefix) else { return nil }
        return String(requestID.dropFirst(podcastRequestPrefix.count))
    }

    private mutating func block(_ ids: String?...) { for case let id? in ids { blocked.insert(id) } }

    /// Journal rows that could not be decoded, or whose run mixes episodes or generations.
    mutating func readJournal(
        unreadable: [LocalLibrarySchemaV3Models.PreparationRecord], runs: [PreparationRunSummary]
    ) {
        for row in unreadable { block(row.itemID, Self.podcastItemID(fromRequestID: row.requestID)) }
        for run in runs {
            guard let named = Self.podcastItemID(fromRequestID: run.requestID) else { continue }
            let owners = Set(run.entries.map(\.itemID.rawValue))
            if owners != [named] { blocked.formUnion(owners); block(named) }
            if run.entries.contains(where: {
                LocalLibraryStore.maintenanceGeneration(of: $0.id, requestID: $0.requestID) != $0.status.attempt
            }) { blocked.formUnion(owners); block(named) }
        }
    }

    /// Every current outcome must name a revision row that belongs to the same episode.
    mutating func readOutcomes(
        _ outcomes: [LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord],
        revisionOwners: [String: Set<String>]
    ) {
        for outcome in outcomes {
            let owners = revisionOwners[outcome.revisionID] ?? []
            if owners != [outcome.episodeID] { blocked.formUnion(owners); block(outcome.episodeID) }
        }
    }

    /// Each podcast work ticket must agree with its own durable key and carry a usable generation.
    mutating func readTickets(_ tickets: [LocalLibrarySchemaV22Models.WorkTicketRecord]) {
        let kind = WorkTicketKind.podcastPreparation.rawValue
        for ticket in tickets where ticket.kind == kind || ticket.id.hasPrefix(kind + "|") {
            let named = ticket.id.hasPrefix(kind + "|") ? String(ticket.id.dropFirst(kind.count + 1)) : nil
            let wellFormed = ticket.kind == kind && named == ticket.subjectID
                && (try? ItemID(rawValue: ticket.subjectID)) != nil
            let attempt = try? PreparationAttemptIdentity(
                requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
            // A ticket that has not started yet (no attempts) owns no generation, which is normal. One that
            // is running without an attempt, or with an impossible counter, owns a generation we cannot name.
            let usable = ticket.requestSequence >= 0 && ticket.attemptCount >= 0
                && (attempt != nil || ticket.state != WorkTicketState.running.rawValue)
            guard wellFormed, usable else {
                block(ticket.subjectID, named)
                continue
            }
            if let attempt { ticketAttempts[ticket.subjectID] = attempt }
        }
    }
}
