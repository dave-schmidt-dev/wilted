import CryptoKit
import Foundation
import WiltedDomain
import WiltedSync

/// Resolves a remote asset to a validated local media file before persistence.
public typealias LocalLibraryAssetResolver = @Sendable (WiltedAsset, AudioRevision) throws -> URL?

/// SwiftData-backed producer implementation of the CloudKit-neutral sync repository.
public actor LocalLibrarySyncRepository: SyncRepository {
    private struct PreparedBatch: Sendable {
        let articles: [LocalLibrarySyncCommit.ArticleApply]
        let revisions: [LocalLibrarySyncCommit.RevisionApply]
        let playbacks: [LocalLibrarySyncCommit.PlaybackApply]
    }

    private let store: LocalLibraryStore
    private let codec = WiltedRecordCodec()
    private let assetResolver: LocalLibraryAssetResolver
    private let beforeCommit: (@Sendable () throws -> Void)?
    private var storedState: SyncRepositoryState
    private var staged: [String: PreparedBatch] = [:]
    private var continuation: AsyncStream<SyncStatus>.Continuation?
    public let statuses: AsyncStream<SyncStatus>

    /// Opens the repository over the same SwiftData store used by the producer library.
    public init(store: LocalLibraryStore, initialState: SyncRepositoryState? = nil,
                assetResolver: @escaping LocalLibraryAssetResolver = { _, _ in nil },
                beforeCommit: (@Sendable () throws -> Void)? = nil) async throws {
        self.store = store
        self.assetResolver = assetResolver
        self.beforeCommit = beforeCommit
        self.storedState = try await store.syncRepositoryState() ?? initialState ?? SyncRepositoryState()
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        statuses = stream
        self.continuation = continuation
    }

    /// Returns the last committed state reconstructed from SwiftData.
    public func state() async -> SyncRepositoryState { storedState }

    /// Quarantines account-bound sync state after CKSyncEngine reports an account change.
    ///
    /// This is not a general reset API. Call it only after the matching CloudKit
    /// account-change event. Pending mutations remain durable for explicit conflict
    /// resolution, but their conflicted identities exclude them from automatic sends.
    public func quarantineAfterAccountChange() async throws {
        emit(.init(phase: .staging, message: "Quarantining local sync work after iCloud account change"))
        do {
            let pendingIDs = Set(storedState.pendingChanges.map(\.recordID))
            var records = storedState.records
            for envelope in storedState.pendingChanges.compactMap(\.record) {
                records.removeAll { $0.id == envelope.id }
                records.append(envelope)
            }
            let candidate = SyncRepositoryState(
                records: records,
                engineState: nil,
                pendingChanges: storedState.pendingChanges,
                tombstones: storedState.tombstones,
                remoteAcknowledgedRecordIDs: storedState.remoteAcknowledgedRecordIDs,
                protectedRecordIDs: storedState.protectedRecordIDs.union(pendingIDs),
                conflictedRecordIDs: storedState.conflictedRecordIDs.union(pendingIDs),
                conflictServerRecords: storedState.conflictServerRecords)
            let conflictedItems = Set(pendingIDs.compactMap { itemID(for: $0) })
            let statusUpdates = conflictedItems.compactMap { itemID in
                (try? WiltedRecordID.item(itemID)).map {
                    LocalLibrarySyncCommit.StatusApply(recordID: $0, status: .conflicted)
                }
            }
            try beforeCommit?()
            try await store.applySyncCommit(LocalLibrarySyncCommit(state: candidate, statusUpdates: statusUpdates))
            storedState = candidate
            staged.removeAll()
            emit(.init(phase: .completed, message: "Local sync work quarantined after iCloud account change"))
        } catch {
            emit(.init(phase: .failed, message: String(describing: error)))
            throw error
        }
    }

    /// Releases account-quarantined work after the owner explicitly reviews the account.
    ///
    /// `quarantineAfterAccountChange` conflicts every pending record, and
    /// `SyncCoordinator` filters conflicted records out of every send, so those records can
    /// never be acknowledged and `acknowledge` is the only path that un-conflicts one.
    /// Without this release, explicit review resumes syncing but permanently strands exactly
    /// the work the quarantine was protecting.
    ///
    /// Release is deliberately narrow: only records that are still pending and carry no
    /// `conflictServerRecords` entry. That entry is written solely by the send-failure path,
    /// so it marks a genuine remote conflict that must keep its manual resolution. A record
    /// whose conflict was recorded without a server version is safe to release because the
    /// envelope is re-sent with its own encoded system fields (or with none at all, for a
    /// record never seen remotely), so the server rejects a stale write rather than
    /// overwriting it, and that rejection records the server version and excludes the record
    /// from every later release.
    public func resumeAfterAccountReview() async throws {
        let releasable = storedState.accountQuarantinedRecordIDs
        guard !releasable.isEmpty else { return }
        emit(.init(phase: .staging, message: "Releasing quarantined local sync work after account review"))
        do {
            let candidate = SyncRepositoryState(
                records: storedState.records,
                engineState: storedState.engineState,
                pendingChanges: storedState.pendingChanges,
                tombstones: storedState.tombstones,
                remoteAcknowledgedRecordIDs: storedState.remoteAcknowledgedRecordIDs,
                protectedRecordIDs: storedState.protectedRecordIDs,
                conflictedRecordIDs: storedState.conflictedRecordIDs.subtracting(releasable),
                conflictServerRecords: storedState.conflictServerRecords)
            // Derived rather than hardcoded to pendingUpload so an item that also holds a
            // genuine remote conflict keeps reading conflicted.
            let statusUpdates = Set(releasable.compactMap { itemID(for: $0) }).compactMap { itemID in
                (try? WiltedRecordID.item(itemID)).map {
                    LocalLibrarySyncCommit.StatusApply(recordID: $0, status: status(for: itemID, in: candidate))
                }
            }
            try beforeCommit?()
            try await store.applySyncCommit(LocalLibrarySyncCommit(state: candidate, statusUpdates: statusUpdates))
            storedState = candidate
            emit(.init(phase: .completed, message: "Quarantined local sync work released after account review"))
        } catch {
            emit(.init(phase: .failed, message: String(describing: error)))
            throw error
        }
    }

    /// Validates and decodes a remote batch without mutating SwiftData.
    public func stage(_ batch: SyncFetchBatch) async throws -> StagedSyncBatch {
        emit(.init(phase: .staging, message: "Validating fetched records", generationID: batch.generationID))
        do {
            if batch.engineState == nil,
               (!batch.records.isEmpty || !batch.deletedRecordIDs.isEmpty || batch.kind == .fullSnapshot) {
                throw WiltedSyncError.missingEngineState
            }
            let prepared = try await prepare(batch.records)
            guard Set(batch.records.map(\.id)).count == batch.records.count else { throw WiltedSyncError.invalidRecordIdentity }
            staged[batch.generationID] = prepared
            return StagedSyncBatch(batch: batch, priorState: storedState)
        } catch {
            emit(.init(phase: .failed, message: String(describing: error), generationID: batch.generationID))
            throw error
        }
    }

    /// Applies one staged batch through one LocalLibraryStore transaction.
    public func commit(_ stagedBatch: StagedSyncBatch) async throws {
        emit(.init(phase: .committing, message: "Committing fetched records", generationID: stagedBatch.batch.generationID))
        do {
            guard storedState == stagedBatch.priorState else { throw WiltedSyncError.staleStagedBatch }
            guard let prepared = staged[stagedBatch.batch.generationID] else { throw WiltedSyncError.staleStagedBatch }
            let (candidate, deletions) = try mergedState(for: stagedBatch.batch, prior: storedState)
            try beforeCommit?()
            let articles = prepared.articles.map {
                LocalLibrarySyncCommit.ArticleApply(article: $0.article, status: status(for: $0.article.itemID, in: candidate))
            }
            let conflictStatusUpdates = candidate.conflictedRecordIDs.compactMap { recordID -> LocalLibrarySyncCommit.StatusApply? in
                guard let item = itemID(for: recordID), let itemRecord = try? WiltedRecordID.item(item) else { return nil }
                return .init(recordID: itemRecord, status: .conflicted)
            }
            try await store.applySyncCommit(LocalLibrarySyncCommit(state: candidate, articles: articles,
                                                                    revisions: prepared.revisions, playbacks: prepared.playbacks,
                                                                    statusUpdates: conflictStatusUpdates, deletions: deletions,
                                                                    lastFetchAt: Timestamp(Date())))
            storedState = candidate
            staged.removeValue(forKey: stagedBatch.batch.generationID)
            emit(.init(phase: .completed, message: "Sync repository committed", generationID: stagedBatch.batch.generationID))
        } catch {
            emit(.init(phase: .failed, message: String(describing: error), generationID: stagedBatch.batch.generationID))
            throw error
        }
    }

    /// Queues and applies one local mutation atomically with its tombstone state.
    public func enqueue(_ change: SyncPendingChange) async throws {
        emit(.init(phase: .staging, message: "Staging local mutation"))
        do {
            var prepared = PreparedBatch(articles: [], revisions: [], playbacks: [])
            if let record = change.record {
                let records = try await prepare([record])
                prepared = records
            }
            var records = storedState.records
            if let record = change.record {
                records.removeAll { $0.id == record.id }
                records.append(record)
            }
            var pending = storedState.pendingChanges
            pending.removeAll { $0.recordID == change.recordID && $0.operation == change.operation }
            pending.append(change)
            var tombstones = storedState.tombstones
            if let tombstone = change.tombstone {
                let acknowledged = tombstones.first(where: { $0.itemID == tombstone.itemID })?.remoteAcknowledged ?? false
                let merged = SyncTombstone(itemID: tombstone.itemID, generationID: tombstone.generationID,
                                           requestedAt: tombstone.requestedAt,
                                           remoteAcknowledged: acknowledged || tombstone.remoteAcknowledged)
                tombstones.removeAll { $0.itemID == tombstone.itemID }
                tombstones.append(merged)
            }
            let candidate = SyncRepositoryState(records: records, engineState: storedState.engineState,
                                                pendingChanges: pending, tombstones: tombstones,
                                                remoteAcknowledgedRecordIDs: storedState.remoteAcknowledgedRecordIDs,
                                                protectedRecordIDs: storedState.protectedRecordIDs.union([change.recordID]),
                                                conflictedRecordIDs: storedState.conflictedRecordIDs,
                                                conflictServerRecords: storedState.conflictServerRecords)
            try beforeCommit?()
            let status: LocalLibrarySyncStatus = .pendingUpload
            let pendingArticles = prepared.articles.map { LocalLibrarySyncCommit.ArticleApply(article: $0.article, status: status) }
            try await store.applySyncCommit(LocalLibrarySyncCommit(state: candidate, articles: pendingArticles,
                                                                    revisions: prepared.revisions, playbacks: prepared.playbacks))
            storedState = candidate
            emit(.init(phase: .completed, message: "Local mutation queued"))
        } catch {
            emit(.init(phase: .failed, message: String(describing: error)))
            throw error
        }
    }

    /// Applies a partial send outcome atomically, retaining retryable work and
    /// recording conflict server versions for the next reconciliation pass.
    public func acknowledge(_ result: SyncSendResult) async throws {
        emit(.init(phase: .committing, message: "Applying send acknowledgement"))
        do {
            let acknowledged = Set(result.acknowledgedRecordIDs)
            let failed = result.failures.map(\.recordID)
            guard Set(failed).count == failed.count, acknowledged.isDisjoint(with: failed) else {
                throw WiltedSyncError.invalidValue(field: "send result identities")
            }

            let outcomeIDs = acknowledged.union(failed)
            var pendingByID: [WiltedRecordID: SyncPendingChange] = [:]
            for pending in storedState.pendingChanges { pendingByID[pending.recordID] = pending }
            guard outcomeIDs.allSatisfy({ pendingByID[$0] != nil }) else {
                throw WiltedSyncError.invalidValue(field: "send result pendingRecordID")
            }
            let serverIDs = Set(result.serverEnvelopes.map(\.id))
            let expectedSaveIDs = Set(acknowledged.filter { pendingByID[$0]?.operation != .delete })
            guard serverIDs == expectedSaveIDs,
                  acknowledged.allSatisfy({ pendingByID[$0]?.operation == .delete ? !serverIDs.contains($0) : serverIDs.contains($0) }) else {
                throw WiltedSyncError.invalidValue(field: "send result serverEnvelope")
            }

            let prepared = try await prepare(result.serverEnvelopes.filter { acknowledged.contains($0.id) })
            var records = storedState.records
            var pending = storedState.pendingChanges
            var tombstones = storedState.tombstones
            var remoteAcknowledged = storedState.remoteAcknowledgedRecordIDs
            var protected = storedState.protectedRecordIDs
            var conflicted = storedState.conflictedRecordIDs
            var conflictServerRecords = storedState.conflictServerRecords
            var deletions: [WiltedRecordID] = []
            var statusUpdates: [LocalLibrarySyncCommit.StatusApply] = []

            for recordID in acknowledged {
                let change = storedState.pendingChanges.first(where: { $0.recordID == recordID })
                let isDelete = change?.operation == .delete
                pending.removeAll { $0.recordID == recordID }
                protected.remove(recordID); conflicted.remove(recordID); conflictServerRecords.removeValue(forKey: recordID)
                if isDelete {
                    remoteAcknowledged.remove(recordID)
                    if recordID.recordType == .item {
                        records.removeAll { itemID(for: $0.id) == itemID(for: recordID) }
                    } else {
                        records.removeAll { $0.id == recordID }
                    }
                } else if result.serverEnvelopes.contains(where: { $0.id == recordID }) {
                    remoteAcknowledged.insert(recordID)
                    records.removeAll { $0.id == recordID }
                }
                if isDelete, let tombstone = change?.tombstone {
                    tombstones = acknowledgedTombstone(tombstone, in: tombstones)
                    deletions.append(recordID)
                }
                if let item = itemID(for: recordID), let itemRecord = try? WiltedRecordID.item(item), !isDelete {
                    statusUpdates.append(.init(recordID: itemRecord, status: .remoteAcknowledged))
                }
            }

            for envelope in result.serverEnvelopes where acknowledged.contains(envelope.id) {
                records.append(envelope)
            }
            for failure in result.failures {
                protected.insert(failure.recordID)
                if failure.disposition == .conflict {
                    conflicted.insert(failure.recordID)
                }
                if let serverRecord = failure.serverRecord ?? result.serverEnvelopes.first(where: { $0.id == failure.recordID }) {
                    conflictServerRecords[failure.recordID] = serverRecord
                }
                if let item = itemID(for: failure.recordID), let itemRecord = try? WiltedRecordID.item(item) {
                    let status: LocalLibrarySyncStatus
                    switch failure.disposition {
                    case .conflict: status = .conflicted
                    case .terminal: status = .failedUpload
                    case .retryable, .cancelled: status = .pendingUpload
                    }
                    statusUpdates.append(.init(recordID: itemRecord, status: status))
                }
            }

            let candidate = SyncRepositoryState(records: records, engineState: result.engineState ?? storedState.engineState,
                                                pendingChanges: pending, tombstones: tombstones,
                                                remoteAcknowledgedRecordIDs: remoteAcknowledged,
                                                protectedRecordIDs: protected, conflictedRecordIDs: conflicted,
                                                conflictServerRecords: conflictServerRecords)
            try beforeCommit?()
            try await store.applySyncCommit(LocalLibrarySyncCommit(
                state: candidate,
                articles: prepared.articles.map { .init(article: $0.article, status: .remoteAcknowledged) },
                revisions: prepared.revisions, playbacks: prepared.playbacks,
                statusUpdates: statusUpdates, deletions: deletions, lastSendAt: Timestamp(Date())))
            storedState = candidate
            emit(.init(phase: .completed, message: "Send acknowledgement committed"))
        } catch {
            emit(.init(phase: .failed, message: String(describing: error)))
            throw error
        }
    }

    /// Closes the status stream for lifecycle teardown.
    public func finishStatusStream() { continuation?.finish(); continuation = nil }

    /// Resolves the local media backing one revision envelope.
    ///
    /// The injected resolver is optional by design and defaults to returning nil, so an
    /// embedder that never supplies one (the shipping Mac app is one) has to be able to
    /// fall back to the durable store. `PreparationCoordinator` names media by its
    /// per-run request ID (`candidate-<uuid>.m4a`), so no path is derivable from the
    /// revision alone and only the store knows where the file went. The live
    /// CloudKit transport already carries this same fallback with the same
    /// revisionID/contentHash guards; keeping the two symmetric is what stops a ready
    /// revision from being enqueueable for upload but not stageable.
    private func resolveMedia(asset: WiltedAsset, revision: AudioRevision) async throws -> URL? {
        if let resolved = try assetResolver(asset, revision) { return resolved }
        guard let stored = try? await store.readyRevision(for: revision.itemID),
              stored.revision.revisionID == revision.revisionID,
              stored.revision.contentHash == revision.contentHash else { return nil }
        return stored.mediaURL
    }

    private func prepare(_ envelopes: [WiltedRecordEnvelope]) async throws -> PreparedBatch {
        var articles: [LocalLibrarySyncCommit.ArticleApply] = []
        var revisions: [LocalLibrarySyncCommit.RevisionApply] = []
        var playbacks: [LocalLibrarySyncCommit.PlaybackApply] = []
        for envelope in envelopes {
            switch envelope.id.recordType {
            case .item:
                articles.append(.init(article: try codec.decodeArticle(envelope), status: .remoteAcknowledged))
            case .revision:
                let decoded = try codec.decodeRevisionRecord(envelope)
                guard case let .asset(asset)? = envelope.fields["audioAsset"], asset.contentHash == decoded.value.contentHash,
                      let mediaURL = try await resolveMedia(asset: asset, revision: decoded.value) else {
                    throw WiltedSyncError.invalidValue(field: "validatedLocalMedia")
                }
                try validateMedia(mediaURL, contentHash: decoded.value.contentHash)
                revisions.append(.init(revision: decoded.value, mediaURL: mediaURL))
            case .playbackState:
                let decoded = try codec.decodePlayback(envelope)
                let sidecar = PlaybackSystemFieldsSidecar(encodedSystemFields: envelope.sidecar?.encodedSystemFields,
                                                          changeTag: envelope.sidecar?.changeTag)
                playbacks.append(.init(state: decoded, sidecar: sidecar))
            }
        }
        return PreparedBatch(articles: articles, revisions: revisions, playbacks: playbacks)
    }

    private func validateMedia(_ url: URL, contentHash: String) throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw WiltedSyncError.invalidValue(field: "validatedLocalMedia")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        guard "sha256:\(digest)" == contentHash else { throw WiltedSyncError.invalidValue(field: "validatedLocalMedia.contentHash") }
    }

    private func mergedState(for batch: SyncFetchBatch, prior: SyncRepositoryState) throws -> (SyncRepositoryState, [WiltedRecordID]) {
        var records = prior.records
        var acknowledged = prior.remoteAcknowledgedRecordIDs
        var conflicted = prior.conflictedRecordIDs
        let fetchedIDs = Set(batch.records.map(\.id))
        var deletions: [WiltedRecordID] = []
        if batch.kind == .fullSnapshot {
            let pendingIDs = Set(prior.pendingChanges.map(\.recordID))
            let protectedIDs = prior.protectedRecordIDs
            let protectedFamilyItems = Set(prior.records.filter {
                pendingIDs.contains($0.id) || protectedIDs.contains($0.id) || conflicted.contains($0.id)
            }.compactMap { itemID(for: $0.id) })
            let missingItems = Set(prior.records.filter { record in
                record.id.recordType == .item && !fetchedIDs.contains(record.id) && acknowledged.contains(record.id) &&
                    !(itemID(for: record.id).map { protectedFamilyItems.contains($0) } ?? false)
            }.compactMap { itemID(for: $0.id) })
            let removable = prior.records.filter { record in
                let familyItem = itemID(for: record.id)
                if let familyItem, missingItems.contains(familyItem) { return true }
                return !fetchedIDs.contains(record.id) && acknowledged.contains(record.id) &&
                    !pendingIDs.contains(record.id) && !protectedIDs.contains(record.id) && !conflicted.contains(record.id) &&
                    !(familyItem.map { protectedFamilyItems.contains($0) } ?? false)
            }
            records.removeAll { removable.contains($0) }
            acknowledged.subtract(removable.map(\.id))
            let familyDeletes = missingItems.compactMap { try? WiltedRecordID.item($0) }
            deletions.append(contentsOf: familyDeletes)
            deletions.append(contentsOf: removable.filter { !(itemID(for: $0.id).map { missingItems.contains($0) } ?? false) }.map(\.id))
        }
        let pendingIDs = Set(prior.pendingChanges.map(\.recordID))
        let protectedIDs = prior.protectedRecordIDs
        for deletion in batch.deletedRecordIDs where deletion.recordType == .item {
            let familyItem = itemID(for: deletion)
            let family = Set(records.filter { itemID(for: $0.id) == familyItem }.map(\.id))
                .union(pendingIDs.filter { itemID(for: $0) == familyItem })
                .union(protectedIDs.filter { itemID(for: $0) == familyItem })
                .union(conflicted.filter { itemID(for: $0) == familyItem })
                .union([deletion])
            if family.contains(where: { pendingIDs.contains($0) || protectedIDs.contains($0) || conflicted.contains($0) }) {
                conflicted.formUnion(family)
            }
        }
        conflicted.formUnion(batch.deletedRecordIDs.filter { pendingIDs.contains($0) || protectedIDs.contains($0) || conflicted.contains($0) })
        let explicitRemovable = batch.deletedRecordIDs.filter { id in
            acknowledged.contains(id) && !pendingIDs.contains(id) && !protectedIDs.contains(id) &&
                !conflicted.contains(id) && !deletions.contains(id)
        }
        if !explicitRemovable.isEmpty {
            for deletion in explicitRemovable {
                let family = records.filter { record in
                    deletion.recordType == .item ? itemID(for: record.id) == itemID(for: deletion) : record.id == deletion
                }
                records.removeAll { record in family.contains(record) }
                acknowledged.subtract(family.map(\.id))
            }
            deletions.append(contentsOf: explicitRemovable)
        }
        for fetched in batch.records {
            records.removeAll { $0.id == fetched.id }
            records.append(fetched)
        }
        acknowledged.formUnion(fetchedIDs)
        return (SyncRepositoryState(records: records, engineState: batch.engineState ?? prior.engineState,
                                    pendingChanges: prior.pendingChanges, tombstones: prior.tombstones,
                                    remoteAcknowledgedRecordIDs: acknowledged, protectedRecordIDs: prior.protectedRecordIDs,
                                    conflictedRecordIDs: conflicted, conflictServerRecords: prior.conflictServerRecords), deletions)
    }

    private func status(for itemID: ItemID, in state: SyncRepositoryState) -> LocalLibrarySyncStatus {
        var familyIDs = Set(state.records.filter { self.itemID(for: $0.id) == itemID }.map(\.id))
        familyIDs.formUnion(state.pendingChanges.map(\.recordID).filter { self.itemID(for: $0) == itemID })
        familyIDs.formUnion(state.protectedRecordIDs.filter { self.itemID(for: $0) == itemID })
        familyIDs.formUnion(state.conflictedRecordIDs.filter { self.itemID(for: $0) == itemID })
        if let itemRecord = try? WiltedRecordID.item(itemID) { familyIDs.insert(itemRecord) }
        if familyIDs.contains(where: { state.conflictedRecordIDs.contains($0) }) { return .conflicted }
        if familyIDs.contains(where: { recordID in state.pendingChanges.contains(where: { change in change.recordID == recordID }) }) { return .pendingUpload }
        if familyIDs.contains(where: { state.protectedRecordIDs.contains($0) }) { return .localOnly }
        if familyIDs.contains(where: { state.remoteAcknowledgedRecordIDs.contains($0) }) { return .remoteAcknowledged }
        return .localOnly
    }

    private func itemID(for recordID: WiltedRecordID) -> ItemID? {
        let parts = recordID.recordName.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        return try? ItemID(rawValue: String(parts[1]))
    }

    private func acknowledgedTombstone(_ tombstone: SyncTombstone, in tombstones: [SyncTombstone]) -> [SyncTombstone] {
        let acknowledged = SyncTombstone(itemID: tombstone.itemID, generationID: tombstone.generationID,
                                         requestedAt: tombstone.requestedAt, remoteAcknowledged: true)
        return tombstones.map { $0.itemID == tombstone.itemID ? acknowledged : $0 }
    }

    private func emit(_ status: SyncStatus) { continuation?.yield(status) }
}
