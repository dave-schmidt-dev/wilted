import Foundation
import SwiftData
import WiltedDomain

enum LocalLibrarySchemaV14Models {
    /// One immutable, unit-typed contribution to a measured lifetime total.
    /// Rows are inserted once under a deterministic `id` and never updated or
    /// deleted; a later write with the same `id` changes nothing.
    @Model final class LifetimeMeasureEventRecord {
        @Attribute(.unique) var id: String
        /// Store-assigned, strictly increasing insertion order. A summary
        /// rebuild pages by it, so a row committed while the rebuild is paused
        /// always lands after the rebuild's cursor and is read exactly once.
        @Attribute(.unique) var sequence: Int64
        /// `LifetimeMeasureKind.rawValue`.
        var kind: String
        /// `LifetimeMeasureUnit.rawValue`, stored redundantly so a reader can
        /// refuse a row whose unit no longer matches its kind.
        var unit: String
        /// Milliseconds or bytes, per `unit`.
        var amount: Int64
        /// The session or attempt whose checkpoint produced this delta, when
        /// it came from a high-water checkpoint.
        var ownerKey: String?
        var recordedAt: Date

        init(id: String, sequence: Int64, amount: LifetimeMeasureAmount, ownerKey: String?, recordedAt: Date) {
            self.id = id
            self.sequence = sequence
            kind = amount.kind.rawValue
            unit = amount.kind.unit.rawValue
            self.amount = amount.baseUnits
            self.ownerKey = ownerKey
            self.recordedAt = recordedAt
        }
    }

    /// The greatest cumulative amount already admitted for one measured kind
    /// of one session or attempt. Mutable and deliberately separate from the
    /// immutable ledger: repeated or replayed checkpoints compare against it
    /// by exact key and only the newly crossed amount becomes an event.
    @Model final class LifetimeMeasureHighWaterRecord {
        /// `"<kind>|<ownerKey>"`.
        @Attribute(.unique) var key: String
        var kind: String
        var ownerKey: String
        var amount: Int64
        var updatedAt: Date

        init(kind: LifetimeMeasureKind, ownerKey: String, amount: Int64, updatedAt: Date) {
            key = Self.key(kind: kind, ownerKey: ownerKey)
            self.kind = kind.rawValue
            self.ownerKey = ownerKey
            self.amount = amount
            self.updatedAt = updatedAt
        }

        static func key(kind: LifetimeMeasureKind, ownerKey: String) -> String {
            "\(kind.rawValue)|\(ownerKey)"
        }
    }

    /// The single rebuildable summary row. Writers update it in the same save
    /// as the event they insert, so a reader sees the event and its total
    /// together or neither. It can always be rebuilt from both ledgers.
    @Model final class LifetimeStatisticsSummaryRecord {
        @Attribute(.unique) var key: String
        /// `LifetimeStatisticsSummary.State.rawValue`.
        var state: String
        var audioProcessedSeconds: Double
        var speechGeneratedSeconds: Double
        var confirmedAdTimeRemovedSeconds: Double
        var fasterPlaybackTimeSavedSeconds: Double
        var playedMilliseconds: Int64
        var receivedBytes: Int64
        var manuallySkippedMilliseconds: Int64
        var updatedAt: Date

        init(state: LifetimeStatisticsSummary.State, updatedAt: Date) {
            key = Self.singletonKey
            self.state = state.rawValue
            audioProcessedSeconds = 0; speechGeneratedSeconds = 0
            confirmedAdTimeRemovedSeconds = 0; fasterPlaybackTimeSavedSeconds = 0
            playedMilliseconds = 0; receivedBytes = 0; manuallySkippedMilliseconds = 0
            self.updatedAt = updatedAt
        }

        static let singletonKey = "lifetime"

        var legacy: LifetimeStatistics {
            get {
                LifetimeStatistics(audioProcessedSeconds: audioProcessedSeconds,
                                   speechGeneratedSeconds: speechGeneratedSeconds,
                                   confirmedAdTimeRemovedSeconds: confirmedAdTimeRemovedSeconds,
                                   fasterPlaybackTimeSavedSeconds: fasterPlaybackTimeSavedSeconds)
            }
            set {
                audioProcessedSeconds = newValue.audioProcessedSeconds
                speechGeneratedSeconds = newValue.speechGeneratedSeconds
                confirmedAdTimeRemovedSeconds = newValue.confirmedAdTimeRemovedSeconds
                fasterPlaybackTimeSavedSeconds = newValue.fasterPlaybackTimeSavedSeconds
            }
        }

        var measured: LifetimeMeasuredTotals {
            get {
                LifetimeMeasuredTotals(playedMilliseconds: playedMilliseconds, receivedBytes: receivedBytes,
                                       manuallySkippedMilliseconds: manuallySkippedMilliseconds)
            }
            set {
                playedMilliseconds = newValue.playedMilliseconds
                receivedBytes = newValue.receivedBytes
                manuallySkippedMilliseconds = newValue.manuallySkippedMilliseconds
            }
        }
    }

    /// When measured tracking began on this store. Written once, at the first
    /// V14 open, and never updated -- separate from the summary so a rebuild
    /// can never move it or invent earlier history.
    @Model final class LifetimeStatisticsTrackingRecord {
        @Attribute(.unique) var key: String
        var startedAt: Date
        /// The store schema version that started tracking.
        var schemaVersion: Int

        init(startedAt: Date, schemaVersion: Int) {
            key = LifetimeStatisticsSummaryRecord.singletonKey
            self.startedAt = startedAt
            self.schemaVersion = schemaVersion
        }
    }
}

/// Version 14 adds the measured lifetime ledger, its high-water records, the
/// summary row and the tracking-start row. Lightweight: four wholly new
/// tables, and no existing entity changes shape.
enum LocalLibrarySchemaV14: VersionedSchema {
    static let versionIdentifier = Schema.Version(14, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV13.models + [
            LocalLibrarySchemaV14Models.LifetimeMeasureEventRecord.self,
            LocalLibrarySchemaV14Models.LifetimeMeasureHighWaterRecord.self,
            LocalLibrarySchemaV14Models.LifetimeStatisticsSummaryRecord.self,
            LocalLibrarySchemaV14Models.LifetimeStatisticsTrackingRecord.self,
        ]
    }
}

/// The store's migration plan: every released stage through V13, unchanged,
/// plus the V13 -> V14 stage.
enum LocalLibraryV14MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LocalLibraryMigrationPlan.schemas + [LocalLibrarySchemaV14.self]
    }
    static var stages: [MigrationStage] {
        LocalLibraryMigrationPlan.stages + [
            .lightweight(fromVersion: LocalLibrarySchemaV13.self, toVersion: LocalLibrarySchemaV14.self),
        ]
    }
}

/// The current schema the store opens. Every seam that names "the current
/// schema" goes through these two aliases.
typealias LocalLibraryCurrentSchema = LocalLibrarySchemaV14
typealias LocalLibraryCurrentMigrationPlan = LocalLibraryV14MigrationPlan
