import Foundation
import SwiftData

public enum PersistenceProbeError: Error, CustomStringConvertible, Sendable {
    case unsupported(String)
    case invalidStore(URL, String)
    case invariant(String)

    public var description: String {
        switch self {
        case .unsupported(let detail): return "unsupported: \(detail)"
        case .invalidStore(let url, let detail): return "invalid store \(url.path): \(detail)"
        case .invariant(let detail): return "invariant: \(detail)"
        }
    }
}

public enum PersistenceSchemaVersion: Int, Codable, Sendable {
    case v1 = 1
    case v2 = 2
}

public struct ProbeArticle: Codable, Equatable, Sendable {
    public let id: String
    public let canonicalURL: String
    public let title: String
    public let source: String?
    public let createdAt: Date
    public let deleted: Bool

    public init(id: String, canonicalURL: String, title: String, source: String? = nil,
                createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000), deleted: Bool = false) {
        self.id = id; self.canonicalURL = canonicalURL; self.title = title; self.source = source
        self.createdAt = createdAt; self.deleted = deleted
    }
}

public struct ProbeRevision: Codable, Equatable, Sendable {
    public let id: String
    public let itemID: String
    public let duration: Double
    public let byteCount: Int
    public let contentHash: String
    public let mediaType: String
    public let mediaLocation: String?
    public let createdAt: Date
    public let readiness: String

    public init(id: String, itemID: String, duration: Double = 42, byteCount: Int = 128,
                contentHash: String = "hash", mediaType: String = "audio/m4a",
                mediaLocation: String? = nil, createdAt: Date = Date(timeIntervalSince1970: 1_700_000_001), readiness: String = "ready") {
        self.id = id; self.itemID = itemID; self.duration = duration; self.byteCount = byteCount
        self.contentHash = contentHash; self.mediaType = mediaType; self.mediaLocation = mediaLocation; self.createdAt = createdAt
        self.readiness = readiness
    }
}

public struct ProbePlayback: Codable, Equatable, Sendable {
    public let id: String
    public let itemID: String
    public let revisionID: String
    public let position: Double
    public let duration: Double
    public let completion: Bool
    public let intent: String
    public let deviceID: String
    public let encodedRecordSystemFields: Data?
    public let lastSeenChangeTag: Data?
    public let updatedAt: Date

    public init(id: String, itemID: String, revisionID: String, position: Double = 0,
                duration: Double = 42, completion: Bool = false, intent: String = "progress",
                deviceID: String = "probe-mac", encodedRecordSystemFields: Data? = nil,
                lastSeenChangeTag: Data? = nil, updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_002)) {
        self.id = id; self.itemID = itemID; self.revisionID = revisionID; self.position = position
        self.duration = duration; self.completion = completion; self.intent = intent
        self.deviceID = deviceID; self.encodedRecordSystemFields = encodedRecordSystemFields
        self.lastSeenChangeTag = lastSeenChangeTag; self.updatedAt = updatedAt
    }
}

public struct ProbeJournal: Codable, Equatable, Sendable {
    public let id: String
    public let itemID: String
    public let stage: String
    public let detail: String
    public let terminal: Bool
    public let error: String?
    public let updatedAt: Date

    public init(id: String, itemID: String, stage: String, detail: String,
                terminal: Bool = false, error: String? = nil,
                updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_003)) {
        self.id = id; self.itemID = itemID; self.stage = stage; self.detail = detail
        self.terminal = terminal; self.error = error; self.updatedAt = updatedAt
    }
}

public struct ProbeSyncState: Codable, Equatable, Sendable {
    public let key: String
    public let engineState: Data
    public let lastFetchAt: Date?
    public let lastSendAt: Date?

    public init(key: String = "private-zone", engineState: Data = Data([1, 2, 3]),
                lastFetchAt: Date? = Date(timeIntervalSince1970: 1_700_000_004), lastSendAt: Date? = nil) {
        self.key = key; self.engineState = engineState
        self.lastFetchAt = lastFetchAt; self.lastSendAt = lastSendAt
    }
}

public struct ProbeTombstone: Codable, Equatable, Sendable {
    public let id: String
    public let itemID: String
    public let deletedAt: Date
    public let remoteAcknowledged: Bool

    public init(id: String, itemID: String, deletedAt: Date = Date(timeIntervalSince1970: 1_700_000_005), remoteAcknowledged: Bool = false) {
        self.id = id; self.itemID = itemID; self.deletedAt = deletedAt; self.remoteAcknowledged = remoteAcknowledged
    }
}

public struct PersistenceInspection: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let articles: Int
    public let revisions: Int
    public let playback: Int
    public let journal: Int
    public let syncState: Int
    public let tombstones: Int

    public var total: Int { articles + revisions + playback + journal + syncState + tombstones }
}

// Keep the entity names stable across schema versions. SwiftData derives the
// persistent entity name from the nested type name, not its schema namespace.
//
// The deletion flag is `isRemoved` for the reason spelled out in
// `LocalLibraryStore`: SwiftData reserves both `isDeleted` and `deleted`, and a
// `@Model` property using either reads back `false` no matter what is on disk.
// This probe exists to catch persistence defects, so a field it cannot read
// back would make its own deletion check vacuous.
enum PersistenceSchemaV1Models {
    @Model final class ArticleRecord {
        @Attribute(.unique) var id: String; var canonicalURL: String; var title: String; var createdAt: Date; var isRemoved: Bool; var schemaVersion: Int
        init(id: String, canonicalURL: String, title: String, createdAt: Date, deleted: Bool, schemaVersion: Int) { self.id=id; self.canonicalURL=canonicalURL; self.title=title; self.createdAt=createdAt; self.isRemoved=deleted; self.schemaVersion=schemaVersion }
    }
    @Model final class RevisionRecord {
        @Attribute(.unique) var id: String; var itemID: String; var duration: Double; var byteCount: Int; var contentHash: String; var mediaType: String; var createdAt: Date; var readiness: String; var schemaVersion: Int
        init(id:String,itemID:String,duration:Double,byteCount:Int,contentHash:String,mediaType:String,createdAt:Date,readiness:String,schemaVersion:Int){self.id=id;self.itemID=itemID;self.duration=duration;self.byteCount=byteCount;self.contentHash=contentHash;self.mediaType=mediaType;self.createdAt=createdAt;self.readiness=readiness;self.schemaVersion=schemaVersion}
    }
    @Model final class PlaybackRecord {
        @Attribute(.unique) var id:String; var itemID:String; var revisionID:String; var position:Double; var duration:Double; var completion:Bool; var intent:String; var deviceID:String; var updatedAt:Date; var schemaVersion:Int
        init(_ v:ProbePlayback,schemaVersion:Int){id=v.id;itemID=v.itemID;revisionID=v.revisionID;position=v.position;duration=v.duration;completion=v.completion;intent=v.intent;deviceID=v.deviceID;updatedAt=v.updatedAt;self.schemaVersion=schemaVersion}
    }
    @Model final class JournalRecord {
        @Attribute(.unique) var id:String; var itemID:String; var stage:String; var detail:String; var terminal:Bool; var error:String?; var updatedAt:Date; var schemaVersion:Int
        init(_ v:ProbeJournal,schemaVersion:Int){id=v.id;itemID=v.itemID;stage=v.stage;detail=v.detail;terminal=v.terminal;error=v.error;updatedAt=v.updatedAt;self.schemaVersion=schemaVersion}
    }
    @Model final class SyncStateRecord {
        @Attribute(.unique) var key:String; var recordSystemFields:Data?; var lastFetchAt:Date?; var lastSendAt:Date?; var schemaVersion:Int
        init(_ v:ProbeSyncState,schemaVersion:Int){key=v.key;recordSystemFields=v.engineState;lastFetchAt=v.lastFetchAt;lastSendAt=v.lastSendAt;self.schemaVersion=schemaVersion}
    }
    @Model final class TombstoneRecord {
        @Attribute(.unique) var id:String; var itemID:String; var deletedAt:Date; var remoteAcknowledged:Bool; var schemaVersion:Int
        init(_ v:ProbeTombstone,schemaVersion:Int){id=v.id;itemID=v.itemID;deletedAt=v.deletedAt;remoteAcknowledged=v.remoteAcknowledged;self.schemaVersion=schemaVersion}
    }
}

enum PersistenceSchemaV2Models {
    @Model final class ArticleRecord {
        @Attribute(.unique) var id: String; var canonicalURL: String; var title: String; var source: String?; var createdAt: Date; var isRemoved: Bool; var schemaVersion: Int
        init(_ v:ProbeArticle,schemaVersion:Int=2){id=v.id;canonicalURL=v.canonicalURL;title=v.title;source=v.source;createdAt=v.createdAt;isRemoved=v.deleted;self.schemaVersion=schemaVersion}
    }
    @Model final class RevisionRecord {
        @Attribute(.unique) var id:String; var itemID:String; var duration:Double; var byteCount:Int; var contentHash:String; var mediaType:String; var mediaLocation:String?; var createdAt:Date; var readiness:String; var schemaVersion:Int
        init(_ v:ProbeRevision,schemaVersion:Int=2){id=v.id;itemID=v.itemID;duration=v.duration;byteCount=v.byteCount;contentHash=v.contentHash;mediaType=v.mediaType;mediaLocation=v.mediaLocation;createdAt=v.createdAt;readiness=v.readiness;self.schemaVersion=schemaVersion}
    }
    @Model final class PlaybackRecord {
        @Attribute(.unique) var id:String; var itemID:String; var revisionID:String; var position:Double; var duration:Double; var completion:Bool; var intent:String; var deviceID:String; var encodedRecordSystemFields:Data?; var lastSeenChangeTag:Data?; var updatedAt:Date; var schemaVersion:Int
        init(_ v:ProbePlayback,schemaVersion:Int=2){id=v.id;itemID=v.itemID;revisionID=v.revisionID;position=v.position;duration=v.duration;completion=v.completion;intent=v.intent;deviceID=v.deviceID;encodedRecordSystemFields=v.encodedRecordSystemFields;lastSeenChangeTag=v.lastSeenChangeTag;updatedAt=v.updatedAt;self.schemaVersion=schemaVersion}
    }
    @Model final class JournalRecord {
        @Attribute(.unique) var id:String; var itemID:String; var stage:String; var detail:String; var terminal:Bool; var error:String?; var updatedAt:Date; var schemaVersion:Int
        init(_ v:ProbeJournal,schemaVersion:Int=2){id=v.id;itemID=v.itemID;stage=v.stage;detail=v.detail;terminal=v.terminal;error=v.error;updatedAt=v.updatedAt;self.schemaVersion=schemaVersion}
    }
    @Model final class SyncStateRecord {
        // v1 had only legacy record-system fields; empty is the explicit
        // migration sentinel until a real CKSyncEngine state is saved.
        @Attribute(.unique) var key:String; var engineState:Data = Data(); var lastFetchAt:Date?; var lastSendAt:Date?; var schemaVersion:Int
        init(_ v:ProbeSyncState,schemaVersion:Int=2){key=v.key;engineState=v.engineState;lastFetchAt=v.lastFetchAt;lastSendAt=v.lastSendAt;self.schemaVersion=schemaVersion}
    }
    @Model final class TombstoneRecord {
        @Attribute(.unique) var id:String; var itemID:String; var deletedAt:Date; var remoteAcknowledged:Bool; var schemaVersion:Int
        init(_ v:ProbeTombstone,schemaVersion:Int=2){id=v.id;itemID=v.itemID;deletedAt=v.deletedAt;remoteAcknowledged=v.remoteAcknowledged;self.schemaVersion=schemaVersion}
    }
}

enum PersistenceSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PersistenceSchemaV1Models.ArticleRecord.self, PersistenceSchemaV1Models.RevisionRecord.self, PersistenceSchemaV1Models.PlaybackRecord.self, PersistenceSchemaV1Models.JournalRecord.self, PersistenceSchemaV1Models.SyncStateRecord.self, PersistenceSchemaV1Models.TombstoneRecord.self]
    }
}

enum PersistenceSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PersistenceSchemaV2Models.ArticleRecord.self, PersistenceSchemaV2Models.RevisionRecord.self, PersistenceSchemaV2Models.PlaybackRecord.self, PersistenceSchemaV2Models.JournalRecord.self, PersistenceSchemaV2Models.SyncStateRecord.self, PersistenceSchemaV2Models.TombstoneRecord.self]
    }
}

enum PersistenceMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PersistenceSchemaV1.self, PersistenceSchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: PersistenceSchemaV1.self, toVersion: PersistenceSchemaV2.self)] }
}

public enum PersistenceStoreURL {
    public static func deterministic(named name: String, root: URL? = nil) -> URL {
        let base = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("wilted-persistence-probe", isDirectory: true)
        return base.appendingPathComponent(name, isDirectory: true).appendingPathComponent("store.sqlite")
    }

    public static func reset(_ url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

private func configuration(schema: Schema, url: URL) -> ModelConfiguration {
    ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
}

public actor PersistenceStore {
    private let container: ModelContainer
    public let url: URL

    public init(url: URL, migrate: Bool = true) throws {
        self.url = url
        let schema = Schema(versionedSchema: PersistenceSchemaV2.self)
        let config = configuration(schema: schema, url: url)
        if migrate {
            container = try ModelContainer(for: schema, migrationPlan: PersistenceMigrationPlan.self, configurations: [config])
        } else {
            container = try ModelContainer(for: schema, configurations: [config])
        }
    }

    public func save(article: ProbeArticle) throws {
        let context = ModelContext(container); context.insert(PersistenceSchemaV2Models.ArticleRecord(article)); try context.save()
    }
    public func save(revision: ProbeRevision) throws {
        let context = ModelContext(container); context.insert(PersistenceSchemaV2Models.RevisionRecord(revision)); try context.save()
    }
    public func save(playback: ProbePlayback) throws {
        let context = ModelContext(container); context.insert(PersistenceSchemaV2Models.PlaybackRecord(playback)); try context.save()
    }
    public func record(journal: ProbeJournal) throws {
        let context = ModelContext(container); context.insert(PersistenceSchemaV2Models.JournalRecord(journal)); try context.save()
    }
    public func save(syncState: ProbeSyncState) throws {
        let context = ModelContext(container); context.insert(PersistenceSchemaV2Models.SyncStateRecord(syncState)); try context.save()
    }
    public func save(tombstone: ProbeTombstone) throws {
        let context = ModelContext(container); context.insert(PersistenceSchemaV2Models.TombstoneRecord(tombstone)); try context.save()
    }

    public func fetchArticle(id: String) throws -> ProbeArticle? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PersistenceSchemaV2Models.ArticleRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        return ProbeArticle(id: record.id, canonicalURL: record.canonicalURL, title: record.title,
                            source: record.source, createdAt: record.createdAt, deleted: record.isRemoved)
    }

    public func fetchPlayback(id: String) throws -> ProbePlayback? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PersistenceSchemaV2Models.PlaybackRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        return ProbePlayback(id: record.id, itemID: record.itemID, revisionID: record.revisionID,
                             position: record.position, duration: record.duration, completion: record.completion,
                             intent: record.intent, deviceID: record.deviceID,
                             encodedRecordSystemFields: record.encodedRecordSystemFields,
                             lastSeenChangeTag: record.lastSeenChangeTag, updatedAt: record.updatedAt)
    }

    public func fetchSyncState(key: String) throws -> ProbeSyncState? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PersistenceSchemaV2Models.SyncStateRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        return ProbeSyncState(key: record.key, engineState: record.engineState,
                              lastFetchAt: record.lastFetchAt, lastSendAt: record.lastSendAt)
    }

    public func inspect() throws -> PersistenceInspection {
        let context = ModelContext(container)
        let articles = try context.fetchCount(FetchDescriptor<PersistenceSchemaV2Models.ArticleRecord>())
        let revisions = try context.fetchCount(FetchDescriptor<PersistenceSchemaV2Models.RevisionRecord>())
        let playback = try context.fetchCount(FetchDescriptor<PersistenceSchemaV2Models.PlaybackRecord>())
        let journal = try context.fetchCount(FetchDescriptor<PersistenceSchemaV2Models.JournalRecord>())
        let syncState = try context.fetchCount(FetchDescriptor<PersistenceSchemaV2Models.SyncStateRecord>())
        let tombstones = try context.fetchCount(FetchDescriptor<PersistenceSchemaV2Models.TombstoneRecord>())
        return PersistenceInspection(schemaVersion: PersistenceSchemaVersion.v2.rawValue, articles: articles,
                                     revisions: revisions, playback: playback, journal: journal,
                                     syncState: syncState, tombstones: tombstones)
    }
}

public enum PersistenceProbeScenarios {
    public static func populateAll(_ store: PersistenceStore, prefix: String = "fixture") async throws {
        let article = ProbeArticle(id: "\(prefix)-article", canonicalURL: "https://example.test/article", title: "Probe article", source: "example.test")
        let revision = ProbeRevision(id: "\(prefix)-revision", itemID: article.id, mediaLocation: "/tmp/\(prefix)-audio.m4a")
        try await store.save(article: article)
        try await store.save(revision: revision)
        try await store.save(playback: ProbePlayback(id: "\(prefix)-playback", itemID: article.id, revisionID: revision.id, position: 12, encodedRecordSystemFields: Data([9, 8]), lastSeenChangeTag: Data([7, 6])))
        try await store.record(journal: ProbeJournal(id: "\(prefix)-journal", itemID: article.id, stage: "saved", detail: "durable"))
        try await store.save(syncState: ProbeSyncState(key: "\(prefix)-zone", engineState: Data([1, 2, 3, 4])))
        try await store.save(tombstone: ProbeTombstone(id: "\(prefix)-tombstone", itemID: "deleted-item"))
    }

    public static func concurrentJournalWrites(_ store: PersistenceStore, count: Int = 24) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await store.record(journal: ProbeJournal(id: "concurrent-\(index)", itemID: "concurrent-item", stage: "callback", detail: "write-\(index)"))
                }
            }
            try await group.waitForAll()
        }
    }

    public static func createV1Store(at url: URL) throws {
        let schema = Schema(versionedSchema: PersistenceSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [configuration(schema: schema, url: url)])
        let context = ModelContext(container)
        context.insert(PersistenceSchemaV1Models.ArticleRecord(id: "migration-article", canonicalURL: "https://example.test/v1", title: "Version one", createdAt: Date(timeIntervalSince1970: 1_700_000_010), deleted: false, schemaVersion: 1))
        let legacySyncState = PersistenceSchemaV1Models.SyncStateRecord(ProbeSyncState(key: "migration-zone"), schemaVersion: 1)
        legacySyncState.recordSystemFields = nil
        context.insert(legacySyncState)
        try context.save()
    }
}
