import Foundation
import SwiftData
import WiltedDomain

enum LocalLibrarySchemaV15Models {
    /// An episode's own web page, from the feed item's `<link>`. A separate
    /// entity beside the unchanged V13 episode row, keyed by the episode's
    /// `itemID`, so adding it is a lightweight "new table" stage and no V13
    /// episode record changes shape. At most one row per episode; the row is
    /// deleted with the episode and is absent when the feed publishes no link.
    @Model final class PodcastEpisodeLinkRecord {
        @Attribute(.unique) var itemID: String
        var url: String
        var updatedAt: Date

        init(itemID: String, url: String, updatedAt: Date) {
            self.itemID = itemID
            self.url = url
            self.updatedAt = updatedAt
        }
    }
}

/// Version 15 adds the episode page link. Lightweight: one wholly new table,
/// and no existing entity changes shape.
enum LocalLibrarySchemaV15: VersionedSchema {
    static let versionIdentifier = Schema.Version(15, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV14.models + [
            LocalLibrarySchemaV15Models.PodcastEpisodeLinkRecord.self,
        ]
    }
}

/// The store's migration plan: every released stage through V14, unchanged,
/// plus the V14 -> V15 stage.
enum LocalLibraryV15MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LocalLibraryV14MigrationPlan.schemas + [LocalLibrarySchemaV15.self]
    }
    static var stages: [MigrationStage] {
        LocalLibraryV14MigrationPlan.stages + [
            .lightweight(fromVersion: LocalLibrarySchemaV14.self, toVersion: LocalLibrarySchemaV15.self),
        ]
    }
}
