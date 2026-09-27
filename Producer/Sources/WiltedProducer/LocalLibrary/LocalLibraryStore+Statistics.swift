import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

extension LocalLibraryStore {
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

    /// Inserts new deterministic event IDs into an existing transaction.
    @discardableResult
    func appendLifetimeStatistics(
        _ contributions: [LifetimeStatisticContribution],
        in context: ModelContext
    ) throws -> Bool {
        let existingIDs = Set(try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord>()
        ).map(\.id))
        var admittedIDs = existingIDs
        var inserted = false
        for contribution in contributions
        where !contribution.id.isEmpty && contribution.seconds.isFinite && contribution.seconds >= 0
            && admittedIDs.insert(contribution.id).inserted {
            context.insert(LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord(
                id: contribution.id, kind: contribution.kind, seconds: contribution.seconds
            ))
            inserted = true
        }
        return inserted
    }

    /// Totals the immutable ledger and ignores any corrupt legacy value rather
    /// than allowing NaN, infinity, or a negative value to poison a total.
    public func lifetimeStatistics() throws -> LifetimeStatistics {
        let context = ModelContext(container)
        let records = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord>()
        )
        var totals = LifetimeStatistics()
        for record in records where record.seconds.isFinite && record.seconds >= 0 {
            guard let kind = LifetimeStatisticKind(rawValue: record.kind) else { continue }
            switch kind {
            case .audioProcessed:
                let value = totals.audioProcessedSeconds + record.seconds
                if value.isFinite { totals.audioProcessedSeconds = value }
            case .speechGenerated:
                let value = totals.speechGeneratedSeconds + record.seconds
                if value.isFinite { totals.speechGeneratedSeconds = value }
            case .confirmedAdTimeRemoved:
                let value = totals.confirmedAdTimeRemovedSeconds + record.seconds
                if value.isFinite { totals.confirmedAdTimeRemovedSeconds = value }
            case .fasterPlaybackTimeSaved:
                let value = totals.fasterPlaybackTimeSavedSeconds + record.seconds
                if value.isFinite { totals.fasterPlaybackTimeSavedSeconds = value }
            }
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
        let records = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV11Models.PlaybackStatisticHighWaterRecord>()
        )
        let existing = records.first { $0.revisionID == revisionID.rawValue }
        let lowerBound = max(existing?.positionSeconds ?? startSeconds, startSeconds)
        let upperBound = max(lowerBound, endSeconds)
        guard upperBound > lowerBound else { return 0 }

        if let existing {
            existing.positionSeconds = upperBound
        } else {
            context.insert(LocalLibrarySchemaV11Models.PlaybackStatisticHighWaterRecord(
                revisionID: revisionID, positionSeconds: upperBound
            ))
        }

        var savedSeconds = 0.0
        if rate.isFinite, rate > 1 {
            let programSeconds = upperBound - lowerBound
            savedSeconds = programSeconds - programSeconds / rate
            if savedSeconds.isFinite, savedSeconds > 0 {
                let eventID = "playback-speed|\(revisionID.rawValue)|\(lowerBound.bitPattern)|\(upperBound.bitPattern)"
                let events = try context.fetch(
                    FetchDescriptor<LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord>()
                )
                if !events.contains(where: { $0.id == eventID }) {
                    context.insert(LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord(
                        id: eventID, kind: .fasterPlaybackTimeSaved, seconds: savedSeconds
                    ))
                } else {
                    savedSeconds = 0
                }
            } else {
                savedSeconds = 0
            }
        }
        try context.save()
        return savedSeconds
    }

}
