import Foundation
import SwiftData
import WiltedDomain

enum LocalLibrarySchemaV22Models {
    /// V12's work ticket verbatim, plus the two deferral columns
    /// `deferRunningWorkTicket` writes. Both are optional with no default
    /// value, so every row written before V22 opens with them nil.
    @Model final class WorkTicketRecord {
        @Attribute(.unique) var id: String
        var kind: String
        var subjectID: String
        var resolvedItemID: String?
        var requestSequence: Int
        var state: String
        var attemptCount: Int
        var failureKind: String?
        var lastFailureMessage: String?
        var nextEligibleAt: Date?
        var policySnapshot: Data?
        var processingPolicy: Data?
        var runID: String?
        var requestedAt: Date
        var updatedAt: Date
        var firstDeferredAt: Date?
        var deferralCount: Int?

        init(_ value: WorkTicket) {
            id = value.id
            kind = value.kind.rawValue
            subjectID = value.subjectID
            resolvedItemID = value.resolvedItemID
            requestSequence = value.requestSequence
            state = value.state.rawValue
            attemptCount = value.attemptCount
            failureKind = value.failureKind
            lastFailureMessage = value.lastFailureMessage
            nextEligibleAt = value.nextEligibleAt?.date
            policySnapshot = value.policySnapshot
            processingPolicy = value.processingPolicy
            runID = value.runID
            requestedAt = value.requestedAt.date
            updatedAt = value.updatedAt.date
            firstDeferredAt = value.firstDeferredAt?.date
            deferralCount = value.deferralCount
        }

        /// Overwrites every field but `id`/`kind`/`subjectID`. A re-admission
        /// keeps that durable key but replaces its attempt identity and intake
        /// time with the newer request.
        func apply(_ value: WorkTicket) {
            resolvedItemID = value.resolvedItemID
            requestSequence = value.requestSequence
            state = value.state.rawValue
            attemptCount = value.attemptCount
            failureKind = value.failureKind
            lastFailureMessage = value.lastFailureMessage
            nextEligibleAt = value.nextEligibleAt?.date
            policySnapshot = value.policySnapshot
            processingPolicy = value.processingPolicy
            runID = value.runID
            requestedAt = value.requestedAt.date
            updatedAt = value.updatedAt.date
            firstDeferredAt = value.firstDeferredAt?.date
            deferralCount = value.deferralCount
        }
    }
}

/// Adds the first-deferral time and deferral count to the work ticket.
/// Lightweight: two optional columns on one existing entity, the same shape
/// V13's `removalKind` already carries.
enum LocalLibrarySchemaV22: VersionedSchema {
    static let versionIdentifier = Schema.Version(22, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV21.models.filter {
            $0 != LocalLibrarySchemaV12Models.WorkTicketRecord.self
        } + [
            LocalLibrarySchemaV22Models.WorkTicketRecord.self,
        ]
    }
}

enum LocalLibraryV22MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LocalLibraryV21MigrationPlan.schemas + [LocalLibrarySchemaV22.self]
    }
    static var stages: [MigrationStage] {
        LocalLibraryV21MigrationPlan.stages + [
            .lightweight(fromVersion: LocalLibrarySchemaV21.self, toVersion: LocalLibrarySchemaV22.self),
        ]
    }
}

typealias LocalLibraryCurrentSchema = LocalLibrarySchemaV22
typealias LocalLibraryCurrentMigrationPlan = LocalLibraryV22MigrationPlan
typealias LocalLibraryCurrentSubscriptionRecord = LocalLibrarySchemaV18Models.PodcastSubscriptionRecord
