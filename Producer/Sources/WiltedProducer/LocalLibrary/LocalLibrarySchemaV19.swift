import Foundation
import SwiftData

enum LocalLibrarySchemaV19Models {
    /// Additive journal. Released entities retain their exact V18 shapes.
    @Model final class ManualCompletionReceiptRecord {
        @Attribute(.unique) var operationID: UUID
        var createdAt: Date
        var undoAvailableUntil: Date
        var members: Data
        var admissionEffectIDs: Data

        init(operationID: UUID, createdAt: Date, undoAvailableUntil: Date, members: Data) {
            self.operationID = operationID
            self.createdAt = createdAt
            self.undoAvailableUntil = undoAvailableUntil
            self.members = members
            self.admissionEffectIDs = Data("[]".utf8)
        }
    }
}

enum LocalLibrarySchemaV19: VersionedSchema {
    static let versionIdentifier = Schema.Version(19, 0, 0)
    static var models: [any PersistentModel.Type] {
        LocalLibrarySchemaV18.models + [LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord.self]
    }
}

enum LocalLibraryV19MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LocalLibraryV18MigrationPlan.schemas + [LocalLibrarySchemaV19.self]
    }
    static var stages: [MigrationStage] {
        LocalLibraryV18MigrationPlan.stages + [
            .lightweight(fromVersion: LocalLibrarySchemaV18.self, toVersion: LocalLibrarySchemaV19.self),
        ]
    }
}
