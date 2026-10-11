import Foundation
import SwiftData

enum LocalLibrarySchemaV18Models {
    /// V6 subscription identity and admission metadata plus an optional owner name.
    @Model final class PodcastSubscriptionRecord {
        @Attribute(.unique) var feedID: String
        var subscribedAt: Date
        var enabled: Bool
        var displayName: String?

        init(_ value: PodcastSubscription) {
            feedID = value.feedID.rawValue
            subscribedAt = value.subscribedAt.date
            enabled = value.enabled
            displayName = value.displayName
        }
    }
}

/// Adds only the nullable owner display name, preserving every released V17 entity.
enum LocalLibrarySchemaV18: VersionedSchema {
    static let versionIdentifier = Schema.Version(18, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV17.models.filter {
            $0 != LocalLibrarySchemaV6Models.PodcastSubscriptionRecord.self
        } + [LocalLibrarySchemaV18Models.PodcastSubscriptionRecord.self]
    }
}

enum LocalLibraryV18MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LocalLibraryV17MigrationPlan.schemas + [LocalLibrarySchemaV18.self]
    }
    static var stages: [MigrationStage] {
        LocalLibraryV17MigrationPlan.stages + [
            .lightweight(fromVersion: LocalLibrarySchemaV17.self, toVersion: LocalLibrarySchemaV18.self),
        ]
    }
}

typealias LocalLibraryCurrentSchema = LocalLibrarySchemaV18
typealias LocalLibraryCurrentMigrationPlan = LocalLibraryV18MigrationPlan
typealias LocalLibraryCurrentSubscriptionRecord = LocalLibrarySchemaV18Models.PodcastSubscriptionRecord
