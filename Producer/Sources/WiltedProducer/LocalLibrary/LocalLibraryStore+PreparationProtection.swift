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
            // The row's key and its fields must name the same episode and revision.
            if outcome.id != outcome.episodeID + "|" + outcome.revisionID {
                block(outcome.episodeID, outcome.id.split(separator: "|", maxSplits: 1).first.map(String.init))
            }
        }
    }

    /// What retention may do for one episode.
    enum Proof: Equatable {
        /// No positive proof either way: leave the history whole.
        case skip
        /// Shown never to have been prepared: only failed history exists.
        case neverPrepared
        /// A Ready revision with a current outcome; the associated value is the validated run that proves it.
        case ready(String)
    }

    /// Episodes with any sign of a finished preparation: a revision row, any outcome row, or a run
    /// that ended with a revision, wherever it is filed. "Never prepared" needs all of these absent.
    static func preparedEpisodes(
        runs: [PreparationRunSummary],
        outcomes: [LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord],
        revisionOwners: [String: Set<String>]
    ) -> Set<String> {
        var prepared = Set(revisionOwners.values.joined())
        for outcome in outcomes {
            // A row's key names an episode too, and its fields may disagree with it.
            prepared.insert(outcome.episodeID)
            if let keyed = outcome.id.split(separator: "|", maxSplits: 1).first { prepared.insert(String(keyed)) }
        }
        for run in runs where run.entries.contains(where: { $0.status.terminalResult?.revisionID != nil }) {
            prepared.formUnion(run.entries.map(\.itemID.rawValue))
            if let named = podcastItemID(fromRequestID: run.requestID) { prepared.insert(named) }
        }
        return prepared
    }

    /// Decides, from positive evidence only, how much of one episode's history may be pruned.
    static func proof(
        for episode: String, history: [PreparationRunSummary], prepared: Set<String>,
        ready: StoredAudioRevision?, currentOutcomes: Set<String>
    ) -> Proof {
        guard let ready else { return prepared.contains(episode) ? .skip : .neverPrepared }
        let revision = ready.revision.revisionID
        guard currentOutcomes.contains(episode + "|" + revision.rawValue) else { return .skip }
        // Newest validated run wins, so deletion keeps exactly the run that was checked.
        func rank(_ run: PreparationRunSummary) -> [Int] {
            let attempt = run.entries.first?.status.attempt
            return [attempt?.requestSequence ?? -1, attempt?.attemptCount ?? -1]
        }
        guard let proof = history.filter({ proves($0, revision) })
            .max(by: { $0.id != $1.id && rank($0).lexicographicallyPrecedes(rank($1)) }) else { return .skip }
        return .ready(proof.id)
    }

    /// A run proves a revision only if it ended in success, and every terminal event it holds says so.
    private static func proves(_ run: PreparationRunSummary, _ revision: RevisionID) -> Bool {
        guard run.outcome == .succeeded else { return false }
        let terminals = run.entries.filter(\.status.terminal)
        return !terminals.isEmpty && terminals.allSatisfy {
            $0.status.terminalResult?.outcome == .succeeded && $0.status.terminalResult?.revisionID == revision
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
