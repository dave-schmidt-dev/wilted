import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

/// What a playback checkpoint write did.
public enum PlaybackSaveOutcome: Equatable, Sendable {
    case saved
    /// Nothing was written: the item has no episode row, no article row and
    /// no stored audio for that revision, so a new playback record would
    /// outlive the removal that deleted them.
    case skippedMissingItem
}

extension LocalLibraryStore {
    /// Upserts a playback checkpoint. A first record for an item that no
    /// longer exists is skipped rather than inserted: a pause that lands
    /// after an unsubscribe cascade would otherwise re-create the position
    /// the cascade just deleted.
    @discardableResult
    public func save(playback state: PlaybackState) throws -> PlaybackSaveOutcome {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        let id = "\(state.itemID.rawValue)|\(state.revisionID.rawValue)"
        let existingRecord = records.first(where: { $0.id == id })
        if existingRecord == nil, try !playbackOwnerExists(state, in: context) { return .skippedMissingItem }
        if let existing = existingRecord {
            existing.sessionID = state.sessionID; existing.sequence = state.sequence; existing.positionSeconds = state.positionSeconds
            existing.durationSeconds = state.durationSeconds; existing.completed = state.completed; existing.intent = state.intent.rawValue
            existing.deviceID = state.deviceID
            if let systemFields = state.encodedCloudKitRecordSystemFields {
                existing.encodedCloudKitRecordSystemFields = systemFields
            }
            existing.updatedAt = state.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV3Models.PlaybackRecord(state)) }
        try context.save()
        return .saved
    }

    /// Writes the completed playback checkpoint and the "finished listening"
    /// fact in one `ModelContext`/one save, so a crash between the two never
    /// leaves the checkpoint durable without the listening record, or vice
    /// versa. Skipped as a whole, like `save(playback:)`, when the item no
    /// longer exists and has no playback record yet.
    @discardableResult
    public func save(playback: PlaybackState, listening: PodcastListeningState) throws -> PlaybackSaveOutcome {
        let context = ModelContext(container)
        let playbackRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())
        let playbackID = "\(playback.itemID.rawValue)|\(playback.revisionID.rawValue)"
        let existingRecord = playbackRecords.first(where: { $0.id == playbackID })
        if existingRecord == nil, try !playbackOwnerExists(playback, in: context) { return .skippedMissingItem }
        if let existing = existingRecord {
            existing.sessionID = playback.sessionID; existing.sequence = playback.sequence; existing.positionSeconds = playback.positionSeconds
            existing.durationSeconds = playback.durationSeconds; existing.completed = playback.completed; existing.intent = playback.intent.rawValue
            existing.deviceID = playback.deviceID
            if let systemFields = playback.encodedCloudKitRecordSystemFields {
                existing.encodedCloudKitRecordSystemFields = systemFields
            }
            existing.updatedAt = playback.updatedAt.date
        } else { context.insert(LocalLibrarySchemaV3Models.PlaybackRecord(playback)) }

        let listeningRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
        if let existing = listeningRecords.first(where: { $0.id == listening.episodeID.rawValue }) {
            existing.completedAt = listening.completedAt?.date
            existing.lastRevisionID = listening.lastRevisionID?.rawValue
            existing.updatedAt = listening.updatedAt.date
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(listening))
        }
        try context.save()
        return .saved
    }

    /// Whether the checkpoint's item still has an episode row, an article row
    /// or stored audio for that exact revision to own a new playback record.
    /// An unsubscribe deletes all three in one save. A removed article keeps
    /// its flagged row, so it still counts.
    private func playbackOwnerExists(_ state: PlaybackState, in context: ModelContext) throws -> Bool {
        let identifier = state.itemID.rawValue
        let revisionIdentifier = state.revisionID.rawValue
        let episodes = FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>(
            predicate: #Predicate { $0.id == identifier })
        if try context.fetchCount(episodes) > 0 { return true }
        let articles = FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>(
            predicate: #Predicate { $0.id == identifier })
        if try context.fetchCount(articles) > 0 { return true }
        let revisions = FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>(
            predicate: #Predicate { $0.id == revisionIdentifier && $0.itemID == identifier })
        return try context.fetchCount(revisions) > 0
    }

    public func playbackState(for itemID: ItemID, revisionID: RevisionID) throws -> PlaybackState? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()).first(where: { $0.itemID == itemID.rawValue && $0.revisionID == revisionID.rawValue }) else { return nil }
        return try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: record.sessionID, sequence: record.sequence,
                                 positionSeconds: record.positionSeconds, durationSeconds: record.durationSeconds, completed: record.completed,
                                 intent: PlaybackIntent(rawValue: record.intent) ?? .progress, deviceID: record.deviceID,
                                 encodedCloudKitRecordSystemFields: record.encodedCloudKitRecordSystemFields, updatedAt: Timestamp(record.updatedAt))
    }

    // MARK: CloudKit sidecars and reconciliation state

    /// Saves opaque sync state and replaces both optional operation timestamps.
    public func save(syncState state: LocalLibrarySyncState) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.SyncStateRecord>())
        if let existing = records.first(where: { $0.key == state.key }) {
            existing.engineState = state.engineState
            existing.lastFetchAt = state.lastFetchAt?.date
            existing.lastSendAt = state.lastSendAt?.date
            existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else {
            context.insert(LocalLibrarySchemaV3Models.SyncStateRecord(state))
        }
        try context.save()
    }

    /// Loads the persisted state for one sync-zone key.
    public func syncState(for key: String) throws -> LocalLibrarySyncState? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.SyncStateRecord>()).first(where: { $0.key == key }) else { return nil }
        return LocalLibrarySyncState(key: record.key, engineState: record.engineState,
                                     lastFetchAt: record.lastFetchAt.map(Timestamp.init), lastSendAt: record.lastSendAt.map(Timestamp.init))
    }

    /// Records a successful fetch without inspecting the opaque engine bytes.
    public func recordSuccessfulFetch(at date: Timestamp = Timestamp(Date()), for key: String = "private-zone") throws {
        let prior = try syncState(for: key)
        try save(syncState: LocalLibrarySyncState(key: key, engineState: prior?.engineState ?? Data(),
                                                  lastFetchAt: date, lastSendAt: prior?.lastSendAt))
    }

    /// Records a successful send without inspecting the opaque engine bytes.
    public func recordSuccessfulSend(at date: Timestamp = Timestamp(Date()), for key: String = "private-zone") throws {
        let prior = try syncState(for: key)
        try save(syncState: LocalLibrarySyncState(key: key, engineState: prior?.engineState ?? Data(),
                                                  lastFetchAt: prior?.lastFetchAt, lastSendAt: date))
    }

    /// Persists opaque playback system fields and the latest remote change tag.
    public func save(playbackSidecar sidecar: PlaybackSystemFieldsSidecar, for itemID: ItemID, revisionID: RevisionID) throws {
        let context = ModelContext(container)
        let id = "\(itemID.rawValue)|\(revisionID.rawValue)"
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()).first(where: { $0.id == id }) else { return }
        record.encodedCloudKitRecordSystemFields = sidecar.encodedSystemFields
        record.encodedCloudKitRecordChangeTag = sidecar.changeTag
        try context.save()
    }

    /// Loads opaque playback system fields and the latest remote change tag.
    public func playbackSidecar(for itemID: ItemID, revisionID: RevisionID) throws -> PlaybackSystemFieldsSidecar? {
        let context = ModelContext(container)
        let id = "\(itemID.rawValue)|\(revisionID.rawValue)"
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()).first(where: { $0.id == id }) else { return nil }
        return PlaybackSystemFieldsSidecar(encodedSystemFields: record.encodedCloudKitRecordSystemFields,
                                           changeTag: record.encodedCloudKitRecordChangeTag)
    }

    /// Saves a deletion tombstone while keeping remote acknowledgement monotonic.
    public func record(tombstone: LocalLibraryTombstone) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>())
        if let existing = records.first(where: { $0.id == tombstone.id }) {
            existing.itemID = tombstone.itemID.rawValue
            existing.generationID = tombstone.generationID
            existing.requestedAt = tombstone.requestedAt.date
            // Acknowledgement is monotonic and cannot be accidentally undone by replay.
            existing.remoteAcknowledged = existing.remoteAcknowledged || tombstone.remoteAcknowledged
            existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else {
            context.insert(LocalLibrarySchemaV3Models.TombstoneRecord(tombstone))
        }
        try context.save()
    }

    /// Loads one deletion tombstone by its stable identifier.
    public func tombstone(for id: String) throws -> LocalLibraryTombstone? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>()).first(where: { $0.id == id }),
              let itemID = try? ItemID(rawValue: record.itemID) else { return nil }
        return LocalLibraryTombstone(id: record.id, itemID: itemID, generationID: record.generationID,
                                     requestedAt: Timestamp(record.requestedAt), remoteAcknowledged: record.remoteAcknowledged)
    }

    /// Loads all persisted deletion tombstones.
    public func tombstones() throws -> [LocalLibraryTombstone] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>()).compactMap { record in
            guard let itemID = try? ItemID(rawValue: record.itemID) else { return nil }
            return LocalLibraryTombstone(id: record.id, itemID: itemID, generationID: record.generationID,
                                         requestedAt: Timestamp(record.requestedAt), remoteAcknowledged: record.remoteAcknowledged)
        }
    }

    /// Marks a tombstone acknowledged; replaying an acknowledgement returns false.
    @discardableResult
    public func acknowledgeTombstone(id: String) throws -> Bool {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>()).first(where: { $0.id == id }) else { return false }
        guard !record.remoteAcknowledged else { return false }
        record.remoteAcknowledged = true
        try context.save()
        return true
    }

    /// Sets the local/remote status used by generation absence deletion.
    public func setSyncStatus(_ status: LocalLibrarySyncStatus, for itemID: ItemID) throws {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>()).first(where: { $0.id == itemID.rawValue }) else { return }
        record.syncStatus = status.rawValue
        try context.save()
    }

    /// Loads the sync status for one local item.
    public func syncStatus(for itemID: ItemID) throws -> LocalLibrarySyncStatus? {
        let context = ModelContext(container)
        guard let raw = try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>()).first(where: { $0.id == itemID.rawValue })?.syncStatus else { return nil }
        return LocalLibrarySyncStatus(rawValue: raw)
    }

    /// Finalizes one generation, deleting only unseen remote-acknowledged items.
    @discardableResult
    public func finalizeSnapshot(generationID: String, fetchComplete: Bool, seenRemoteItemIDs: Set<ItemID>) throws -> LocalLibrarySnapshotResult {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>())
        let seen = Set(seenRemoteItemIDs.map(\.rawValue))
        let deleted: [ItemID]
        if fetchComplete {
            deleted = records.compactMap { record in
                guard record.syncStatus == LocalLibrarySyncStatus.remoteAcknowledged.rawValue,
                      !seen.contains(record.id), let itemID = try? ItemID(rawValue: record.id) else { return nil }
                return itemID
            }
            for itemID in deleted {
                for revision in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()).filter({ $0.itemID == itemID.rawValue }) { context.delete(revision) }
                for transcript in try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>()).filter({ $0.itemID == itemID.rawValue }) { context.delete(transcript) }
                for playback in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()).filter({ $0.itemID == itemID.rawValue }) { context.delete(playback) }
                if let article = records.first(where: { $0.id == itemID.rawValue }) { context.delete(article) }
            }
            if !deleted.isEmpty { try context.save() }
        } else {
            deleted = []
        }
        let retained = records.compactMap { try? ItemID(rawValue: $0.id) }.filter { !deleted.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return LocalLibrarySnapshotResult(generationID: generationID, deletedItemIDs: deleted.sorted { $0.rawValue < $1.rawValue }, retainedItemIDs: retained, mutated: !deleted.isEmpty)
    }

    /// Applies one validated sync transaction in a single SwiftData context save.
    public func applySyncCommit(_ commit: LocalLibrarySyncCommit) throws {
        let context = ModelContext(container)
        let articles = try context.fetch(FetchDescriptor<LocalLibrarySchemaV5Models.ArticleRecord>())
        let revisions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        let transcripts = try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
        let playbacks = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>())

        for deletion in commit.deletions {
            switch deletion.recordType {
            case .item:
                let itemID = String(deletion.recordName.dropFirst("item:".count))
                for revision in revisions where revision.itemID == itemID { context.delete(revision) }
                for transcript in transcripts where transcript.itemID == itemID { context.delete(transcript) }
                for playback in playbacks where playback.itemID == itemID { context.delete(playback) }
                for article in articles where article.id == itemID { context.delete(article) }
            case .revision:
                let parts = deletion.recordName.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count == 3 { for revision in revisions where revision.itemID == parts[1] && revision.id == parts[2] { context.delete(revision) } }
            case .transcript:
                let parts = deletion.recordName.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count == 3 { for transcript in transcripts where transcript.itemID == parts[1] && transcript.revisionID == parts[2] { context.delete(transcript) } }
            case .revisionChunk:
                // Chunk rows live only in the durable transport state.
                break
            case .playbackState:
                let parts = deletion.recordName.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count == 3 { for playback in playbacks where playback.id == "\(parts[1])|\(parts[2])" { context.delete(playback) } }
            }
        }

        for applied in commit.articles {
            if let existing = articles.first(where: { $0.id == applied.article.itemID.rawValue }) {
                existing.canonicalURL = applied.article.canonicalURL.absoluteString; existing.title = applied.article.title
                existing.source = applied.article.source; existing.author = applied.article.author
                existing.publishedTime = applied.article.publishedTime?.date; existing.createdAt = applied.article.createdAt.date
                existing.isRemoved = applied.article.isDeleted; existing.syncStatus = applied.status.rawValue
                existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
            } else {
                let record = LocalLibrarySchemaV5Models.ArticleRecord(applied.article)
                record.syncStatus = applied.status.rawValue
                context.insert(record)
            }
        }

        // A delete mutation has no article envelope, but its local item must
        // still advertise pending/conflicted ownership to library readers.
        for article in articles where !commit.articles.contains(where: { $0.article.itemID.rawValue == article.id }) {
            guard let itemID = try? ItemID(rawValue: article.id), let recordID = try? WiltedRecordID.item(itemID) else { continue }
            if commit.state.conflictedRecordIDs.contains(recordID) {
                article.syncStatus = LocalLibrarySyncStatus.conflicted.rawValue
            } else if commit.state.pendingChanges.contains(where: { $0.recordID == recordID }) {
                article.syncStatus = LocalLibrarySyncStatus.pendingUpload.rawValue
            }
        }

        for update in commit.statusUpdates where update.recordID.recordType == .item {
            let components = update.recordID.recordName.split(separator: ":")
            guard components.count == 2, let itemID = try? ItemID(rawValue: String(components[1])) else { continue }
            if let article = articles.first(where: { $0.id == itemID.rawValue }) {
                article.syncStatus = update.status.rawValue
            }
        }

        for applied in commit.revisions {
            if let existing = revisions.first(where: { $0.id == applied.revision.revisionID.rawValue }) {
                guard existing.itemID == applied.revision.itemID.rawValue,
                      existing.contentHash == applied.revision.contentHash,
                      existing.mediaURL == applied.mediaURL.absoluteString else {
                    throw LocalLibraryStoreError.immutableRevision(applied.revision.revisionID, site: .syncCommit)
                }
            } else {
                context.insert(LocalLibrarySchemaV3Models.RevisionRecord(applied.revision, mediaURL: applied.mediaURL))
            }
        }

        for applied in commit.transcripts {
            try upsert(applied.transcript, in: context)
        }

        for applied in commit.playbacks {
            let recordID = try WiltedRecordID.playback(applied.state.itemID, applied.state.revisionID)
            guard !commit.state.pendingChanges.contains(where: { $0.recordID == recordID }) else { continue }
            let id = "\(applied.state.itemID.rawValue)|\(applied.state.revisionID.rawValue)"
            if let existing = playbacks.first(where: { $0.id == id }) {
                let current = try PlaybackState(itemID: applied.state.itemID, revisionID: applied.state.revisionID,
                                                sessionID: existing.sessionID, sequence: existing.sequence,
                                                positionSeconds: existing.positionSeconds, durationSeconds: existing.durationSeconds,
                                                completed: existing.completed, intent: PlaybackIntent(rawValue: existing.intent) ?? .progress,
                                                deviceID: existing.deviceID, encodedCloudKitRecordSystemFields: existing.encodedCloudKitRecordSystemFields,
                                                updatedAt: Timestamp(existing.updatedAt))
                let incomingTag = applied.sidecar.changeTag
                let merge = mergePlayback(current: current, incoming: applied.state, changeTagMatches: true)
                if merge.acceptedStateIsIncoming {
                    existing.sessionID = applied.state.sessionID; existing.sequence = applied.state.sequence
                    existing.positionSeconds = applied.state.positionSeconds; existing.durationSeconds = applied.state.durationSeconds
                    existing.completed = applied.state.completed; existing.intent = applied.state.intent.rawValue
                    existing.deviceID = applied.state.deviceID; existing.updatedAt = applied.state.updatedAt.date
                }
                existing.encodedCloudKitRecordSystemFields = applied.sidecar.encodedSystemFields
                existing.encodedCloudKitRecordChangeTag = incomingTag
            } else {
                let record = LocalLibrarySchemaV3Models.PlaybackRecord(applied.state)
                record.encodedCloudKitRecordSystemFields = applied.sidecar.encodedSystemFields
                record.encodedCloudKitRecordChangeTag = applied.sidecar.changeTag
                context.insert(record)
            }
        }

        let tombstones = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.TombstoneRecord>())
        for tombstone in commit.state.tombstones {
            let id = "item:\(tombstone.itemID.rawValue):\(tombstone.generationID)"
            if let existing = tombstones.first(where: { $0.id == id }) {
                existing.itemID = tombstone.itemID.rawValue; existing.generationID = tombstone.generationID
                existing.requestedAt = tombstone.requestedAt.date
                existing.remoteAcknowledged = existing.remoteAcknowledged || tombstone.remoteAcknowledged
                existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
            } else {
                context.insert(LocalLibrarySchemaV3Models.TombstoneRecord(
                    LocalLibraryTombstone(id: id, itemID: tombstone.itemID, generationID: tombstone.generationID,
                                          requestedAt: tombstone.requestedAt, remoteAcknowledged: tombstone.remoteAcknowledged)))
            }
        }

        let encodedRepositoryState = try JSONEncoder().encode(commit.state)
        let syncStates = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.SyncStateRecord>())
        if let existing = syncStates.first(where: { $0.key == "private-zone" }) {
            existing.engineState = commit.state.engineState ?? Data()
            if let lastFetchAt = commit.lastFetchAt { existing.lastFetchAt = lastFetchAt.date }
            if let lastSendAt = commit.lastSendAt { existing.lastSendAt = lastSendAt.date }
            existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else {
            context.insert(LocalLibrarySchemaV3Models.SyncStateRecord(
                LocalLibrarySyncState(key: "private-zone", engineState: commit.state.engineState ?? Data(),
                                      lastFetchAt: commit.lastFetchAt, lastSendAt: commit.lastSendAt)))
        }
        let repositoryStates = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RepositoryStateRecord>())
        if let existing = repositoryStates.first(where: { $0.key == "private-zone" }) {
            existing.stateData = encodedRepositoryState
            existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else {
            context.insert(LocalLibrarySchemaV3Models.RepositoryStateRecord(stateData: encodedRepositoryState))
        }
        try context.save()
    }

    /// Loads the sync repository snapshot embedded in the SwiftData sync-state record.
    public func syncRepositoryState() throws -> SyncRepositoryState? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RepositoryStateRecord>()).first(where: { $0.key == "private-zone" }) else { return nil }
        return try JSONDecoder().decode(SyncRepositoryState.self, from: record.stateData)
    }

    // MARK: Podcast catalog and local listening state

}
