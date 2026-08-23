import XCTest
import CryptoKit
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

final class LocalLibrarySyncRepositoryTests: XCTestCase {
    private func storeURL(_ name: String = #function) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wilted-sync-\(name)-\(UUID().uuidString)").appendingPathComponent("library.sqlite")
    }

    private func article(_ suffix: String = "alpha") throws -> Article {
        let url = URL(string: "https://example.test/sync/\(suffix)")!
        return try Article(itemID: ItemID.derive(from: url), canonicalURL: url, title: "Sync \(suffix)", source: "example.test",
                           createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func record(for article: Article) throws -> WiltedRecordEnvelope {
        try WiltedRecordCodec().encode(article: article, currentRevisionID: RevisionID(rawValue: "rev-\(article.itemID.rawValue.suffix(8))"))
    }

    func testPendingMutationAndOpaqueEngineStateSurviveReopen() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let itemRecord = try record(for: item)
        let tombstone = SyncTombstone(itemID: item.itemID, generationID: "delete-1", requestedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_001)))
        let deletion = try SyncPendingChange(operation: .delete, recordID: itemRecord.id, tombstone: tombstone)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        let batch = try SyncFetchBatch(generationID: "generation-1", records: [itemRecord], engineState: Data([9, 8, 7]))
        try await repository.commit(try await repository.stage(batch))
        try await repository.enqueue(deletion)

        let reopenedStore = try LocalLibraryStore(url: url)
        let reopened = try await LocalLibrarySyncRepository(store: reopenedStore)
        let state = await reopened.state()
        XCTAssertEqual(state.engineState, Data([9, 8, 7]))
        let reopenedSyncState = try await reopenedStore.syncState(for: "private-zone")
        XCTAssertEqual(reopenedSyncState?.engineState, Data([9, 8, 7]))
        XCTAssertEqual(state.pendingChanges, [deletion])
        XCTAssertEqual(state.tombstones, [tombstone])
        XCTAssertEqual(state.records, [itemRecord])
        let reopenedArticle = try await reopenedStore.article(for: item.itemID)
        XCTAssertEqual(reopenedArticle, item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("library.sync.json").path))
    }

    func testExplicitRemoteItemDeletionCascadesAndUpdatesStoreVisibility() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("remote-delete")
        let itemRecord = try record(for: item)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        let fetched = try SyncFetchBatch(generationID: "fetch", records: [itemRecord], engineState: Data([1]))
        try await repository.commit(try await repository.stage(fetched))
        let visibleBeforeDelete = try await store.article(for: item.itemID)
        XCTAssertEqual(visibleBeforeDelete, item)

        let deleted = try SyncFetchBatch(generationID: "delete", records: [], engineState: Data([2]),
                                         deletedRecordIDs: [itemRecord.id])
        try await repository.commit(try await repository.stage(deleted))
        let visibleAfterDelete = try await store.article(for: item.itemID)
        XCTAssertNil(visibleAfterDelete)
        let state = await repository.state()
        XCTAssertTrue(state.records.isEmpty)
    }

    func testReadyRevisionEnqueuesWithTheDefaultResolverByFallingBackToTheStore() async throws {
        // The shipping Mac app builds this repository without an asset resolver, so the
        // default nil-returning one has to resolve durable media through the store. Before
        // the fallback existed every revision enqueue threw invalidValue("validatedLocalMedia"),
        // which meant no audio revision could ever be queued for CloudKit publication.
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("default-resolver")
        let bytes = Data("default-resolver-media".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mediaURL = url.deletingLastPathComponent().appendingPathComponent("candidate-\(UUID().uuidString).m4a")
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-default-resolver"),
                                         durationSeconds: 9, byteCount: Int64(bytes.count), contentHash: hash,
                                         mediaType: "audio/mp4",
                                         createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_030)), schemaVersion: 1)
        let revisionRecord = try WiltedRecordCodec().encode(
            revision: revision, audioAsset: WiltedAsset(assetID: revision.revisionID.rawValue, contentHash: hash)
        )
        let store = try LocalLibraryStore(url: url)
        try await store.save(article: item)
        try await store.saveReadyRevision(revision, mediaURL: mediaURL)
        let repository = try await LocalLibrarySyncRepository(store: store)

        try await repository.enqueue(try SyncPendingChange(operation: .create, recordID: revisionRecord.id, record: revisionRecord))

        let state = await repository.state()
        XCTAssertEqual(state.pendingChanges.map(\.recordID), [revisionRecord.id])
    }

    func testRevisionChunksRemainTransportStateWithoutEnteringTheLocalCatalog() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("chunk-transport")
        let revisionID = try RevisionID(rawValue: "rev-chunk-transport")
        let chunked = try AudioChunking.chunk(Data("chunk-transport-bytes".utf8), chunkSize: 4)
        let descriptor = chunked.manifest.chunks[0]
        let asset = try WiltedAsset(assetID: "chunk-asset", contentHash: "sha256:\(descriptor.sha256)")
        let chunkRecord = try WiltedRecordCodec().encode(
            revisionChunk: item.itemID, revisionID: revisionID, descriptor: descriptor, chunkAsset: asset)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)

        try await repository.commit(try await repository.stage(try SyncFetchBatch(
            generationID: "chunk-fetch", records: [chunkRecord], engineState: Data([1]))))

        let stateAfterFetch = await repository.state()
        let inspectionAfterFetch = try await store.inspect()
        XCTAssertEqual(stateAfterFetch.records, [chunkRecord])
        XCTAssertEqual(inspectionAfterFetch.articleCount, 0)
        XCTAssertEqual(inspectionAfterFetch.revisionCount, 0)

        try await repository.commit(try await repository.stage(try SyncFetchBatch(
            generationID: "chunk-delete", records: [], engineState: Data([2]), deletedRecordIDs: [chunkRecord.id])))

        let stateAfterDelete = await repository.state()
        let inspectionAfterDelete = try await store.inspect()
        XCTAssertTrue(stateAfterDelete.records.isEmpty)
        XCTAssertEqual(inspectionAfterDelete.articleCount, 0)
        XCTAssertEqual(inspectionAfterDelete.revisionCount, 0)
    }

    func testManifestRevisionAndChunksQueueAsTransportStateWithoutLocalMedia() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("manifest-transport")
        let revisionID = try RevisionID(rawValue: "rev-manifest-transport")
        let chunked = try AudioChunking.chunk(Data("manifest-transport-bytes".utf8), chunkSize: 4)
        let revision = try AudioRevision(
            itemID: item.itemID, revisionID: revisionID, durationSeconds: 8,
            byteCount: Int64(chunked.manifest.totalByteCount),
            contentHash: "sha256:\(chunked.manifest.contentSHA256)", mediaType: "audio/mp4",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_032)), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let manifestRecord = try codec.encode(revision: revision, manifest: chunked.manifest)
        let chunkRecords = try chunked.manifest.chunks.map { descriptor in
            try codec.encode(
                revisionChunk: item.itemID, revisionID: revisionID, descriptor: descriptor,
                chunkAsset: try WiltedAsset(assetID: descriptor.identity, contentHash: "sha256:\(descriptor.sha256)"))
        }
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)

        for record in [manifestRecord] + chunkRecords {
            try await repository.enqueue(try SyncPendingChange(operation: .create, recordID: record.id, record: record))
        }

        let state = await repository.state()
        XCTAssertEqual(state.pendingChanges.map(\.recordID), [manifestRecord.id] + chunkRecords.map(\.id))
        let inspection = try await store.inspect()
        XCTAssertEqual(inspection.articleCount, 0)
        XCTAssertEqual(inspection.revisionCount, 0)
    }

    func testRevisionEnqueueStillFailsWhenNoLocalMediaBacksIt() async throws {
        // The fallback must not turn a missing asset into a publishable record: an
        // unresolvable revision is still a hard failure, just no longer the only outcome.
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("unbacked")
        let hash = "sha256:" + SHA256.hash(data: Data("absent".utf8)).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-unbacked"),
                                         durationSeconds: 3, byteCount: 6, contentHash: hash, mediaType: "audio/mp4",
                                         createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_031)), schemaVersion: 1)
        let revisionRecord = try WiltedRecordCodec().encode(
            revision: revision, audioAsset: WiltedAsset(assetID: revision.revisionID.rawValue, contentHash: hash)
        )
        let store = try LocalLibraryStore(url: url)
        try await store.save(article: item)
        let repository = try await LocalLibrarySyncRepository(store: store)

        do {
            try await repository.enqueue(try SyncPendingChange(operation: .create, recordID: revisionRecord.id, record: revisionRecord))
            XCTFail("expected an unresolvable revision to fail")
        } catch {
            XCTAssertEqual(error as? WiltedSyncError, .invalidValue(field: "validatedLocalMedia"))
        }
    }

    func testExplicitItemDeletionRetainsProtectedRevisionFamilyAsConflict() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("protected-family")
        let bytes = Data("family-media".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mediaURL = url.deletingLastPathComponent().appendingPathComponent("family.m4a")
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-family"), durationSeconds: 4,
                                         byteCount: Int64(bytes.count), contentHash: hash, mediaType: "audio/mp4",
                                         createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_020)), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let itemRecord = try codec.encode(article: item, currentRevisionID: revision.revisionID)
        let revisionRecord = try codec.encode(revision: revision, audioAsset: WiltedAsset(assetID: "family", contentHash: hash))
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store, assetResolver: { _, _ in mediaURL })
        let fetched = try SyncFetchBatch(generationID: "family-fetch", records: [itemRecord, revisionRecord], engineState: Data([1]))
        try await repository.commit(try await repository.stage(fetched))
        try await repository.enqueue(try SyncPendingChange(operation: .update, recordID: revisionRecord.id, record: revisionRecord))
        let deleted = try SyncFetchBatch(generationID: "family-delete", records: [], engineState: Data([2]), deletedRecordIDs: [itemRecord.id])
        try await repository.commit(try await repository.stage(deleted))
        let state = await repository.state()
        XCTAssertTrue(state.conflictedRecordIDs.contains(itemRecord.id))
        XCTAssertTrue(state.conflictedRecordIDs.contains(revisionRecord.id))
        let retainedArticle = try await store.article(for: item.itemID)
        let retainedRevision = try await store.readyRevision(for: item.itemID, revisionID: revision.revisionID)
        let familyStatus = try await store.syncStatus(for: item.itemID)
        XCTAssertNotNil(retainedArticle)
        XCTAssertNotNil(retainedRevision)
        XCTAssertEqual(familyStatus, .conflicted)
    }

    func testPartialSendAcknowledgementReopensWithPendingConflictAndServerEnvelope() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try article("send-success"); let second = try article("send-conflict")
        let firstRecord = try record(for: first); let secondRecord = try record(for: second)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        let fetched = try SyncFetchBatch(generationID: "send-fetch", records: [firstRecord, secondRecord], engineState: Data([3]))
        try await repository.commit(try await repository.stage(fetched))
        let update = try SyncPendingChange(operation: .update, recordID: firstRecord.id, record: firstRecord)
        let conflict = try SyncPendingChange(operation: .update, recordID: secondRecord.id, record: secondRecord)
        try await repository.enqueue(update)
        try await repository.enqueue(conflict)

        let outcome = try SyncSendResult(
            engineState: Data([4]),
            acknowledgedRecordIDs: [firstRecord.id],
            serverEnvelopes: [firstRecord],
            failures: [SyncSendFailure(recordID: secondRecord.id, disposition: .conflict, serverRecord: secondRecord)])
        try await repository.acknowledge(outcome)
        let state = await repository.state()
        XCTAssertEqual(state.engineState, Data([4]))
        XCTAssertFalse(state.pendingChanges.contains(where: { $0.recordID == firstRecord.id }))
        XCTAssertTrue(state.pendingChanges.contains(where: { $0.recordID == secondRecord.id }))
        XCTAssertTrue(state.conflictedRecordIDs.contains(secondRecord.id))
        XCTAssertEqual(state.conflictServerRecords[secondRecord.id], secondRecord)
        let firstStatus = try await store.syncStatus(for: first.itemID)
        let secondStatus = try await store.syncStatus(for: second.itemID)
        XCTAssertEqual(firstStatus, .remoteAcknowledged)
        XCTAssertEqual(secondStatus, .conflicted)

        let reopened = try await LocalLibrarySyncRepository(store: try LocalLibraryStore(url: url))
        let reopenedState = await reopened.state()
        XCTAssertEqual(reopenedState, state)
    }

    func testAcknowledgedDeleteRemovesPendingAndMonotonicallyAcknowledgesTombstone() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("send-delete"); let itemRecord = try record(for: item)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        try await repository.commit(try await repository.stage(try SyncFetchBatch(generationID: "delete-fetch", records: [itemRecord], engineState: Data([1]))))
        let tombstone = SyncTombstone(itemID: item.itemID, generationID: "delete-send", requestedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_010)))
        let pending = try SyncPendingChange(operation: .delete, recordID: itemRecord.id, tombstone: tombstone)
        try await repository.enqueue(pending)
        try await repository.acknowledge(try SyncSendResult(engineState: Data([2]), acknowledgedRecordIDs: [itemRecord.id]))
        let state = await repository.state()
        XCTAssertTrue(state.pendingChanges.isEmpty)
        XCTAssertEqual(state.tombstones.first?.remoteAcknowledged, true)
        let savedArticle = try await store.article(for: item.itemID)
        XCTAssertNil(savedArticle)
    }

    func testRetryableAndTerminalFailuresRemainPendingWithDistinctStatuses() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let retry = try article("retryable"); let terminal = try article("terminal")
        let retryRecord = try record(for: retry); let terminalRecord = try record(for: terminal)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        try await repository.commit(try await repository.stage(try SyncFetchBatch(generationID: "failure-fetch", records: [retryRecord, terminalRecord], engineState: Data([1]))))
        try await repository.enqueue(try SyncPendingChange(operation: .update, recordID: retryRecord.id, record: retryRecord))
        try await repository.enqueue(try SyncPendingChange(operation: .update, recordID: terminalRecord.id, record: terminalRecord))
        let result = try SyncSendResult(engineState: Data([2]), failures: [
            SyncSendFailure(recordID: retryRecord.id, disposition: .retryable),
            SyncSendFailure(recordID: terminalRecord.id, disposition: .terminal)
        ])
        try await repository.acknowledge(result)
        let state = await repository.state()
        XCTAssertEqual(state.pendingChanges.count, 2)
        let retryStatus = try await store.syncStatus(for: retry.itemID)
        let terminalStatus = try await store.syncStatus(for: terminal.itemID)
        XCTAssertEqual(retryStatus, .pendingUpload)
        XCTAssertEqual(terminalStatus, .failedUpload)
    }

    func testAcknowledgementRejectsUnknownOrUnmatchedSaveOutcome() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("ack-validation"); let itemRecord = try record(for: item)
        let unknown = try record(for: article("unknown"))
        let repository = try await LocalLibrarySyncRepository(store: try LocalLibraryStore(url: url))
        try await repository.commit(try await repository.stage(try SyncFetchBatch(generationID: "ack-validation-fetch", records: [itemRecord], engineState: Data([1]))))
        do {
            try await repository.acknowledge(try SyncSendResult(engineState: Data([2]), acknowledgedRecordIDs: [unknown.id], serverEnvelopes: [unknown]))
            XCTFail("Expected unknown acknowledgement rejection")
        } catch let error as WiltedSyncError {
            XCTAssertEqual(error, .invalidValue(field: "send result pendingRecordID"))
        }
        try await repository.enqueue(try SyncPendingChange(operation: .update, recordID: itemRecord.id, record: itemRecord))
        do {
            try await repository.acknowledge(try SyncSendResult(engineState: Data([3]), acknowledgedRecordIDs: [itemRecord.id]))
            XCTFail("Expected missing server envelope rejection")
        } catch let error as WiltedSyncError {
            XCTAssertEqual(error, .invalidValue(field: "send result serverEnvelope"))
        }
    }

    func testStaleCommitFailureLeavesStateUnchanged() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try record(for: article("first")); let second = try record(for: article("second"))
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        let initial = try SyncFetchBatch(generationID: "initial", records: [first], engineState: Data([1]))
        try await repository.commit(try await repository.stage(initial))
        let staged = try await repository.stage(try SyncFetchBatch(generationID: "staged", records: [second], engineState: Data([2])))
        let localChange = try SyncPendingChange(operation: .create, recordID: first.id, record: first)
        try await repository.enqueue(localChange)
        let before = await repository.state()
        do {
            try await repository.commit(staged)
            XCTFail("Expected stale staged batch")
        } catch let error as WiltedSyncError {
            XCTAssertEqual(error, .staleStagedBatch)
        }
        let after = await repository.state()
        XCTAssertEqual(after, before)
    }

    func testIncrementalMergeRetainsAbsentRecords() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try record(for: article("first")); let second = try record(for: article("second"))
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        let initial = try SyncFetchBatch(generationID: "initial", records: [first, second], engineState: Data([1]))
        try await repository.commit(try await repository.stage(initial))
        let incremental = try SyncFetchBatch(generationID: "incremental", records: [first], engineState: Data([2]), kind: .incremental)
        try await repository.commit(try await repository.stage(incremental))
        let state = await repository.state()
        XCTAssertEqual(Set(state.records.map(\.id)), Set([first.id, second.id]))
    }

    func testFullSnapshotDeletesOnlyRemoteAcknowledgedUnprotectedRecords() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let acknowledged = try record(for: article("ack")); let localOnly = try record(for: article("local")); let protected = try record(for: article("protected"))
        let initial = SyncRepositoryState(records: [acknowledged, localOnly, protected], engineState: Data([1]),
                                          remoteAcknowledgedRecordIDs: [acknowledged.id], protectedRecordIDs: [protected.id])
        let repository = try await LocalLibrarySyncRepository(store: try LocalLibraryStore(url: url), initialState: initial)
        let full = try SyncFetchBatch(generationID: "full", records: [], engineState: Data([2]), kind: .fullSnapshot)
        try await repository.commit(try await repository.stage(full))
        let records = await repository.state().records
        XCTAssertEqual(Set(records.map(\.id)), Set([localOnly.id, protected.id]))
    }

    func testStatusEmitsStagingAndCommitProgress() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = try await LocalLibrarySyncRepository(store: try LocalLibraryStore(url: url))
        let batch = try SyncFetchBatch(generationID: "status", records: [], engineState: Data([1]))
        let staged = try await repository.stage(batch)
        let staging = await repository.statuses.first { $0.phase == .staging }
        XCTAssertEqual(staging?.generationID, "status")
        try await repository.commit(staged)
        let committing = await repository.statuses.first { $0.phase == .committing }
        XCTAssertEqual(committing?.generationID, "status")
    }

    func testNoOpFetchAndSendPreservePriorEngineState() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let priorState = Data([7, 8, 9])
        let repository = try await LocalLibrarySyncRepository(
            store: try LocalLibraryStore(url: url),
            initialState: SyncRepositoryState(engineState: priorState))

        let batch = try SyncFetchBatch(generationID: "no-op", records: [])
        try await repository.commit(try await repository.stage(batch))
        let stateAfterFetch = await repository.state()
        XCTAssertEqual(stateAfterFetch.engineState, priorState)

        try await repository.acknowledge(try SyncSendResult())
        let stateAfterSend = await repository.state()
        XCTAssertEqual(stateAfterSend.engineState, priorState)
    }

    func testAccountChangeQuarantinePersistsConflictsAndRetainsLocalLibrary() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("account-change")
        let revisionID = try RevisionID(rawValue: "rev-account-change")
        let media = Data("account-change-media".utf8)
        let mediaURL = url.deletingLastPathComponent().appendingPathComponent("account-change.m4a")
        try FileManager.default.createDirectory(at: mediaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try media.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: media).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(
            itemID: item.itemID, revisionID: revisionID, durationSeconds: 3,
            byteCount: Int64(media.count), contentHash: hash, mediaType: "audio/mp4",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_040)), schemaVersion: 1)
        let playback = try PlaybackState(
            itemID: item.itemID, revisionID: revisionID, sessionID: "account-session", sequence: 2,
            positionSeconds: 1, durationSeconds: 3, completed: false, intent: .progress,
            deviceID: "account-device", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_041)))
        let codec = WiltedRecordCodec()
        let itemRecord = try codec.encode(article: item, currentRevisionID: revisionID)
        let revisionRecord = try codec.encode(
            revision: revision,
            audioAsset: WiltedAsset(assetID: "account-media", contentHash: hash))
        let playbackRecord = try codec.encode(playback: playback)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store, assetResolver: { _, _ in mediaURL })
        let fetched = try SyncFetchBatch(
            generationID: "account-seed", records: [itemRecord, revisionRecord, playbackRecord],
            engineState: Data([4, 2]))
        try await repository.commit(try await repository.stage(fetched))
        let pending = try SyncPendingChange(operation: .update, recordID: itemRecord.id, record: itemRecord)
        try await repository.enqueue(pending)
        let statuses = await repository.statuses

        try await repository.quarantineAfterAccountChange()

        let state = await repository.state()
        XCTAssertNil(state.engineState)
        XCTAssertEqual(state.pendingChanges, [pending])
        XCTAssertTrue(state.conflictedRecordIDs.contains(itemRecord.id))
        XCTAssertTrue(state.protectedRecordIDs.contains(itemRecord.id))
        XCTAssertEqual(state.records.first(where: { $0.id == itemRecord.id }), itemRecord)
        let persistedSyncState = try await store.syncState(for: "private-zone")
        let persistedStatus = try await store.syncStatus(for: item.itemID)
        let persistedArticle = try await store.article(for: item.itemID)
        let persistedRevision = try await store.readyRevision(for: item.itemID, revisionID: revisionID)
        let persistedPlayback = try await store.playbackState(for: item.itemID, revisionID: revisionID)
        let persistedMedia = try Data(contentsOf: mediaURL)
        XCTAssertEqual(persistedSyncState?.engineState, Data())
        XCTAssertEqual(persistedStatus, .conflicted)
        XCTAssertEqual(persistedArticle, item)
        XCTAssertEqual(persistedRevision?.mediaURL, mediaURL)
        XCTAssertEqual(persistedPlayback, playback)
        XCTAssertEqual(persistedMedia, media)
        let completed = await statuses.first {
            $0.phase == .completed && $0.message.contains("quarantined after iCloud account change")
        }
        XCTAssertNotNil(completed)

        let reopenedStore = try LocalLibraryStore(url: url)
        let reopened = try await LocalLibrarySyncRepository(store: reopenedStore, assetResolver: { _, _ in mediaURL })
        let reopenedState = await reopened.state()
        let reopenedArticle = try await reopenedStore.article(for: item.itemID)
        let reopenedRevision = try await reopenedStore.readyRevision(for: item.itemID, revisionID: revisionID)
        let reopenedPlayback = try await reopenedStore.playbackState(for: item.itemID, revisionID: revisionID)
        XCTAssertEqual(reopenedState, state)
        XCTAssertEqual(reopenedArticle, item)
        XCTAssertEqual(reopenedRevision?.mediaURL, mediaURL)
        XCTAssertEqual(reopenedPlayback, playback)
    }

    func testAccountReviewReleasesQuarantinedWorkSoItCanBeSentAgain() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("account-review"); let itemRecord = try record(for: item)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        let pending = try SyncPendingChange(operation: .update, recordID: itemRecord.id, record: itemRecord)
        try await repository.enqueue(pending)
        try await repository.quarantineAfterAccountChange()
        let quarantined = await repository.state()
        XCTAssertTrue(quarantined.conflictedRecordIDs.contains(itemRecord.id))

        try await repository.resumeAfterAccountReview()

        let state = await repository.state()
        XCTAssertFalse(state.conflictedRecordIDs.contains(itemRecord.id))
        XCTAssertEqual(state.pendingChanges, [pending])
        XCTAssertTrue(state.protectedRecordIDs.contains(itemRecord.id))
        let persistedStatus = try await store.syncStatus(for: item.itemID)
        XCTAssertEqual(persistedStatus, .pendingUpload)
        // SyncCoordinator drops conflicted records from every batch, so this filter is the
        // property the release exists to restore.
        XCTAssertEqual(state.pendingChanges.filter { !state.conflictedRecordIDs.contains($0.recordID) }, [pending])
        let reopened = try await LocalLibrarySyncRepository(store: try LocalLibraryStore(url: url))
        let reopenedState = await reopened.state()
        XCTAssertEqual(reopenedState, state)
    }

    func testAccountReviewKeepsGenuineRemoteConflictsQuarantined() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("account-review-conflict"); let itemRecord = try record(for: item)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        let pending = try SyncPendingChange(operation: .update, recordID: itemRecord.id, record: itemRecord)
        try await repository.enqueue(pending)
        let serverRecord = try record(for: item)
        try await repository.acknowledge(try SyncSendResult(
            engineState: Data([9]),
            failures: [SyncSendFailure(recordID: itemRecord.id, disposition: .conflict, serverRecord: serverRecord)]))
        try await repository.quarantineAfterAccountChange()

        try await repository.resumeAfterAccountReview()

        let state = await repository.state()
        XCTAssertTrue(state.conflictedRecordIDs.contains(itemRecord.id))
        XCTAssertEqual(state.conflictServerRecords[itemRecord.id], serverRecord)
        let persistedStatus = try await store.syncStatus(for: item.itemID)
        XCTAssertEqual(persistedStatus, .conflicted)
    }

    func testAccountChangeQuarantineFailureLeavesStateUnchanged() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let itemRecord = try record(for: article("account-failure"))
        let pending = try SyncPendingChange(operation: .update, recordID: itemRecord.id, record: itemRecord)
        let initial = SyncRepositoryState(
            records: [itemRecord], engineState: Data([9]), pendingChanges: [pending])
        let repository = try await LocalLibrarySyncRepository(
            store: try LocalLibraryStore(url: url), initialState: initial,
            beforeCommit: { throw WiltedSyncError.injectedFailure("account-quarantine") })
        let statuses = await repository.statuses

        do {
            try await repository.quarantineAfterAccountChange()
            XCTFail("Expected injected account quarantine failure")
        } catch let error as WiltedSyncError {
            XCTAssertEqual(error, .injectedFailure("account-quarantine"))
        }
        let state = await repository.state()
        XCTAssertEqual(state, initial)
        let failed = await statuses.first { $0.phase == .failed }
        XCTAssertNotNil(failed)
    }

    func testRemotePlaybackUsesCausalMergeBeforeApplying() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("playback")
        let revisionID = try RevisionID(rawValue: "rev-playback")
        let first = try PlaybackState(itemID: item.itemID, revisionID: revisionID, sessionID: "session-1", sequence: 2,
                                      positionSeconds: 20, durationSeconds: 100, completed: false, intent: .progress,
                                      deviceID: "device-remote", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_001)))
        let stale = try PlaybackState(itemID: item.itemID, revisionID: revisionID, sessionID: "session-1", sequence: 1,
                                      positionSeconds: 10, durationSeconds: 100, completed: false, intent: .progress,
                                      deviceID: "device-remote", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_002)))
        let codec = WiltedRecordCodec()
        let firstRecord = try codec.encode(playback: first, sidecar: WiltedOpaqueSidecar(changeTag: "tag-1"))
        let staleRecord = try codec.encode(playback: stale, sidecar: WiltedOpaqueSidecar(changeTag: "tag-1"))
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        for (generation, record) in [("playback-1", firstRecord), ("playback-2", staleRecord)] {
            let batch = try SyncFetchBatch(generationID: generation, records: [record], engineState: Data([1]))
            try await repository.commit(try await repository.stage(batch))
        }
        let saved = try await store.playbackState(for: item.itemID, revisionID: revisionID)
        XCTAssertEqual(saved?.positionSeconds, 20)
        XCTAssertEqual(saved?.sequence, 2)
    }

    func testInjectedPreSaveFailureLeavesStoreUnchanged() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("failure")
        let record = try self.record(for: item)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store, beforeCommit: { throw WiltedSyncError.injectedFailure("pre-save") })
        let batch = try SyncFetchBatch(generationID: "failure", records: [record], engineState: Data([1]))
        do {
            try await repository.commit(try await repository.stage(batch))
            XCTFail("Expected injected pre-save failure")
        } catch let error as WiltedSyncError {
            XCTAssertEqual(error, .injectedFailure("pre-save"))
        }
        let savedArticle = try await store.article(for: item.itemID)
        let savedRepositoryState = try await store.syncRepositoryState()
        XCTAssertNil(savedArticle)
        XCTAssertNil(savedRepositoryState)
        let repositoryState = await repository.state()
        XCTAssertTrue(repositoryState.records.isEmpty)
    }

    func testInjectedAcknowledgementFailureLeavesPriorStateAndEngineBytes() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("ack-failure")
        let itemRecord = try record(for: item)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        try await repository.commit(try await repository.stage(try SyncFetchBatch(generationID: "ack-failure-fetch", records: [itemRecord], engineState: Data([1]))))
        try await repository.enqueue(try SyncPendingChange(operation: .update, recordID: itemRecord.id, record: itemRecord))
        let before = await repository.state()
        let failing = try await LocalLibrarySyncRepository(store: store, beforeCommit: { throw WiltedSyncError.injectedFailure("ack") })
        do {
            let result = try SyncSendResult(engineState: Data([9]), acknowledgedRecordIDs: [itemRecord.id], serverEnvelopes: [itemRecord])
            try await failing.acknowledge(result)
            XCTFail("Expected injected acknowledgement failure")
        } catch let error as WiltedSyncError {
            XCTAssertEqual(error, .injectedFailure("ack"))
        }
        let reopened = try await LocalLibrarySyncRepository(store: try LocalLibraryStore(url: url))
        let reopenedState = await reopened.state()
        let syncState = try await store.syncState(for: "private-zone")
        XCTAssertEqual(reopenedState, before)
        XCTAssertEqual(syncState?.engineState, Data([1]))
    }

    func testRevisionRequiresResolverAndValidatedLocalMedia() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("revision")
        let bytes = Data("validated-media".utf8)
        let mediaURL = url.deletingLastPathComponent().appendingPathComponent("revision.m4a")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-media"), durationSeconds: 10,
                                         byteCount: Int64(bytes.count), contentHash: hash, mediaType: "audio/mp4",
                                         createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_003)), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let articleRecord = try codec.encode(article: item, currentRevisionID: revision.revisionID)
        let revisionRecord = try codec.encode(revision: revision, audioAsset: WiltedAsset(assetID: "remote-media", contentHash: hash))
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store, assetResolver: { _, _ in mediaURL })
        let batch = try SyncFetchBatch(generationID: "revision", records: [articleRecord, revisionRecord], engineState: Data([4]))
        try await repository.commit(try await repository.stage(batch))
        let saved = try await store.readyRevision(for: item.itemID, revisionID: revision.revisionID)
        XCTAssertEqual(saved?.mediaURL, mediaURL)
    }
}
