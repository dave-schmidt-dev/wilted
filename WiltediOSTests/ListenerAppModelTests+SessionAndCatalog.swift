import CryptoKit
import MediaPlayer
import XCTest
@testable import WiltediOS
import WiltedDomain
@testable import WiltedListener
import WiltedSync
import CloudKit
import WiltedCloudKit

extension ListenerAppModelTests {
    func testNextRefreshRebuildsFailedSessionFromPersistedStateOnce() async throws {
        let (records, pendingChanges) = try listenerStaleStageFixture(changeCount: 1)
        let persistedEngineState = Data([1])
        let repository = StaticSyncRepository(state: SyncRepositoryState(
            records: records,
            engineState: persistedEngineState,
            pendingChanges: pendingChanges
        ))
        let failedTransport = RecordingSyncTransport(fetchError: TestSyncError.network)
        let recoveredTransport = RecordingSyncTransport()
        let cancelProbe = SessionCancelProbe()
        let factory = SessionSequenceProbe(
            transports: [failedTransport, recoveredTransport],
            firstCancelProbe: cancelProbe
        )
        let model = WiltedListenerAppModel(
            repository: repository,
            sessionFactory: { stateData in
                try await factory.makeSession(stateData: stateData)
            }
        )

        await model.refresh()
        guard case .failed(_, retryable: true) = model.syncPhase else {
            return XCTFail("Expected the initial transport to fail")
        }
        XCTAssertEqual(model.items.count, 1, "the committed local catalog remains visible")

        await model.refresh()

        XCTAssertEqual(model.syncPhase, .ready)
        let stateInputs = await factory.stateInputs()
        let firstSessionWasCancelled = await cancelProbe.wasCalled
        let failedFetchCount = await failedTransport.fetchCountValue()
        let recoveredFetchCount = await recoveredTransport.fetchCountValue()
        XCTAssertEqual(stateInputs, [persistedEngineState, persistedEngineState])
        XCTAssertTrue(firstSessionWasCancelled)
        XCTAssertEqual(failedFetchCount, 1)
        XCTAssertEqual(recoveredFetchCount, 1)
        let recoveredState = await repository.state()
        XCTAssertEqual(recoveredState.records, records)
        XCTAssertEqual(recoveredState.pendingChanges, pendingChanges)
    }

    func testFailedFetchCommitRebuildsFromCommittedStateBeforeNonEmptySend() async throws {
        let fixture = try listenerCommitHandshakeFixture()
        let committedState = Data([1])
        let provisionalFetchState = Data([2])
        let repository = CommitHandshakeRepository(
            state: SyncRepositoryState(records: fixture.records, engineState: committedState,
                                       pendingChanges: [fixture.pendingChange]),
            commitFailuresRemaining: 1
        )
        let failedTransport = SerializedStateTransport(
            initialState: committedState,
            fetchStates: [provisionalFetchState],
            persistenceCheck: { state in (await repository.state()).engineState == state }
        )
        let recoveredTransport = SerializedStateTransport(
            initialState: committedState,
            persistenceCheck: { state in (await repository.state()).engineState == state }
        )
        let cancellation = SessionCancelProbe()
        let factory = SessionSequenceProbe(
            transports: [failedTransport, recoveredTransport],
            firstCancelProbe: cancellation
        )
        let model = WiltedListenerAppModel(
            repository: repository,
            sessionFactory: { stateData in
                try await factory.makeSession(stateData: stateData)
            }
        )

        await model.refresh()
        guard case .failed(_, retryable: true) = model.syncPhase else {
            return XCTFail("Expected the fetch whose local commit failed to be retryable")
        }

        await model.sendPending()

        let stateInputs = await factory.stateInputs()
        let wasCancelled = await cancellation.wasCalled
        let failedSaveCount = await failedTransport.saveCount()
        let recoveredSentCommits = await recoveredTransport.sentCommitStates()
        let persistedState = await repository.state()
        XCTAssertEqual(stateInputs, [committedState, committedState])
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(failedSaveCount, 0,
                       "the transport carrying provisional fetch state must not send")
        XCTAssertEqual(recoveredSentCommits, [committedState])
        XCTAssertEqual(persistedState.engineState, committedState)
    }

    func testCancelledFetchBeforeLocalCommitRebuildsFromPersistedStateBeforeNonEmptySend() async throws {
        let fixture = try listenerCommitHandshakeFixture()
        let committedState = Data([1])
        let provisionalFetchState = Data([2])
        let stageGate = AsyncEnqueueGate()
        let repository = CommitHandshakeRepository(
            state: SyncRepositoryState(records: fixture.records, engineState: committedState,
                                       pendingChanges: [fixture.pendingChange])
        )
        let provisionalTransport = SerializedStateTransport(
            initialState: committedState,
            fetchStates: [committedState, provisionalFetchState],
            persistenceCheck: { state in (await repository.state()).engineState == state }
        )
        let recoveredTransport = SerializedStateTransport(
            initialState: committedState,
            persistenceCheck: { state in (await repository.state()).engineState == state }
        )
        let cancellation = SessionCancelProbe()
        let factory = SessionSequenceProbe(
            transports: [provisionalTransport, recoveredTransport],
            firstCancelProbe: cancellation
        )
        let model = WiltedListenerAppModel(
            repository: repository,
            sessionFactory: { stateData in
                try await factory.makeSession(stateData: stateData)
            }
        )

        // Load the locally known item first. Sending playback is intentionally
        // limited to items the listener has displayed, so a cancelled first
        // launch fetch would have no sendable changes to exercise this path.
        await model.refresh()
        XCTAssertEqual(model.items.count, 1)
        await repository.setStageGate(stageGate)
        let refresh = Task { await model.refresh() }
        let stageStarted = await stageGate.waitUntilStarted()
        XCTAssertTrue(stageStarted)
        model.cancel()
        await stageGate.release()
        await refresh.value

        await model.sendPending()

        let stateInputs = await factory.stateInputs()
        let wasCancelled = await cancellation.wasCalled
        let provisionalSaveCount = await provisionalTransport.saveCount()
        let recoveredSentCommits = await recoveredTransport.sentCommitStates()
        let persistedState = await repository.state()
        XCTAssertEqual(stateInputs, [committedState, committedState])
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(provisionalSaveCount, 0,
                       "the cancelled session carrying provisional fetch state must not send")
        XCTAssertEqual(recoveredSentCommits, [committedState])
        XCTAssertEqual(persistedState.engineState, committedState)
    }

    func testCommittedFetchAndSendStateSurviveLaterEmptyFetchAndSend() async throws {
        let fixture = try listenerCommitHandshakeFixture()
        let initialState = Data([1])
        let fetchedState = Data([2])
        let sentState = Data([3])
        let repository = CommitHandshakeRepository(
            state: SyncRepositoryState(records: fixture.records, engineState: initialState,
                                       pendingChanges: [fixture.pendingChange])
        )
        let transport = SerializedStateTransport(
            initialState: initialState,
            fetchStates: [fetchedState, sentState],
            sendStates: [sentState],
            persistenceCheck: { state in (await repository.state()).engineState == state }
        )
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        await model.refresh()
        await model.sendPending()
        await model.refresh()
        await model.sendPending()

        let fetchedCommits = await transport.fetchedCommitStates()
        let sentCommits = await transport.sentCommitStates()
        let committedState = await transport.committedState()
        let persistedState = await repository.state()
        let saveCount = await transport.saveCount()
        XCTAssertEqual(fetchedCommits, [fetchedState, sentState])
        XCTAssertEqual(sentCommits, [sentState])
        XCTAssertEqual(committedState, sentState)
        XCTAssertEqual(persistedState.engineState, sentState)
        XCTAssertEqual(saveCount, 1,
                       "the empty send must retain, rather than replace, the latest committed state")
    }

    func testPixelFixturesAreAccountFreeAndExposeTheirIntendedTerminalStates() {
        let library = WiltedListenerAppModel.makePixelFixture()
        XCTAssertEqual(library.syncPhase, .ready)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.transcriptsByItem.values.first?.availability, .available)
        XCTAssertEqual(library.downloadStatistics.fileCount, 1)
        XCTAssertNotNil(library.syncObservability.lastSuccessfulFetchAt)

        let playing = WiltedListenerAppModel.makePixelFixture(state: .nowPlaying)
        XCTAssertEqual(playing.playbackPhase, .playing)
        XCTAssertEqual(playing.selectedPlayback?.positionSeconds, 31)

        let failure = WiltedListenerAppModel.makePixelFixture(state: .terminalFailure)
        XCTAssertEqual(failure.syncPhase, .failed("iCloud account changed; sync is quarantined", retryable: false))
        XCTAssertEqual(failure.items.count, 1)
    }

    func testCatalogPublishesOnlyTranscriptMatchingTheCurrentRevision() async throws {
        let url = URL(string: "https://example.test/transcript-listener")!
        let itemID = try ItemID.derive(from: url)
        let currentRevisionID = try RevisionID(rawValue: "revision-current")
        let oldRevisionID = try RevisionID(rawValue: "revision-old")
        let hash = "sha256:" + String(repeating: "a", count: 64)
        let asset = try WiltedAsset(assetID: "transcript-audio", contentHash: hash)
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Transcript article",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: currentRevisionID,
                                         durationSeconds: 30, byteCount: 16, contentHash: hash,
                                         mediaType: "audio/m4a", createdAt: Timestamp(Date()), schemaVersion: 1)
        let current = try Transcript(itemID: itemID, revisionID: currentRevisionID,
                                     availability: .available, text: "Current transcript",
                                     languageCode: "en", updatedAt: Timestamp(Date()))
        let old = try Transcript(itemID: itemID, revisionID: oldRevisionID,
                                 availability: .available, text: "Old transcript",
                                 languageCode: "en", updatedAt: Timestamp(Date()))
        let codec = WiltedRecordCodec()
        let repository = StaticSyncRepository(state: SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: currentRevisionID),
            try codec.encode(revision: revision, audioAsset: asset),
            try codec.encode(transcript: old),
            try codec.encode(transcript: current),
        ]))
        let model = WiltedListenerAppModel(repository: repository)

        await model.refresh()

        XCTAssertEqual(model.transcriptsByItem[itemID], current)
    }

    func testCatalogSelectsTheArticleDeclaredRevisionOverLaterSupersededRecord() async throws {
        let url = URL(string: "https://example.test/current-revision")!
        let itemID = try ItemID.derive(from: url)
        let currentRevisionID = try RevisionID(rawValue: "revision-current")
        let supersededRevisionID = try RevisionID(rawValue: "revision-superseded-z")
        let currentAsset = try WiltedAsset(assetID: "current-audio",
                                           contentHash: "sha256:" + String(repeating: "a", count: 64))
        let supersededAsset = try WiltedAsset(assetID: "superseded-audio",
                                              contentHash: "sha256:" + String(repeating: "b", count: 64))
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Current revision",
                                  source: "Test", createdAt: Timestamp(Date()))
        let current = try AudioRevision(itemID: itemID, revisionID: currentRevisionID,
                                        durationSeconds: 30, byteCount: 1, contentHash: currentAsset.contentHash,
                                        mediaType: "audio/m4a", createdAt: Timestamp(Date()), schemaVersion: 1)
        let superseded = try AudioRevision(itemID: itemID, revisionID: supersededRevisionID,
                                            durationSeconds: 90, byteCount: 1, contentHash: supersededAsset.contentHash,
                                            mediaType: "audio/m4a", createdAt: Timestamp(Date()), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let repository = StaticSyncRepository(state: SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: currentRevisionID),
            try codec.encode(revision: current, audioAsset: currentAsset),
            try codec.encode(revision: superseded, audioAsset: supersededAsset),
        ]))
        let model = WiltedListenerAppModel(repository: repository)

        await model.refresh()

        XCTAssertEqual(model.items.first?.revisionID, currentRevisionID)
        XCTAssertEqual(model.items.first?.durationSeconds, current.durationSeconds)
    }

    func testPlayStartsCurrentRevisionWhenCachedPlaybackHasAnotherRevision() async throws {
        let staleRevisionID = try RevisionID(rawValue: "revision-stale")
        let harness = try await PlaybackHarness.make(cachedPlaybackRevisionID: staleRevisionID)

        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)

        let selected = try XCTUnwrap(harness.model.selectedPlayback)
        XCTAssertEqual(selected.revisionID, harness.model.items.first?.revisionID)
        XCTAssertEqual(selected.positionSeconds, 0)
    }

    func testRebuildMergesPlaybackCausallyInsteadOfUsingRecordOrder() async throws {
        let url = URL(string: "https://example.test/causal-playback")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-causal-playback")
        let asset = try WiltedAsset(assetID: "causal-audio",
                                    contentHash: "sha256:" + String(repeating: "c", count: 64))
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Causal playback",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID,
                                         durationSeconds: 30, byteCount: 1, contentHash: asset.contentHash,
                                         mediaType: "audio/m4a", createdAt: Timestamp(Date()), schemaVersion: 1)
        let first = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "causal-session",
                                      sequence: 1, positionSeconds: 4, durationSeconds: 30, completed: false,
                                      intent: .progress, deviceID: "iphone", updatedAt: Timestamp(Date()))
        let latest = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "causal-session",
                                       sequence: 2, positionSeconds: 11, durationSeconds: 30, completed: false,
                                       intent: .progress, deviceID: "iphone", updatedAt: Timestamp(Date()))
        let staleTag = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "causal-session",
                                         sequence: 3, positionSeconds: 18, durationSeconds: 30, completed: false,
                                         intent: .progress, deviceID: "iphone", updatedAt: Timestamp(Date()))
        let codec = WiltedRecordCodec()
        let playbackID = try WiltedRecordID.playback(itemID, revisionID)
        let repository = StaticSyncRepository(state: SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: revisionID),
            try codec.encode(revision: revision, audioAsset: asset),
            try codec.encode(playback: latest, sidecar: WiltedOpaqueSidecar(changeTag: "tag-current")),
            try codec.encode(playback: first, sidecar: WiltedOpaqueSidecar(changeTag: "tag-current")),
            try codec.encode(playback: staleTag, sidecar: WiltedOpaqueSidecar(changeTag: "tag-stale")),
        ]))
        let model = WiltedListenerAppModel(repository: repository,
                                           metadataLoader: { ListenerMetadata(lastPlayedRecordID: playbackID) })

        await model.refresh()

        XCTAssertEqual(model.selectedPlayback?.sequence, latest.sequence)
        XCTAssertEqual(model.selectedPlayback?.positionSeconds, latest.positionSeconds)
    }

    func testSettingsFactsLoadPersistedFetchAndCacheStatistics() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiltedSettingsFacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ListenerRepository(directoryURL: root)
        let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.recordSuccessfulFetch(at: date)
        let bytes = Data("settings-cache".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = try WiltedAsset(assetID: "settings-cache", contentHash: "sha256:\(digest)")
        _ = try await cache.store(data: bytes, asset: asset)
        let model = WiltedListenerAppModel(repository: repository, cache: cache)

        await model.start()

        XCTAssertEqual(model.syncObservability.lastSuccessfulFetchAt, date)
        XCTAssertEqual(model.downloadStatistics, ListenerDownloadStatistics(fileCount: 1, byteCount: Int64(bytes.count)))
    }

    func testEveryTypedAccountChangeQuarantinesTheListener() async throws {
        let source = AccountSignalSource()
        let repository = StaticSyncRepository(state: SyncRepositoryState(engineState: Data([1])))
        let transport = RecordingSyncTransport()
        let model = WiltedListenerAppModel(repository: repository, sessionFactory: { _ in
            TestSyncSession(transport: transport, accountChanges: source.stream)
        })

        await model.refresh()
        for type in [ListenerAccountChangeType.signIn, .signOut, .switchAccounts] {
            source.send(.quarantined(type))
            let expected = type.userFacingName
            var observed = false
            for _ in 0..<100 {
                if case let .failed(message, retryable) = model.syncPhase,
                   message.contains(expected), !retryable {
                    observed = true
                    break
                }
                await Task.yield()
            }
            XCTAssertTrue(observed, "Expected quarantine for \(expected)")
        }
    }

    func testResetDoesNotSendQuarantinedPendingPlayback() async throws {
        let url = URL(string: "https://example.test/account-reset")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-account-reset")
        let asset = try WiltedAsset(assetID: "audio-account-reset",
                                    contentHash: "sha256:" + String(repeating: "a", count: 64))
        let codec = WiltedRecordCodec()
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Account reset",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                        byteCount: 1, contentHash: asset.contentHash,
                                        mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
        let playback = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "old-account",
                                         sequence: 1, positionSeconds: 5, durationSeconds: 30,
                                         completed: false, intent: .progress, deviceID: "iphone",
                                         updatedAt: Timestamp(Date()))
        let itemRecord = try codec.encode(article: article, currentRevisionID: revisionID)
        let revisionRecord = try codec.encode(revision: revision, audioAsset: asset)
        let playbackRecord = try codec.encode(playback: playback)
        let change = try SyncPendingChange(operation: .update, recordID: playbackRecord.id, record: playbackRecord)
        let repository = StaticSyncRepository(state: SyncRepositoryState(
            records: [itemRecord, revisionRecord, playbackRecord], engineState: Data([1]),
            pendingChanges: [change], conflictedRecordIDs: [change.recordID]))
        let transport = RecordingSyncTransport()
        let model = WiltedListenerAppModel(repository: repository, sessionFactory: { _ in
            TestSyncSession(transport: transport)
        })

        await model.refresh()
        await model.resetAfterAccountChange()
        await model.sendPending()

        let sent = await transport.savedChanges()
        XCTAssertTrue(sent.isEmpty)
    }

    func testAFullyConflictedPlaybackQueueReportsHeldWorkInsteadOfReady() async throws {
        let url = URL(string: "https://example.test/held-playback")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-held-playback")
        let asset = try WiltedAsset(assetID: "audio-held-playback",
                                    contentHash: "sha256:" + String(repeating: "b", count: 64))
        let codec = WiltedRecordCodec()
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Held playback",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                         byteCount: 1, contentHash: asset.contentHash,
                                         mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
        let playback = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "held",
                                         sequence: 1, positionSeconds: 5, durationSeconds: 30,
                                         completed: false, intent: .progress, deviceID: "iphone",
                                         updatedAt: Timestamp(Date()))
        let itemRecord = try codec.encode(article: article, currentRevisionID: revisionID)
        let revisionRecord = try codec.encode(revision: revision, audioAsset: asset)
        let playbackRecord = try codec.encode(playback: playback)
        let change = try SyncPendingChange(operation: .update, recordID: playbackRecord.id, record: playbackRecord)
        let repository = StaticSyncRepository(state: SyncRepositoryState(
            records: [itemRecord, revisionRecord, playbackRecord], engineState: Data([1]),
            pendingChanges: [change], conflictedRecordIDs: [change.recordID],
            conflictServerRecords: [change.recordID: playbackRecord]))
        let transport = RecordingSyncTransport()
        let model = WiltedListenerAppModel(repository: repository, sessionFactory: { _ in
            TestSyncSession(transport: transport)
        })

        await model.refresh()
        await model.sendPending()

        // Every queued update is conflicted, so nothing left the device. Reporting ready here
        // is indistinguishable from having had nothing to send.
        let sent = await transport.savedChanges()
        XCTAssertTrue(sent.isEmpty)
        guard case let .failed(message, retryable) = model.syncPhase else {
            XCTFail("Expected a held-work failure, got \(model.syncPhase)")
            return
        }
        XCTAssertEqual(message, "Nothing was sent. 1 playback update is held by unresolved conflicts.")
        XCTAssertTrue(retryable)
    }

}
