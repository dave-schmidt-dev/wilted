import Foundation
import SwiftData

enum LocalLibrarySchemaV23Models {
    /// Cue history for late offline captures after a prepared revision is replaced.
    @Model final class NotebookRevisionCuesRecord {
        @Attribute(.unique) var id: String
        var cues: Data

        init(id: String, cues: Data) {
            self.id = id
            self.cues = cues
        }
    }

    /// Notebook payload is encoded as one validated shared value. The local scope
    /// is intentionally outside the payload, so owner changes never merge offline rows.
    @Model final class NotebookEntryRecord {
        @Attribute(.unique) var id: String
        var scopeKey: String
        var entryID: String
        var payload: Data
        var serverVersion: Int64

        init(scopeKey: String, entryID: String, payload: Data, serverVersion: Int64 = 0) {
            id = Self.recordID(scopeKey: scopeKey, entryID: entryID)
            self.scopeKey = scopeKey
            self.entryID = entryID
            self.payload = payload
            self.serverVersion = serverVersion
        }

        static func recordID(scopeKey: String, entryID: String) -> String {
            "\(scopeKey.utf8.count):\(scopeKey)\(entryID)"
        }
    }
}

/// Adds the owner-partitioned Notebook payload table. All existing V22 entities
/// are carried forward unchanged; this migration does not rewrite their rows.
enum LocalLibrarySchemaV23: VersionedSchema {
    static let versionIdentifier = Schema.Version(23, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV22.models + [LocalLibrarySchemaV23Models.NotebookEntryRecord.self,
                                        LocalLibrarySchemaV23Models.NotebookRevisionCuesRecord.self]
    }
}

enum LocalLibraryV23MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LocalLibraryV22MigrationPlan.schemas + [LocalLibrarySchemaV23.self]
    }
    static var stages: [MigrationStage] {
        LocalLibraryV22MigrationPlan.stages + [
            .lightweight(fromVersion: LocalLibrarySchemaV22.self, toVersion: LocalLibrarySchemaV23.self),
        ]
    }
}

typealias LocalLibraryCurrentSchema = LocalLibrarySchemaV23
typealias LocalLibraryCurrentMigrationPlan = LocalLibraryV23MigrationPlan
typealias LocalLibraryCurrentSubscriptionRecord = LocalLibrarySchemaV18Models.PodcastSubscriptionRecord
