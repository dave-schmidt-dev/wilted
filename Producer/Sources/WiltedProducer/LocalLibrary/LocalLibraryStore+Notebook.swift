import Foundation
import SwiftData
import WiltedDomain
import WiltedLibrary

public enum LibraryNotebookStoreError: Error, Equatable, Sendable {
    case tombstoneCannotBeReused
    case staleVersion(expected: UInt64, actual: UInt64)
    case invalidVersion
}

extension LocalLibraryStore {
    /// Returns the records held by exactly one local owner partition.
    /// Tombstones are included by default so they remain publishable.
    public func notebookEntries(
        in scope: NotebookLocalScope, includingDeleted: Bool = true
    ) throws -> [LibraryNotebookEntry] {
        let context = ModelContext(container)
        let scopeKey = scope.persistenceKey
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV23Models.NotebookEntryRecord>(
            predicate: #Predicate { $0.scopeKey == scopeKey }
        ))
        return records.compactMap { record in
            guard let entry = try? JSONDecoder().decode(LibraryNotebookEntry.self, from: record.payload),
                  includingDeleted || !entry.isDeleted else { return nil }
            return entry
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    /// Reads one record without crossing a local owner partition.
    public func notebookEntry(id: ItemID, in scope: NotebookLocalScope) throws -> LibraryNotebookEntry? {
        guard let record = try notebookRecord(id: id, in: scope, context: ModelContext(container)) else { return nil }
        return try JSONDecoder().decode(LibraryNotebookEntry.self, from: record.payload)
    }

    /// Current server revision observed for this exact locally mirrored record.
    public func notebookServerVersion(id: ItemID, in scope: NotebookLocalScope) throws -> UInt64 {
        let record = try notebookRecord(id: id, in: scope, context: ModelContext(container))
        guard let record, record.serverVersion >= 0 else { return 0 }
        return UInt64(record.serverVersion)
    }

    /// Saves a local edit, optionally requiring the exact server version a phone
    /// intent was based on. A tombstoned ID can never become live again.
    @discardableResult
    public func saveNotebookEntry(
        _ value: LibraryNotebookEntry, in scope: NotebookLocalScope,
        expectedServerVersion: UInt64? = nil
    ) throws -> UInt64 {
        let entry = try validatedNotebookEntry(value)
        let context = ModelContext(container)
        let existing = try notebookRecord(id: entry.id, in: scope, context: context)
        let actual = existing.flatMap { $0.serverVersion >= 0 ? UInt64($0.serverVersion) : nil } ?? 0
        if let expectedServerVersion, expectedServerVersion != actual {
            throw LibraryNotebookStoreError.staleVersion(expected: expectedServerVersion, actual: actual)
        }
        if let existing {
            let previous = try JSONDecoder().decode(LibraryNotebookEntry.self, from: existing.payload)
            if previous.isDeleted && !entry.isDeleted { throw LibraryNotebookStoreError.tombstoneCannotBeReused }
            existing.payload = try JSONEncoder().encode(entry)
        } else {
            if entry.isDeleted { throw LibraryNotebookStoreError.tombstoneCannotBeReused }
            context.insert(LocalLibrarySchemaV23Models.NotebookEntryRecord(
                scopeKey: scope.persistenceKey, entryID: entry.id.rawValue,
                payload: try JSONEncoder().encode(entry)
            ))
        }
        try context.save()
        return actual
    }

    /// Applies a fetched versioned record atomically. Older echoes are ignored;
    /// equal-version mismatches and tombstone resurrection fail closed.
    @discardableResult
    public func applyRemoteNotebookEntry(
        _ value: LibraryNotebookEntry, version: UInt64, in scope: NotebookLocalScope
    ) throws -> Bool {
        guard version > 0, version <= UInt64(Int64.max) else { throw LibraryNotebookStoreError.invalidVersion }
        let entry = try validatedNotebookEntry(value)
        let context = ModelContext(container)
        let existing = try notebookRecord(id: entry.id, in: scope, context: context)
        let current = existing.flatMap { $0.serverVersion >= 0 ? UInt64($0.serverVersion) : nil } ?? 0
        guard version > current else { return false }
        if let existing {
            let previous = try JSONDecoder().decode(LibraryNotebookEntry.self, from: existing.payload)
            if previous.isDeleted && !entry.isDeleted { throw LibraryNotebookStoreError.tombstoneCannotBeReused }
            existing.payload = try JSONEncoder().encode(entry)
            existing.serverVersion = Int64(version)
        } else {
            context.insert(LocalLibrarySchemaV23Models.NotebookEntryRecord(
                scopeKey: scope.persistenceKey, entryID: entry.id.rawValue,
                payload: try JSONEncoder().encode(entry), serverVersion: Int64(version)
            ))
        }
        try context.save()
        return true
    }

    /// Records a CloudKit acknowledgement only if the exact value is still local.
    /// A later edit cannot inherit an earlier send's version.
    public func acknowledgeNotebookEntry(
        _ value: LibraryNotebookEntry, version: UInt64, in scope: NotebookLocalScope
    ) throws -> Bool {
        guard version > 0, version <= UInt64(Int64.max) else { throw LibraryNotebookStoreError.invalidVersion }
        let entry = try validatedNotebookEntry(value)
        let context = ModelContext(container)
        guard let record = try notebookRecord(id: entry.id, in: scope, context: context),
              try JSONDecoder().decode(LibraryNotebookEntry.self, from: record.payload) == entry else { return false }
        record.serverVersion = Int64(version)
        try context.save()
        return true
    }

    /// Writes a durable tombstone. The caller retains the original value for Undo;
    /// restoring creates a new identity below rather than clearing this marker.
    public func tombstoneNotebookEntry(
        id: ItemID, in scope: NotebookLocalScope, at date: Date = Date()
    ) throws -> LibraryNotebookEntry? {
        guard var entry = try notebookEntry(id: id, in: scope), !entry.isDeleted else { return nil }
        entry.deletedAt = date
        entry.updatedAt = date
        _ = try saveNotebookEntry(entry, in: scope)
        return entry
    }

    /// Restores the content of a tombstone under a fresh ID, preserving the old
    /// server tombstone so delayed writes cannot revive the deleted identity.
    public func restoreNotebookEntry(
        id: ItemID, as newID: ItemID, in scope: NotebookLocalScope, at date: Date = Date()
    ) throws -> LibraryNotebookEntry? {
        guard let old = try notebookEntry(id: id, in: scope), old.isDeleted else { return nil }
        let restored = try LibraryNotebookEntry(
            id: newID, createdAt: date, kind: old.kind, sourceKind: old.sourceKind,
            sourceItemID: old.sourceItemID, sourceRevision: old.sourceRevision,
            sourceTitle: old.sourceTitle, sourceURL: old.sourceURL, sourceName: old.sourceName,
            startSeconds: old.startSeconds, endSeconds: old.endSeconds,
            textExcerpt: old.textExcerpt, note: old.note, tags: old.tags,
            capturedOn: old.capturedOn, reviewed: old.reviewed, updatedAt: date
        )
        _ = try saveNotebookEntry(restored, in: scope)
        return restored
    }

    /// Fills a missing cue only from its captured immutable revision. A newer
    /// Ready transcript is never consulted, and an existing excerpt is retained.
    @discardableResult
    public func fillNotebookExcerptFromExactTranscript(
        id: ItemID, in scope: NotebookLocalScope, at date: Date = Date()
    ) throws -> LibraryNotebookEntry? {
        guard var entry = try notebookEntry(id: id, in: scope), !entry.isDeleted,
              entry.textExcerpt == nil, entry.sourceKind == .podcast,
              let start = entry.startSeconds, let end = entry.endSeconds,
              let cues = try notebookCues(for: entry) else { return nil }
        let selected = cues.filter { $0.endSeconds >= start && $0.startSeconds <= end }
        guard !selected.isEmpty else { return nil }
        let excerpt = String(selected.map(\.text).joined(separator: " ").prefix(16_000))
        guard !excerpt.isEmpty else { return nil }
        entry.textExcerpt = excerpt
        entry.updatedAt = date
        _ = try saveNotebookEntry(entry, in: scope)
        return entry
    }

    private func notebookCues(for entry: LibraryNotebookEntry) throws -> [TranscriptCue]? {
        if let current = try readPlaybackTranscript(for: entry.sourceItemID, revisionID: entry.sourceRevision,
                                                    requestedAt: nil),
           current.availability == .available, current.timing != .none, let cues = current.cues {
            return cues
        }
        let key = "\(entry.sourceItemID.rawValue)|\(entry.sourceRevision.rawValue)"
        var descriptor = FetchDescriptor<LocalLibrarySchemaV23Models.NotebookRevisionCuesRecord>(
            predicate: #Predicate { $0.id == key })
        descriptor.fetchLimit = 1
        guard let record = try ModelContext(container).fetch(descriptor).first else { return nil }
        return try TranscriptCueCodec.decode(record.cues)
    }

    private func notebookRecord(
        id: ItemID, in scope: NotebookLocalScope, context: ModelContext
    ) throws -> LocalLibrarySchemaV23Models.NotebookEntryRecord? {
        let scopeKey = scope.persistenceKey
        let entryID = id.rawValue
        var descriptor = FetchDescriptor<LocalLibrarySchemaV23Models.NotebookEntryRecord>(
            predicate: #Predicate { $0.scopeKey == scopeKey && $0.entryID == entryID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func validatedNotebookEntry(_ value: LibraryNotebookEntry) throws -> LibraryNotebookEntry {
        try LibraryNotebookEntry(
            id: value.id, createdAt: value.createdAt, kind: value.kind, sourceKind: value.sourceKind,
            sourceItemID: value.sourceItemID, sourceRevision: value.sourceRevision,
            sourceTitle: value.sourceTitle, sourceURL: value.sourceURL, sourceName: value.sourceName,
            startSeconds: value.startSeconds, endSeconds: value.endSeconds,
            textExcerpt: value.textExcerpt, note: value.note, tags: value.tags,
            capturedOn: value.capturedOn, reviewed: value.reviewed, updatedAt: value.updatedAt,
            deletedAt: value.deletedAt
        )
    }
}
