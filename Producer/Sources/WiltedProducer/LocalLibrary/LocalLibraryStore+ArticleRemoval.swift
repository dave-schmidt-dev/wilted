import Foundation
import SwiftData
import WiltedDomain

/// A persistence stage of a confirmed, destructive library removal.
///
/// Each removal stages its record changes in one `ModelContext` and commits
/// them with one save. A stage names the group of changes staged when the
/// operation stopped, so a caller can report where a removal failed.
public enum LocalLibraryRemovalStage: String, CaseIterable, Sendable {
    case articleFlag
    case articleTombstone
    case subscription
    case feed
    case episodes
    case queue
    case downloads
    case playbackSpeeds
    case artwork
    case revisions
    case transcripts
    case playback
    /// The single commit of everything staged before it.
    case save

    /// The stages `removeArticle(itemID:at:)` passes through, in order.
    public static let articleRemoval: [Self] = [.articleFlag, .articleTombstone, .save]
    /// The stages `unsubscribeFromPodcast(feedID:)` passes through, in order.
    public static let unsubscribe: [Self] = [
        .subscription, .feed, .episodes, .queue, .downloads, .playbackSpeeds,
        .artwork, .revisions, .transcripts, .playback, .save,
    ]
}

/// A confirmed removal that did not commit.
///
/// Thrown only before the operation's single save succeeds, so no record
/// changed: the caller keeps its visible row, selection and player state and
/// may offer a retry.
public struct LocalLibraryRemovalError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Operation: String, Sendable {
        case removeArticle
        case unsubscribe
    }

    public let operation: Operation
    public let stage: LocalLibraryRemovalStage
    /// The underlying failure, for logs. Not shown to the listener.
    public let reason: String

    public init(operation: Operation, stage: LocalLibraryRemovalStage, reason: String) {
        self.operation = operation
        self.stage = stage
        self.reason = reason
    }

    public var description: String { "\(operation.rawValue) failed at \(stage.rawValue): \(reason)" }
}

extension LocalLibraryStore {
    #if DEBUG
    /// Test-only failure seam. When bound, it runs after each removal stage is
    /// staged and before the commit, and a throw aborts the removal there.
    /// Task-local, so it reaches only removals awaited inside `withValue` and
    /// never another test or the running app.
    @TaskLocal static var removalStageObserver: (@Sendable (LocalLibraryRemovalStage) throws -> Void)?
    #endif

    /// Runs the test seam for `stage`. A no-op unless a test bound one.
    static func reachRemovalStage(_ stage: LocalLibraryRemovalStage) throws {
        #if DEBUG
        try removalStageObserver?(stage)
        #endif
    }

    /// Runs one removal body, converting any failure into a typed
    /// `LocalLibraryRemovalError` that names the stage reached.
    static func performRemoval<Result>(
        _ operation: LocalLibraryRemovalError.Operation,
        startingAt first: LocalLibraryRemovalStage,
        _ body: (inout LocalLibraryRemovalStage) throws -> Result
    ) throws -> Result {
        var stage = first
        do {
            return try body(&stage)
        } catch let error as LocalLibraryRemovalError {
            throw error
        } catch {
            throw LocalLibraryRemovalError(operation: operation, stage: stage, reason: String(describing: error))
        }
    }

    /// Removes an article: marks it deleted and records its sync tombstone in
    /// one `ModelContext` save, so the flag and the tombstone commit together
    /// or not at all.
    ///
    /// The tombstone is keyed by item (`id == itemID.rawValue`), the shape
    /// `refresh()` and the sync repository already read. An existing
    /// tombstone keeps its remote acknowledgement, as `record(tombstone:)`
    /// does. Records only: no media file is deleted, and there is no undo.
    ///
    /// Idempotent. An article that is already removed and already has its
    /// tombstone writes nothing and returns false, so a duplicate confirm
    /// coalesces. An article flagged by the earlier two-save path without its
    /// tombstone gets the tombstone and returns true. An unknown article
    /// returns false and writes nothing.
    ///
    /// - Throws: `LocalLibraryRemovalError` when nothing was committed.
    @discardableResult
    public func removeArticle(itemID: ItemID, at requestedAt: Timestamp = Timestamp(Date())) throws -> Bool {
        try Self.performRemoval(.removeArticle, startingAt: .articleFlag) { stage in
            let context = ModelContext(container)
            let identifier = itemID.rawValue
            var articleQuery = FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>(
                predicate: #Predicate { $0.id == identifier })
            articleQuery.fetchLimit = 1
            guard let article = try context.fetch(articleQuery).first else { return false }
            var tombstoneQuery = FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>(
                predicate: #Predicate { $0.id == identifier })
            tombstoneQuery.fetchLimit = 1
            let tombstone = try context.fetch(tombstoneQuery).first
            if article.isRemoved, tombstone != nil { return false }

            if !article.isRemoved {
                article.isRemoved = true
                article.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
            }
            try Self.reachRemovalStage(.articleFlag)

            stage = .articleTombstone
            if let tombstone {
                tombstone.itemID = identifier
                tombstone.generationID = nil
                tombstone.requestedAt = requestedAt.date
                tombstone.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
            } else {
                context.insert(LocalLibrarySchemaV3Models.TombstoneRecord(
                    LocalLibraryTombstone(id: identifier, itemID: itemID, requestedAt: requestedAt)))
            }
            try Self.reachRemovalStage(.articleTombstone)

            stage = .save
            try Self.reachRemovalStage(.save)
            try context.save()
            return true
        }
    }
}
