import Foundation
import SwiftData

enum LocalLibrarySchemaV16Models {
    @Model final class PodcastFeedPolicyRecord {
        @Attribute(.unique) var feedID: String
        var autoKeep: String
        var autoDownload: String
        var autoPrepare: String
        var keptLimit: Int?
        var updatedAt: Date

        init(feedID: String, autoKeep: String, autoDownload: String, autoPrepare: String,
             keptLimit: Int?, updatedAt: Date) {
            self.feedID = feedID; self.autoKeep = autoKeep; self.autoDownload = autoDownload
            self.autoPrepare = autoPrepare; self.keptLimit = keptLimit; self.updatedAt = updatedAt
        }
    }

    @Model final class EpisodeMatchRuleRecord {
        @Attribute(.unique) var id: UUID
        var feedID: String
        var order: Int
        var field: String
        var includePattern: String
        var excludePattern: String?
        var action: String
        var enabled: Bool
        var updatedAt: Date

        init(id: UUID, feedID: String, order: Int, field: String, includePattern: String,
             excludePattern: String?, action: String, enabled: Bool, updatedAt: Date) {
            self.id = id; self.feedID = feedID; self.order = order; self.field = field
            self.includePattern = includePattern; self.excludePattern = excludePattern
            self.action = action; self.enabled = enabled; self.updatedAt = updatedAt
        }
    }

    @Model final class EpisodeDecisionRecord {
        @Attribute(.unique) var episodeID: String
        var decision: String
        var source: String
        var ruleID: UUID?
        var decidedAt: Date

        init(episodeID: String, decision: String, source: String, ruleID: UUID?, decidedAt: Date) {
            self.episodeID = episodeID; self.decision = decision; self.source = source
            self.ruleID = ruleID; self.decidedAt = decidedAt
        }
    }
}

/// Version 16 adds the automation policy, ordered rule, and episode-decision
/// tables. Every prior entity remains unchanged, so V15 -> V16 is lightweight.
enum LocalLibrarySchemaV16: VersionedSchema {
    static let versionIdentifier = Schema.Version(16, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV15.models + [
            LocalLibrarySchemaV16Models.PodcastFeedPolicyRecord.self,
            LocalLibrarySchemaV16Models.EpisodeMatchRuleRecord.self,
            LocalLibrarySchemaV16Models.EpisodeDecisionRecord.self,
        ]
    }
}

enum LocalLibraryV16MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LocalLibraryV15MigrationPlan.schemas + [LocalLibrarySchemaV16.self]
    }
    static var stages: [MigrationStage] {
        LocalLibraryV15MigrationPlan.stages + [
            .lightweight(fromVersion: LocalLibrarySchemaV15.self, toVersion: LocalLibrarySchemaV16.self),
        ]
    }
}

