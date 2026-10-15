import Foundation
import SwiftData

enum LocalLibrarySchemaV20Models {
    /// Association history is additive; backing source and receipt entities are frozen.
    @Model final class EpisodeAssociationRecord {
        @Attribute(.unique) var associationID: UUID
        var feedID: String
        var representativeID: String
        var members: Data
        var evidence: Data
        var version: Int
        var isActive: Bool
        var createdAt: Date
        var reversedAt: Date?
        var capturedMemberState: Data
        var manualChoiceConflicts: Data

        init(associationID: UUID, feedID: String, representativeID: String,
             members: Data, evidence: Data, createdAt: Date, capturedMemberState: Data) {
            self.associationID = associationID
            self.feedID = feedID
            self.representativeID = representativeID
            self.members = members
            self.evidence = evidence
            self.version = 1
            self.isActive = true
            self.createdAt = createdAt
            self.reversedAt = nil
            self.capturedMemberState = capturedMemberState
            self.manualChoiceConflicts = Data("[]".utf8)
        }
    }
}

enum LocalLibrarySchemaV20: VersionedSchema {
    static let versionIdentifier = Schema.Version(20, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV19.models + [LocalLibrarySchemaV20Models.EpisodeAssociationRecord.self]
    }
}

enum LocalLibraryV20MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LocalLibraryV19MigrationPlan.schemas + [LocalLibrarySchemaV20.self]
    }
    static var stages: [MigrationStage] {
        LocalLibraryV19MigrationPlan.stages + [
            .lightweight(fromVersion: LocalLibrarySchemaV19.self, toVersion: LocalLibrarySchemaV20.self),
        ]
    }
}

typealias LocalLibraryCurrentSchema = LocalLibrarySchemaV20
typealias LocalLibraryCurrentMigrationPlan = LocalLibraryV20MigrationPlan
typealias LocalLibraryCurrentSubscriptionRecord = LocalLibrarySchemaV18Models.PodcastSubscriptionRecord
