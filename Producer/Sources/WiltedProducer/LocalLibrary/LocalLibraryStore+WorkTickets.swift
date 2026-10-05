import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

extension LocalLibraryStore {
    #if DEBUG
    /// Narrow test seam for exercising a ticket-local recovery error through
    /// the app bootstrap path. Production leaves this nil.
    @_spi(Testing) public nonisolated(unsafe) static var workTicketReconciliationFailureForTesting:
        (@Sendable (WorkTicketReconciliationStep, String) -> Bool)?

    private struct InjectedWorkTicketReconciliationFailure: Error {}

    private static func injectWorkTicketReconciliationFailure(
        for step: WorkTicketReconciliationStep, subjectID: String
    ) throws {
        if workTicketReconciliationFailureForTesting?(step, subjectID) == true {
            throw InjectedWorkTicketReconciliationFailure()
        }
    }
    #endif

    /// A recoverable unit of launch-time ticket repair.
    public enum WorkTicketReconciliationStep: String, Equatable, Sendable, CaseIterable {
        case importingDeferrals
        case adoptingDownloads
        case closingInterruptedRuns
        case collapsingDuplicates
        case pruningTickets

        public var startupAction: String {
            switch self {
            case .importingDeferrals: "importing deferred preparations"
            case .adoptingDownloads: "adopting downloads"
            case .closingInterruptedRuns: "closing interrupted requests"
            case .collapsingDuplicates: "collapsing duplicate requests"
            case .pruningTickets: "removing expired requests"
            }
        }
    }

    /// One live reconciliation update. `done` is reported both before and
    /// after a step so a zero-item step is still visible to the caller.
    public struct WorkTicketReconciliationProgress: Equatable, Sendable {
        public let step: WorkTicketReconciliationStep
        public let done: Int
        public let total: Int

        public init(step: WorkTicketReconciliationStep, done: Int, total: Int) {
            self.step = step
            self.done = done
            self.total = total
        }
    }

    /// A single ticket that could not be recovered. Reconciliation records it
    /// and continues so one malformed row cannot strand the rest of the queue.
    public struct WorkTicketReconciliationError: Equatable, Sendable {
        public let step: WorkTicketReconciliationStep
        public let subjectID: String
        public let message: String

        public init(step: WorkTicketReconciliationStep, subjectID: String, message: String) {
            self.step = step
            self.subjectID = subjectID
            self.message = message
        }
    }

    /// Decodes a persisted work-ticket row, dropping it if its `kind` or
    /// `state` raw value is not one this store recognizes.
    private static func decodeWorkTicket(_ record: LocalLibrarySchemaV12Models.WorkTicketRecord) -> WorkTicket? {
        guard let kind = WorkTicketKind(rawValue: record.kind),
              let state = WorkTicketState(rawValue: record.state) else { return nil }
        return WorkTicket(
            kind: kind, subjectID: record.subjectID, resolvedItemID: record.resolvedItemID,
            requestSequence: record.requestSequence, state: state, attemptCount: record.attemptCount,
            failureKind: record.failureKind, lastFailureMessage: record.lastFailureMessage,
            nextEligibleAt: record.nextEligibleAt.map(Timestamp.init),
            policySnapshot: record.policySnapshot, processingPolicy: record.processingPolicy,
            runID: record.runID, requestedAt: Timestamp(record.requestedAt), updatedAt: Timestamp(record.updatedAt)
        )
    }

    /// All persisted work tickets, in no particular order.
    public func workTickets() throws -> [WorkTicket] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
            .compactMap(Self.decodeWorkTicket)
    }

    /// The persisted ticket for one `(kind, subjectID)`, or nil if none exists.
    public func workTicket(kind: WorkTicketKind, subjectID: String) throws -> WorkTicket? {
        let id = "\(kind.rawValue)|\(subjectID)"
        return try workTickets().first { $0.id == id }
    }

    /// Overwrites the ticket matching `ticket.id`, or inserts it if absent.
    /// Unlike `issueWorkTicket`, the caller supplies `requestSequence`
    /// directly -- this is the path state transitions (running, succeeded,
    /// a retry's incremented `attemptCount`) use, not the path that assigns
    /// a ticket its place in the queue.
    @discardableResult
    public func upsertWorkTicket(_ ticket: WorkTicket) throws -> WorkTicket {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
        if let existing = records.first(where: { $0.id == ticket.id }) {
            existing.apply(ticket)
        } else {
            context.insert(LocalLibrarySchemaV12Models.WorkTicketRecord(ticket))
        }
        try context.save()
        return ticket
    }

    /// Finds or creates the ticket for one `(kind, subjectID)`. An existing
    /// ticket -- pending, in flight, or already terminal -- is returned
    /// unchanged; this is a find-or-insert, not a reset. A new ticket's
    /// `requestSequence` is `max(requestSequence) + 1` computed inside the
    /// same fetch-then-save as the insert, so sequence numbers are
    /// monotonic by construction and never assigned by a separate counter
    /// row -- unless `requestSequence` is supplied, in which case the caller
    /// already reserved that number (from the same in-memory high-water mark
    /// this store seeded at bootstrap) and it is used as-is. This is what
    /// lets a preparation request's place in line be decided synchronously,
    /// on the click, while the durable ticket that records it is written
    /// later, from an async context, without a second numbering scheme.
    @discardableResult
    public func issueWorkTicket(
        kind: WorkTicketKind, subjectID: String, resolvedItemID: String? = nil,
        policySnapshot: Data? = nil, processingPolicy: Data? = nil, requestedAt: Timestamp,
        requestSequence: Int? = nil
    ) throws -> WorkTicket {
        let context = ModelContext(container)
        let id = "\(kind.rawValue)|\(subjectID)"
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
        if let existing = records.first(where: { $0.id == id }) {
            guard let decoded = Self.decodeWorkTicket(existing) else {
                throw LocalLibraryStoreError.invalidPodcastState("corrupt work ticket row")
            }
            return decoded
        }
        let nextSequence = requestSequence ?? ((records.map(\.requestSequence).max() ?? 0) + 1)
        let ticket = WorkTicket(
            kind: kind, subjectID: subjectID, resolvedItemID: resolvedItemID,
            requestSequence: nextSequence, state: .pending, attemptCount: 0,
            policySnapshot: policySnapshot, processingPolicy: processingPolicy,
            requestedAt: requestedAt, updatedAt: requestedAt
        )
        context.insert(LocalLibrarySchemaV12Models.WorkTicketRecord(ticket))
        try context.save()
        return ticket
    }

    /// Finds-or-inserts the ticket for `(kind, subjectID)` and applies one
    /// state transition to it, in a single actor hop -- the fetch, the
    /// mutation, and the save share no `await` between them. That is what
    /// actually serializes two concurrent transitions for the same subject:
    /// this actor is re-entrant across a suspension point, so a caller that
    /// splits find/mutate/write across separate awaited calls (as
    /// `issueWorkTicket` + `upsertWorkTicket` composed by hand would) lets a
    /// second transition interleave between them and overwrite the first.
    /// Composing the whole thing into one actor call is the fix; relying on
    /// `Task` submission order is not an option, since Swift makes no
    /// ordering guarantee between detached `Task`s.
    ///
    /// Immutable-at-admission fields (`policySnapshot`, `processingPolicy`,
    /// `resolvedItemID`) are only ever set when currently nil. The sole
    /// exception is `readmitWorkTicket`, which atomically replaces them for a
    /// genuinely newer request after an earlier attempt has settled.
    /// `attemptCount` increments only on entry into `.running`, never for a
    /// duplicate `.running` write for the same request sequence.
    ///
    /// Throws `.invalidWorkTicketTransition` rather than silently applying or
    /// silently doing nothing when the requested transition is illegal per
    /// `WorkTicketState.canTransition(to:)` -- e.g. a `.pending` arriving
    /// after the ticket is already `.cancelled`. The caller decides what a
    /// rejection means (typically: log it and move on), but it is never
    /// swallowed inside the store.
    @discardableResult
    public func applyWorkTicketTransition(
        kind: WorkTicketKind,
        subjectID: String,
        requestSequence: Int? = nil,
        resolvedItemID: String? = nil,
        policySnapshot: Data? = nil,
        processingPolicy: Data? = nil,
        to state: WorkTicketState,
        failureKind: String? = nil,
        lastFailureMessage: String? = nil,
        at now: Timestamp
    ) throws -> WorkTicket {
        try transitionWorkTicket(
            kind: kind, subjectID: subjectID, requestSequence: requestSequence,
            resolvedItemID: resolvedItemID, policySnapshot: policySnapshot,
            processingPolicy: processingPolicy, to: state, failureKind: failureKind,
            lastFailureMessage: lastFailureMessage, at: now, reAdmitting: false
        )
    }

    /// Atomically admits a newer request into the durable row for this
    /// `(kind, subjectID)`. A newer sequence supersedes the prior attempt in
    /// place: it replaces both policy values, clears terminal/run metadata,
    /// and then applies `state`. A late write carrying an older sequence is a
    /// no-op, so an earlier attempt cannot overwrite this admission.
    ///
    /// Within one request sequence, ordinary forward-only transition rules
    /// still apply and policy remains immutable. Callers must use this only
    /// when they have accepted a genuinely new request.
    @discardableResult
    public func readmitWorkTicket(
        kind: WorkTicketKind,
        subjectID: String,
        requestSequence: Int,
        resolvedItemID: String? = nil,
        policySnapshot: Data? = nil,
        processingPolicy: Data? = nil,
        to state: WorkTicketState,
        at now: Timestamp
    ) throws -> WorkTicket {
        try transitionWorkTicket(
            kind: kind, subjectID: subjectID, requestSequence: requestSequence,
            resolvedItemID: resolvedItemID, policySnapshot: policySnapshot,
            processingPolicy: processingPolicy, to: state, failureKind: nil,
            lastFailureMessage: nil, at: now, reAdmitting: true
        )
    }

    private func transitionWorkTicket(
        kind: WorkTicketKind,
        subjectID: String,
        requestSequence: Int? = nil,
        resolvedItemID: String? = nil,
        policySnapshot: Data? = nil,
        processingPolicy: Data? = nil,
        to state: WorkTicketState,
        failureKind: String? = nil,
        lastFailureMessage: String? = nil,
        at now: Timestamp,
        reAdmitting: Bool
    ) throws -> WorkTicket {
        let context = ModelContext(container)
        let id = "\(kind.rawValue)|\(subjectID)"
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
        let existingRecord = records.first(where: { $0.id == id })

        var ticket: WorkTicket
        if let existingRecord {
            guard let decoded = Self.decodeWorkTicket(existingRecord) else {
                throw LocalLibraryStoreError.invalidPodcastState("corrupt work ticket row")
            }
            ticket = decoded
        } else {
            let nextSequence = requestSequence ?? ((records.map(\.requestSequence).max() ?? 0) + 1)
            ticket = WorkTicket(
                kind: kind, subjectID: subjectID, resolvedItemID: nil,
                requestSequence: nextSequence, state: .pending, attemptCount: 0,
                requestedAt: now, updatedAt: now
            )
        }

        if let requestSequence, requestSequence < ticket.requestSequence {
            // This is a late write from an earlier attempt. It must leave the
            // newer row completely untouched, including its timestamp.
            return ticket
        }
        if let requestSequence, requestSequence > ticket.requestSequence {
            guard reAdmitting else {
                throw LocalLibraryStoreError.invalidWorkTicketTransition(
                    from: ticket.state.rawValue, to: state.rawValue
                )
            }
            // One row remains per key, but every value tied to the old run is
            // discarded before the new admission supplies its policy.
            ticket.requestSequence = requestSequence
            ticket.requestedAt = now
            ticket.state = .pending
            ticket.resolvedItemID = resolvedItemID
            ticket.failureKind = nil
            ticket.lastFailureMessage = nil
            ticket.nextEligibleAt = nil
            ticket.policySnapshot = policySnapshot
            ticket.processingPolicy = processingPolicy
            ticket.runID = nil
        }

        guard ticket.state.canTransition(to: state) else {
            throw LocalLibraryStoreError.invalidWorkTicketTransition(from: ticket.state.rawValue, to: state.rawValue)
        }

        if ticket.policySnapshot == nil, let policySnapshot { ticket.policySnapshot = policySnapshot }
        if ticket.processingPolicy == nil, let processingPolicy { ticket.processingPolicy = processingPolicy }
        if ticket.resolvedItemID == nil, let resolvedItemID { ticket.resolvedItemID = resolvedItemID }
        if state == .running, ticket.state != .running { ticket.attemptCount += 1 }
        ticket.state = state
        if let failureKind { ticket.failureKind = failureKind }
        if let lastFailureMessage { ticket.lastFailureMessage = lastFailureMessage }
        ticket.updatedAt = now

        if let existingRecord {
            existingRecord.apply(ticket)
        } else {
            context.insert(LocalLibrarySchemaV12Models.WorkTicketRecord(ticket))
        }
        try context.save()
        return ticket
    }

    /// Idempotent post-open bootstrap for the work-ticket queue.
    ///
    /// Deliberately not a `LocalLibraryMigrationPlan` stage: every stage there
    /// is `.lightweight` and cannot transform row values, and this must run on
    /// *every* launch rather than once per schema version -- an interrupted
    /// run can happen on any launch, not just the one that first opens V12.
    /// Mirrors `reconcilePodcastStateV10`'s shape: each numbered sub-step below
    /// commits its own `save()` before the next begins, so a crash partway
    /// through leaves already-saved sub-steps durable instead of rolled back
    /// together, and a second call after a partial (or complete) prior one
    /// changes nothing further.
    ///
    /// `sequenceFloor` is the caller's own pre-V12 request-sequence counter,
    /// read once from preferences before this call. Every ticket this pass
    /// issues gets a `requestSequence` above both the highest existing ticket
    /// row and this floor, so a number already handed out under the old
    /// counter is never reissued to a new ticket.
    @discardableResult
    public func reconcileWorkTickets(
        now: Timestamp,
        sequenceFloor: Int,
        importedDeferrals: [WorkTicketImportedDeferral],
        progress: (@Sendable (WorkTicketReconciliationProgress) -> Void)? = nil
    ) throws -> WorkTicketReconciliation {
        let context = ModelContext(container)
        var errors: [WorkTicketReconciliationError] = []

        func report(_ step: WorkTicketReconciliationStep, _ done: Int, _ total: Int) {
            progress?(WorkTicketReconciliationProgress(step: step, done: done, total: total))
        }

        func recordFailure(_ error: Error, step: WorkTicketReconciliationStep, subjectID: String) {
            errors.append(WorkTicketReconciliationError(
                step: step, subjectID: subjectID, message: String(describing: error)
            ))
        }

        // 1. Import deferrals. Find-or-insert, exactly like `issueWorkTicket`:
        // an existing ticket for the subject wins unchanged, so re-running
        // this against preferences the caller has not yet cleared (because an
        // earlier attempt saved this step and then failed a later one) is a
        // no-op rather than a duplicate.
        var importedCount = 0
        report(.importingDeferrals, 0, importedDeferrals.count)
        for (index, deferral) in importedDeferrals.enumerated() {
            try Task.checkCancellation()
            defer { report(.importingDeferrals, index + 1, importedDeferrals.count) }
            do {
                #if DEBUG
                try Self.injectWorkTicketReconciliationFailure(for: .importingDeferrals, subjectID: deferral.subjectID)
                #endif
                let id = "\(WorkTicketKind.podcastPreparation.rawValue)|\(deferral.subjectID)"
                let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
                guard !records.contains(where: { $0.id == id }) else { continue }
                let nextSequence = max(records.map(\.requestSequence).max() ?? 0, sequenceFloor) + 1
                let ticket = WorkTicket(
                    kind: .podcastPreparation, subjectID: deferral.subjectID,
                    requestSequence: nextSequence, state: .pending, attemptCount: 0,
                    policySnapshot: deferral.policySnapshot, processingPolicy: deferral.processingPolicy,
                    requestedAt: now, updatedAt: now
                )
                context.insert(LocalLibrarySchemaV12Models.WorkTicketRecord(ticket))
                importedCount += 1
            } catch {
                recordFailure(error, step: .importingDeferrals, subjectID: deferral.subjectID)
            }
        }
        try context.save()

        // 2. Adopt orphan downloads. A subject that already has a ticket is
        // left untouched -- this only fills a gap left by a pre-ticket launch
        // or a launch that died before it could issue one.
        var adoptedCount = 0
        var seenSubjects: Set<String> = []
        let orphanedDownloads = try (unfinishedPodcastDownloads() + resumablePodcastDownloads()).filter {
            seenSubjects.insert($0.episodeID.rawValue).inserted
        }
        report(.adoptingDownloads, 0, orphanedDownloads.count)
        for (index, download) in orphanedDownloads.enumerated() {
            try Task.checkCancellation()
            let subjectID = download.episodeID.rawValue
            defer { report(.adoptingDownloads, index + 1, orphanedDownloads.count) }
            do {
                #if DEBUG
                try Self.injectWorkTicketReconciliationFailure(for: .adoptingDownloads, subjectID: subjectID)
                #endif
                let id = "\(WorkTicketKind.podcastDownload.rawValue)|\(subjectID)"
                let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
                guard !records.contains(where: { $0.id == id }) else { continue }
                let nextSequence = max(records.map(\.requestSequence).max() ?? 0, sequenceFloor) + 1
                let ticket = WorkTicket(
                    kind: .podcastDownload, subjectID: subjectID,
                    requestSequence: nextSequence, state: .pending, attemptCount: 0,
                    failureKind: download.failureKind?.rawValue,
                    requestedAt: now, updatedAt: now
                )
                context.insert(LocalLibrarySchemaV12Models.WorkTicketRecord(ticket))
                adoptedCount += 1
            } catch {
                recordFailure(error, step: .adoptingDownloads, subjectID: subjectID)
            }
        }
        try context.save()

        // 3. Close interrupted runs. Every ticket at `running` belonged to a
        // process this one is not -- this process has started none -- the
        // same argument `closeInterruptedPreparationRuns` already makes for
        // the preparation journal. A run left `.retryable` or unclassified
        // gets another attempt; one already marked `.terminal`, or that has
        // now exhausted the retry bound, is closed as failed instead.
        var closedCount = 0
        let runningRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
            .filter { $0.state == WorkTicketState.running.rawValue }
        report(.closingInterruptedRuns, 0, runningRecords.count)
        for (index, record) in runningRecords.enumerated() {
            try Task.checkCancellation()
            defer { report(.closingInterruptedRuns, index + 1, runningRecords.count) }
            do {
                #if DEBUG
                try Self.injectWorkTicketReconciliationFailure(for: .closingInterruptedRuns, subjectID: record.subjectID)
                #endif
                let attemptCount = record.attemptCount + 1
                let isTerminalClassification = record.failureKind == PodcastDownloadFailureKind.terminal.rawValue
                if isTerminalClassification || attemptCount > 3 {
                    record.state = WorkTicketState.failed.rawValue
                    record.failureKind = WorkTicketFailure.interrupted.rawValue
                } else {
                    record.state = WorkTicketState.pending.rawValue
                }
                record.attemptCount = attemptCount
                record.updatedAt = now.date
                closedCount += 1
            } catch {
                recordFailure(error, step: .closingInterruptedRuns, subjectID: record.subjectID)
            }
        }
        try context.save()

        // 3.5. Collapse article-preparation duplicates that share a resolved
        // identity. `subjectID` is the draft URL's `ItemID` -- a stable
        // request key at intake, before extraction has run -- so two
        // requests pasted from different draft URLs (a redirect, tracking
        // parameters, an advertised-feed link and the article link it
        // advertises) can both resolve to the same canonical article and end
        // up as two distinct tickets once `resolvedItemID` is known. Only one
        // of those is doing real work; the rest are closed here rather than
        // left to run the GPU pipeline twice for one article. The ticket with
        // the highest `requestSequence` (the most recently requested, and by
        // construction the one whose in-process run -- if any -- is still
        // live) is kept; every other non-terminal duplicate is cancelled. A
        // duplicate already terminal is left alone: it already stopped doing
        // work, and step 4 below prunes it in due course.
        var collapsedCount = 0
        let articleRecords: [LocalLibrarySchemaV12Models.WorkTicketRecord] = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>()
        )
        .filter { $0.kind == WorkTicketKind.articlePreparation.rawValue }
        let groupedByResolution = Dictionary(grouping: articleRecords.filter { $0.resolvedItemID != nil }) {
            $0.resolvedItemID!
        }
        let duplicateRecords = groupedByResolution.values.flatMap { group -> [LocalLibrarySchemaV12Models.WorkTicketRecord] in
            guard group.count > 1, let canonical = group.max(by: { $0.requestSequence < $1.requestSequence }) else {
                return []
            }
            return group.filter { record in
                record.id != canonical.id
                    && (WorkTicketState(rawValue: record.state).map { !$0.isTerminal && $0.canTransition(to: .cancelled) } ?? false)
            }
        }
        report(.collapsingDuplicates, 0, duplicateRecords.count)
        for (index, record) in duplicateRecords.enumerated() {
            try Task.checkCancellation()
            defer { report(.collapsingDuplicates, index + 1, duplicateRecords.count) }
            do {
                #if DEBUG
                try Self.injectWorkTicketReconciliationFailure(for: .collapsingDuplicates, subjectID: record.subjectID)
                #endif
                record.state = WorkTicketState.cancelled.rawValue
                record.updatedAt = now.date
                collapsedCount += 1
            } catch {
                recordFailure(error, step: .collapsingDuplicates, subjectID: record.subjectID)
            }
        }
        try context.save()

        // 4. Prune terminal tickets older than 30 days, per kind, always
        // keeping at least the newest 50 of that kind regardless of age.
        var prunedCount = 0
        let cutoff = now.date.addingTimeInterval(-30 * 24 * 60 * 60)
        let allRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV12Models.WorkTicketRecord>())
        var recordsToPrune: [LocalLibrarySchemaV12Models.WorkTicketRecord] = []
        for kind in WorkTicketKind.allCases {
            let terminalRecords = allRecords
                .filter { $0.kind == kind.rawValue && (WorkTicketState(rawValue: $0.state)?.isTerminal ?? false) }
                .sorted { $0.updatedAt > $1.updatedAt }
            guard terminalRecords.count > 50 else { continue }
            recordsToPrune += terminalRecords.dropFirst(50).filter { $0.updatedAt < cutoff }
        }
        report(.pruningTickets, 0, recordsToPrune.count)
        for (index, record) in recordsToPrune.enumerated() {
            try Task.checkCancellation()
            defer { report(.pruningTickets, index + 1, recordsToPrune.count) }
            do {
                #if DEBUG
                try Self.injectWorkTicketReconciliationFailure(for: .pruningTickets, subjectID: record.subjectID)
                #endif
                context.delete(record)
                prunedCount += 1
            } catch {
                recordFailure(error, step: .pruningTickets, subjectID: record.subjectID)
            }
        }
        try context.save()

        // 5. The sequence floor itself is reseeded by construction: every new
        // ticket issued in steps 1-2 above already took `sequenceFloor` into
        // account when allocating its `requestSequence`, so no further store
        // action is needed here. Reading the preferences counter once and
        // deleting it afterward is the caller's job -- it is process-local
        // preferences state, not library content this actor owns.
        return WorkTicketReconciliation(
            importedDeferralCount: importedCount, adoptedDownloadCount: adoptedCount,
            closedRunCount: closedCount, collapsedDuplicateCount: collapsedCount, prunedCount: prunedCount,
            errors: errors
        )
    }

    /// Idempotent post-open reconciliation folding the pre-V13 removal
    /// representations onto the V13 `removalKind` column.
    ///
    /// Deliberately not a `LocalLibraryMigrationPlan` stage, for the same
    /// reason `reconcileWorkTickets` is not: the V13 stage is `.lightweight`
    /// and cannot transform row values, and this must run on every launch --
    /// an interrupted run can happen on any launch, not just the one that
    /// first opens V13. Each sub-step commits its own `save()` before the
    /// next begins, so a crash partway through leaves already-saved
    /// sub-steps durable, and a second call after a partial or complete
    /// prior one changes nothing further.
    @discardableResult
    public func reconcileEpisodeRemovals() throws -> EpisodeRemovalReconciliation {
        let context = ModelContext(container)

        // 1. A pre-V13 row's only removal evidence was `retiredAt`, so every
        // row that carries one without a `removalKind` yet was retired, not
        // dismissed -- dismissal never left a row behind before this version.
        var backfilledCount = 0
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        where record.retiredAt != nil && record.removalKind == nil {
            record.removalKind = PodcastEpisodeRemovalKind.retired.rawValue
            backfilledCount += 1
        }
        try context.save()

        // 2. Fold every dismissal tombstone onto an episode row. Find first,
        // write second, delete the tombstone last in the same save as the
        // write it depends on -- a conflicting insert on this row's
        // `@Attribute(.unique) id` neither throws nor duplicates, it just
        // silently keeps one side, so this never blind-inserts against an id
        // that might already have a row.
        var convertedCount = 0
        let tombstones = try context.fetch(FetchDescriptor<LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord>())
        if !tombstones.isEmpty {
            let existingByID = Dictionary(
                uniqueKeysWithValues: try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
                    .map { ($0.id, $0) }
            )
            for tombstone in tombstones {
                if let existing = existingByID[tombstone.id] {
                    if existing.removalKind == nil {
                        existing.removalKind = PodcastEpisodeRemovalKind.dismissed.rawValue
                        existing.retiredAt = tombstone.dismissedAt
                    }
                } else {
                    context.insert(LocalLibrarySchemaV13Models.PodcastEpisodeRecord(
                        placeholderForDismissalID: tombstone.id, feedID: tombstone.feedID,
                        title: tombstone.title, dismissedAt: tombstone.dismissedAt
                    ))
                }
                context.delete(tombstone)
                convertedCount += 1
            }
            try context.save()
        }

        return EpisodeRemovalReconciliation(
            backfilledRetirementCount: backfilledCount, convertedDismissalCount: convertedCount
        )
    }

}
