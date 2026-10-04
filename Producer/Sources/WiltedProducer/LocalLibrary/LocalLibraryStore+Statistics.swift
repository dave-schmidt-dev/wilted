import Foundation
import SwiftData
import WiltedDomain

private typealias LegacyEvent = LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord
private typealias SpeedHighWater = LocalLibrarySchemaV11Models.PlaybackStatisticHighWaterRecord
private typealias MeasureEvent = LocalLibrarySchemaV14Models.LifetimeMeasureEventRecord
private typealias MeasureHighWater = LocalLibrarySchemaV14Models.LifetimeMeasureHighWaterRecord
private typealias SummaryRecord = LocalLibrarySchemaV14Models.LifetimeStatisticsSummaryRecord
private typealias TrackingRecord = LocalLibrarySchemaV14Models.LifetimeStatisticsTrackingRecord

extension LocalLibraryStore {
    // MARK: - Legacy four totals

    /// Appends one validated lifetime contribution. An existing deterministic
    /// ID wins unchanged, making retries and relaunches idempotent.
    @discardableResult
    public func recordLifetimeStatistic(
        id: String,
        kind: LifetimeStatisticKind,
        seconds: Double
    ) throws -> Bool {
        guard !id.isEmpty, seconds.isFinite, seconds >= 0 else { return false }
        let context = ModelContext(container)
        let inserted = try appendLifetimeStatistics([
            LifetimeStatisticContribution(id: id, kind: kind, seconds: seconds)
        ], in: context)
        guard inserted else { return false }
        try context.save()
        return true
    }

    /// Inserts new deterministic event IDs into an existing transaction and
    /// adds them to a ready summary in that same transaction. Each ID is
    /// checked by exact key, never by reading the whole ledger.
    @discardableResult
    func appendLifetimeStatistics(
        _ contributions: [LifetimeStatisticContribution],
        in context: ModelContext
    ) throws -> Bool {
        var admittedIDs: Set<String> = []
        var inserted = false
        var summary: SummaryRecord?
        var summaryLoaded = false
        for contribution in contributions
        where !contribution.id.isEmpty && contribution.seconds.isFinite && contribution.seconds >= 0
            && admittedIDs.insert(contribution.id).inserted {
            guard try !legacyEventExists(contribution.id, in: context) else { continue }
            context.insert(LegacyEvent(id: contribution.id, kind: contribution.kind, seconds: contribution.seconds))
            if !summaryLoaded { summary = try readySummary(in: context); summaryLoaded = true }
            summary?.legacy.add(contribution.kind, seconds: contribution.seconds)
            // Match the measured path: a ready summary records when it last changed.
            summary?.updatedAt = Date()
            inserted = true
        }
        return inserted
    }

    /// The four legacy totals. O(1) from the summary when it is ready; while
    /// a summary is still awaiting its rebuild (right after the V14
    /// migration) it totals the legacy ledger directly, with the same
    /// filtering, so these values never regress.
    public func lifetimeStatistics() throws -> LifetimeStatistics {
        let context = ModelContext(container)
        if let summary = try readySummary(in: context) { return summary.legacy }
        var totals = LifetimeStatistics()
        for record in try context.fetch(FetchDescriptor<LegacyEvent>()) {
            guard let kind = LifetimeStatisticKind(rawValue: record.kind) else { continue }
            totals.add(kind, seconds: record.seconds)
        }
        return totals
    }

    /// Advances one revision's durable high-water mark on every checkpoint.
    /// Only the newly crossed program interval can contribute savings, and a
    /// rate at or below 1x still advances the mark so it cannot be counted by
    /// a later faster checkpoint.
    @discardableResult
    public func recordPlaybackSpeedCheckpoint(
        revisionID: RevisionID,
        from startSeconds: Double,
        to endSeconds: Double,
        rate: Double
    ) throws -> Double {
        guard startSeconds.isFinite, endSeconds.isFinite,
              startSeconds >= 0, endSeconds >= 0 else { return 0 }
        let context = ModelContext(container)
        let key = revisionID.rawValue
        var descriptor = FetchDescriptor<SpeedHighWater>(predicate: #Predicate { $0.revisionID == key })
        descriptor.fetchLimit = 1
        lifetimeStatisticsFetchCount += 1
        let existing = try context.fetch(descriptor).first
        let lowerBound = max(existing?.positionSeconds ?? startSeconds, startSeconds)
        let upperBound = max(lowerBound, endSeconds)
        guard upperBound > lowerBound else { return 0 }

        if let existing {
            existing.positionSeconds = upperBound
        } else {
            context.insert(SpeedHighWater(revisionID: revisionID, positionSeconds: upperBound))
        }

        var savedSeconds = 0.0
        if rate.isFinite, rate > 1 {
            let programSeconds = upperBound - lowerBound
            let candidate = programSeconds - programSeconds / rate
            if candidate.isFinite, candidate > 0 {
                let eventID = "playback-speed|\(revisionID.rawValue)|\(lowerBound.bitPattern)|\(upperBound.bitPattern)"
                if try appendLifetimeStatistics([
                    LifetimeStatisticContribution(id: eventID, kind: .fasterPlaybackTimeSaved, seconds: candidate)
                ], in: context) {
                    savedSeconds = candidate
                }
            }
        }
        try context.save()
        return savedSeconds
    }

    // MARK: - Measured totals (V14)

    /// Admits one immutable measured delta under a deterministic `id`.
    /// Returns false, changing nothing, when the ID already exists -- even if
    /// the earlier row carries a different amount -- or the amount is zero.
    @discardableResult
    public func recordLifetimeMeasure(id: String, _ amount: LifetimeMeasureAmount, at date: Date) throws -> Bool {
        guard !id.isEmpty, amount.baseUnits > 0 else { return false }
        let context = ModelContext(container)
        guard try !measureEventExists(id, in: context) else { return false }
        try insertMeasure(id: id, amount: amount, ownerKey: nil, at: date, in: context)
        try context.save()
        return true
    }

    /// Records a cumulative checkpoint for one session or attempt.
    ///
    /// Only the amount above the stored high-water mark for `(kind,
    /// ownerKey)` becomes a new immutable event; the event, the advanced mark
    /// and the summary commit in one save. Repeated, replayed or lower
    /// checkpoints admit nothing. Returns the admitted delta, if any.
    @discardableResult
    public func recordLifetimeMeasureCheckpoint(
        _ cumulative: LifetimeMeasureAmount, ownerKey: String, at date: Date
    ) throws -> LifetimeMeasureAmount? {
        guard !ownerKey.isEmpty else { return nil }
        let context = ModelContext(container)
        let highWater = try measureHighWaterRecord(kind: cumulative.kind, ownerKey: ownerKey, in: context)
        let previous = highWater?.amount ?? 0
        guard cumulative.baseUnits > previous,
              let delta = LifetimeMeasureAmount.stored(cumulative.kind, baseUnits: cumulative.baseUnits - previous)
        else { return nil }
        let eventID = "measure|\(cumulative.kind.rawValue)|\(ownerKey)|\(previous)|\(cumulative.baseUnits)"
        if let highWater {
            highWater.amount = cumulative.baseUnits
            highWater.updatedAt = date
        } else {
            context.insert(MeasureHighWater(kind: cumulative.kind, ownerKey: ownerKey,
                                            amount: cumulative.baseUnits, updatedAt: date))
        }
        try insertMeasure(id: eventID, amount: delta, ownerKey: ownerKey, at: date, in: context)
        try context.save()
        return delta
    }

    /// The greatest cumulative amount admitted for `(kind, ownerKey)`, by exact key.
    public func lifetimeMeasureHighWater(kind: LifetimeMeasureKind, ownerKey: String) throws -> LifetimeMeasureAmount? {
        let context = ModelContext(container)
        guard let record = try measureHighWaterRecord(kind: kind, ownerKey: ownerKey, in: context) else { return nil }
        return LifetimeMeasureAmount.stored(kind, baseUnits: record.amount)
    }

    /// Whether a measured event with this exact ID exists.
    public func lifetimeMeasureEventExists(id: String) throws -> Bool {
        try measureEventExists(id, in: ModelContext(container))
    }

    /// The durable summary in O(1): one summary row and one tracking row.
    /// Never rebuilds; a `rebuildRequired` state carries zero totals.
    public func lifetimeStatisticsSummary() throws -> LifetimeStatisticsSummary {
        let context = ModelContext(container)
        var trackingDescriptor = FetchDescriptor<TrackingRecord>()
        trackingDescriptor.fetchLimit = 1
        lifetimeStatisticsFetchCount += 1
        let startedAt = try context.fetch(trackingDescriptor).first?.startedAt
        guard let summary = try summaryRecord(in: context),
              summary.state == LifetimeStatisticsSummary.State.ready.rawValue else {
            return LifetimeStatisticsSummary(state: .rebuildRequired, trackingStartedAt: startedAt)
        }
        return LifetimeStatisticsSummary(state: .ready, legacy: summary.legacy, measured: summary.measured,
                                         trackingStartedAt: startedAt, updatedAt: summary.updatedAt)
    }

    // MARK: - Exact-key helpers

    private func insertMeasure(
        id: String, amount: LifetimeMeasureAmount, ownerKey: String?, at date: Date, in context: ModelContext
    ) throws {
        let sequence = try nextLifetimeMeasureSequence(in: context)
        context.insert(MeasureEvent(id: id, sequence: sequence, amount: amount, ownerKey: ownerKey, recordedAt: date))
        if let summary = try readySummary(in: context) {
            var measured = summary.measured
            measured.add(amount)
            summary.measured = measured
            summary.updatedAt = date
        }
    }

    /// The next ledger sequence: one past the greatest stored sequence, read
    /// through its unique index inside the inserting transaction. It is
    /// re-read on every insert rather than cached, because `sequence` is
    /// unique and SwiftData resolves a unique clash by overwriting -- a stale
    /// cached value from a second store instance would replace a committed event.
    private func nextLifetimeMeasureSequence(in context: ModelContext) throws -> Int64 {
        var descriptor = FetchDescriptor<MeasureEvent>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        descriptor.fetchLimit = 1
        lifetimeStatisticsFetchCount += 1
        return (try context.fetch(descriptor).first?.sequence ?? 0) + 1
    }

    private func legacyEventExists(_ id: String, in context: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<LegacyEvent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        lifetimeStatisticsFetchCount += 1
        return try context.fetchCount(descriptor) > 0
    }

    private func measureEventExists(_ id: String, in context: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<MeasureEvent>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        lifetimeStatisticsFetchCount += 1
        return try context.fetchCount(descriptor) > 0
    }

    private func measureHighWaterRecord(
        kind: LifetimeMeasureKind, ownerKey: String, in context: ModelContext
    ) throws -> MeasureHighWater? {
        let key = MeasureHighWater.key(kind: kind, ownerKey: ownerKey)
        var descriptor = FetchDescriptor<MeasureHighWater>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        lifetimeStatisticsFetchCount += 1
        return try context.fetch(descriptor).first
    }

    fileprivate func summaryRecord(in context: ModelContext) throws -> SummaryRecord? {
        let key = SummaryRecord.singletonKey
        var descriptor = FetchDescriptor<SummaryRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        lifetimeStatisticsFetchCount += 1
        return try context.fetch(descriptor).first
    }

    private func readySummary(in context: ModelContext) throws -> SummaryRecord? {
        guard let summary = try summaryRecord(in: context),
              summary.state == LifetimeStatisticsSummary.State.ready.rawValue else { return nil }
        return summary
    }

    // MARK: - Summary rebuild

    /// Rebuilds the summary from both ledgers and publishes it in one save.
    ///
    /// Not a prerequisite to opening the library: callers run it in the
    /// background. The measured ledger is read in `batchSize` pages by
    /// sequence, yielding between pages so playback writes keep flowing;
    /// rows committed meanwhile carry a higher sequence and are read by a
    /// later page, so each row counts exactly once. The small legacy ledger
    /// is then read and the result published without yielding, so no write
    /// can slip between the final read and the publish. Cancellation between
    /// pages discards the work and leaves the stored summary untouched.
    @discardableResult
    public func rebuildLifetimeStatisticsSummary(
        batchSize: Int = 500,
        progress: (@Sendable (LifetimeStatisticsRebuildProgress) -> Void)? = nil
    ) async throws -> LifetimeStatisticsSummary {
        guard !lifetimeStatisticsRebuildRunning else { throw LocalLibraryStoreError.statisticsRebuildInProgress }
        lifetimeStatisticsRebuildRunning = true
        defer { lifetimeStatisticsRebuildRunning = false }
        let pageSize = max(1, batchSize)
        let total = try ModelContext(container).fetchCount(FetchDescriptor<MeasureEvent>())
            + ModelContext(container).fetchCount(FetchDescriptor<LegacyEvent>())
        var processed = 0
        var measured = LifetimeMeasuredTotals()
        var cursor: Int64 = 0
        while true {
            try Task.checkCancellation()
            let context = ModelContext(container)
            let after = cursor
            var page = FetchDescriptor<MeasureEvent>(predicate: #Predicate { $0.sequence > after },
                                                     sortBy: [SortDescriptor(\.sequence)])
            page.fetchLimit = pageSize
            let rows = try context.fetch(page)
            for row in rows {
                guard let kind = LifetimeMeasureKind(rawValue: row.kind), row.unit == kind.unit.rawValue,
                      let amount = LifetimeMeasureAmount.stored(kind, baseUnits: row.amount) else { continue }
                measured.add(amount)
            }
            processed += rows.count
            cursor = rows.last?.sequence ?? cursor
            progress?(LifetimeStatisticsRebuildProgress(phase: .measuredLedger, processedEvents: processed, totalEvents: total))
            if rows.count < pageSize { break }
            await Task.yield()
        }
        // From here to the publish there is no suspension point.
        var legacy = LifetimeStatistics()
        var offset = 0
        while true {
            try Task.checkCancellation()
            var page = FetchDescriptor<LegacyEvent>(sortBy: [SortDescriptor(\.id, comparator: .lexical)])
            page.fetchLimit = pageSize
            page.fetchOffset = offset
            let rows = try ModelContext(container).fetch(page)
            for row in rows {
                guard let kind = LifetimeStatisticKind(rawValue: row.kind) else { continue }
                legacy.add(kind, seconds: row.seconds)
            }
            processed += rows.count
            offset += rows.count
            progress?(LifetimeStatisticsRebuildProgress(phase: .legacyLedger, processedEvents: processed, totalEvents: total))
            if rows.count < pageSize { break }
        }
        try Task.checkCancellation()
        let context = ModelContext(container)
        let summary: SummaryRecord
        if let existing = try summaryRecord(in: context) {
            summary = existing
        } else {
            summary = SummaryRecord(state: .rebuildRequired, updatedAt: Date())
            context.insert(summary)
        }
        summary.legacy = legacy
        summary.measured = measured
        summary.state = LifetimeStatisticsSummary.State.ready.rawValue
        summary.updatedAt = Date()
        try context.save()
        progress?(LifetimeStatisticsRebuildProgress(phase: .published, processedEvents: processed, totalEvents: total))
        return try lifetimeStatisticsSummary()
    }
}
