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
    func testChunkedCatalogRefreshDefersAudioRetrievalUntilDownload() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let loader = CountingChunkLoader(data: fixture.bytes)
        let model = WiltedListenerAppModel(repository: fixture.repository, transport: RecordingSyncTransport(),
                                           cache: fixture.cache,
                                           audioChunkLoader: { itemID, revisionID, manifest in
                                               try await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
                                           })

        await model.refresh()
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        let initialLoadCount = await loader.count
        XCTAssertEqual(initialLoadCount, 0)

        await model.download(itemID: fixture.itemID)

        let loadCount = await loader.count
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(model.items.first?.state, .downloaded)
        let cachedURL = await fixture.cache.url(for: fixture.asset)
        XCTAssertNotNil(cachedURL)
    }

    func testLegacyRevisionDownloadsThroughDirectRecordFetch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-legacy-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloudRoot = root.appendingPathComponent("CloudAssets", isDirectory: true)
        let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
        let stager = try FileCloudKitAssetStager(rootURL: cloudRoot)
        let mapper = try CloudKitRecordMapper(stager: stager)
        let bytes = Data("legacy-listener-audio".utf8)
        let source = root.appendingPathComponent("legacy-source.m4a")
        try bytes.write(to: source)
        let contentHash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let itemID = try ItemID.derive(from: URL(string: "https://example.test/legacy-listener")!)
        let revisionID = try RevisionID(rawValue: "revision-legacy-listener")
        let article = try Article(
            itemID: itemID,
            canonicalURL: URL(string: "https://example.test/legacy-listener")!,
            title: "Legacy listener",
            source: "Test",
            createdAt: Timestamp(Date())
        )
        let revision = try AudioRevision(
            itemID: itemID,
            revisionID: revisionID,
            durationSeconds: 12,
            byteCount: Int64(bytes.count),
            contentHash: contentHash,
            mediaType: "audio/mp4",
            createdAt: Timestamp(Date()),
            schemaVersion: 1
        )
        let codec = WiltedRecordCodec()
        let legacyEnvelope = try codec.encode(
            revision: revision,
            audioAsset: WiltedAsset(assetID: "legacy-write-fixture", contentHash: contentHash)
        )
        let cloudRecord = try mapper.encode(legacyEnvelope, assetURLs: ["legacy-write-fixture": source])
        let metadataEnvelope = try mapper.decodeMetadataOnly(cloudRecord).envelope
        let repository = StaticSyncRepository(state: SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: revisionID),
            metadataEnvelope,
        ]))
        let driver = LegacyAssetEngineDriver(record: cloudRecord)
        let transport = try CloudKitSyncTransport(driver: driver, role: .iphone, mapper: mapper)
        let model = WiltedListenerAppModel(
            repository: repository,
            cache: cache,
            assetLoader: { recordID, asset in
                try await transport.fetchLegacyRevisionAsset(recordID: recordID, expectedAsset: asset)
            }
        )

        await model.refresh()
        await model.download(itemID: itemID)

        let cached = await cache.url(for: try XCTUnwrap(model.items.first?.asset))
        let requestedRecordNames = await driver.requestedRecordNames()
        XCTAssertEqual(model.items.first?.state, .downloaded)
        XCTAssertEqual(try cached.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(requestedRecordNames, [legacyEnvelope.id.recordName])
    }

    func testQuarantinedLegacyRevisionDownloadLeavesMetadataOnlyAndNoCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-legacy-quarantine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
        let stager = try FileCloudKitAssetStager(
            rootURL: root.appendingPathComponent("CloudAssets", isDirectory: true)
        )
        let mapper = try CloudKitRecordMapper(stager: stager)
        let bytes = Data("legacy-quarantined-audio".utf8)
        let source = root.appendingPathComponent("legacy-source.m4a")
        try bytes.write(to: source)
        let contentHash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let itemID = try ItemID.derive(from: URL(string: "https://example.test/legacy-quarantine")!)
        let revisionID = try RevisionID(rawValue: "revision-legacy-quarantine")
        let article = try Article(
            itemID: itemID,
            canonicalURL: URL(string: "https://example.test/legacy-quarantine")!,
            title: "Legacy quarantine",
            source: "Test",
            createdAt: Timestamp(Date())
        )
        let revision = try AudioRevision(
            itemID: itemID,
            revisionID: revisionID,
            durationSeconds: 12,
            byteCount: Int64(bytes.count),
            contentHash: contentHash,
            mediaType: "audio/mp4",
            createdAt: Timestamp(Date()),
            schemaVersion: 1
        )
        let codec = WiltedRecordCodec()
        let legacyEnvelope = try codec.encode(
            revision: revision,
            audioAsset: WiltedAsset(assetID: "legacy-quarantine-fixture", contentHash: contentHash)
        )
        let cloudRecord = try mapper.encode(
            legacyEnvelope,
            assetURLs: ["legacy-quarantine-fixture": source]
        )
        let metadataEnvelope = try mapper.decodeMetadataOnly(cloudRecord).envelope
        let repository = StaticSyncRepository(state: SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: revisionID),
            metadataEnvelope,
        ]))
        let driver = LegacyAssetEngineDriver(record: cloudRecord, holdRecordFetch: true)
        let transport = try CloudKitSyncTransport(driver: driver, role: .iphone, mapper: mapper)
        let model = WiltedListenerAppModel(
            repository: repository,
            cache: cache,
            assetLoader: { recordID, asset in
                try await transport.fetchLegacyRevisionAsset(recordID: recordID, expectedAsset: asset)
            }
        )

        await model.refresh()
        let download = Task { await model.download(itemID: itemID) }
        let fetchStarted = await driver.waitForRecordFetch()
        XCTAssertTrue(fetchStarted)
        await driver.emit(.accountChanged(.switchAccounts))
        for _ in 0..<100 {
            if await transport.isQuarantined() { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let quarantined = await transport.isQuarantined()
        XCTAssertTrue(quarantined)
        await driver.releaseRecordFetch()
        await download.value

        let cached = await cache.url(for: try XCTUnwrap(model.items.first?.asset))
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        XCTAssertNil(cached)
    }

    func testCorruptChunkDownloadLeavesMetadataOnlyAndNoCache() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let model = WiltedListenerAppModel(repository: fixture.repository, transport: RecordingSyncTransport(),
                                           cache: fixture.cache,
                                           audioChunkLoader: { _, _, _ in Data("corrupt".utf8) })

        await model.refresh()
        await model.download(itemID: fixture.itemID)

        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        let cachedURL = await fixture.cache.url(for: fixture.asset)
        XCTAssertNil(cachedURL)
        guard case let .failed(message, retryable) = model.syncPhase else {
            return XCTFail("Expected a retryable download failure")
        }
        XCTAssertTrue(message.contains("Download failed"))
        XCTAssertTrue(retryable)
    }

    func testMissingChunkDownloadLeavesMetadataOnlyAndReportsRetryableFailure() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let model = WiltedListenerAppModel(repository: fixture.repository, transport: RecordingSyncTransport(),
                                           cache: fixture.cache,
                                           audioChunkLoader: { _, _, _ in throw TestSyncError.network })

        await model.refresh()
        await model.download(itemID: fixture.itemID)

        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        XCTAssertEqual(model.syncPhase, .failed("Download failed: network unavailable", retryable: true))
    }

    func testDownloadReportsBusyStateAndRejectsADuplicateRequest() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let loader = BlockingChunkLoader(data: fixture.bytes)
        let model = WiltedListenerAppModel(repository: fixture.repository, transport: RecordingSyncTransport(),
                                           cache: fixture.cache,
                                           audioChunkLoader: { itemID, revisionID, manifest in
                                               await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
                                           })
        await model.refresh()

        let first = Task { await model.download(itemID: fixture.itemID) }
        for _ in 0..<100 {
            if await loader.count > 0 { break }
            await Task.yield()
        }

        XCTAssertEqual(model.downloadingItemID, fixture.itemID)
        XCTAssertTrue(model.syncPhase.isBusy)
        await model.download(itemID: fixture.itemID)
        let loadCount = await loader.count
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(model.downloadRequestFeedback, "Download already in progress.")
        await loader.release()
        await first.value
        XCTAssertNil(model.downloadingItemID)
        XCTAssertNil(model.downloadRequestFeedback)
        XCTAssertEqual(model.items.first?.state, .downloaded)
    }

    func testCancelledChunkDownloadCannotCompleteOverItsRetry() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let loader = BlockingChunkLoader(data: fixture.bytes)
        let model = WiltedListenerAppModel(repository: fixture.repository, transport: RecordingSyncTransport(),
                                           cache: fixture.cache,
                                           audioChunkLoader: { itemID, revisionID, manifest in
                                               await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
                                           })
        await model.refresh()

        let cancelled = Task { await model.download(itemID: fixture.itemID) }
        for _ in 0..<100 {
            if await loader.count == 1 { break }
            await Task.yield()
        }
        model.cancel()

        let retry = Task { await model.download(itemID: fixture.itemID) }
        for _ in 0..<100 {
            if await loader.count == 2 { break }
            await Task.yield()
        }

        await loader.release()
        await cancelled.value
        XCTAssertEqual(model.items.first?.state, .metadataOnly,
                       "the cancelled generation must not publish its completed bytes")
        XCTAssertTrue(model.syncPhase.isBusy,
                      "the cancelled generation must not clear the retry's visible progress")

        await loader.release()
        await retry.value
        XCTAssertEqual(model.items.first?.state, .downloaded)
        XCTAssertEqual(model.syncPhase, .ready)
    }

    func testAccountQuarantineInvalidatesAnActiveChunkDownload() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let signals = AccountSignalSource()
        let loader = BlockingChunkLoader(data: fixture.bytes)
        let cancelProbe = SessionCancelProbe()
        let model = WiltedListenerAppModel(
            repository: fixture.repository,
            sessionFactory: { _ in
                TestSyncSession(
                    transport: RecordingSyncTransport(),
                    accountChanges: signals.stream,
                    audioChunkLoader: { itemID, revisionID, manifest in
                        await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
                    },
                    cancelAction: { await cancelProbe.record() }
                )
            },
            cache: fixture.cache
        )
        await model.refresh()

        let download = Task { await model.download(itemID: fixture.itemID) }
        for _ in 0..<100 {
            if await loader.count == 1 { break }
            await Task.yield()
        }
        signals.send(.quarantined(.switchAccounts))
        for _ in 0..<100 {
            if case .failed(_, retryable: false) = model.syncPhase { break }
            await Task.yield()
        }

        await loader.release()
        await download.value
        let cachedURL = await fixture.cache.url(for: fixture.asset)
        let sessionWasCancelled = await cancelProbe.wasCalled
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        XCTAssertNil(cachedURL)
        XCTAssertTrue(sessionWasCancelled)
        XCTAssertEqual(model.syncPhase,
                       .failed("iCloud account switch detected; sync is quarantined", retryable: false))
    }

    func testAccountQuarantineBlocksANewChunkDownload() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let signals = AccountSignalSource()
        let loader = CountingChunkLoader(data: fixture.bytes)
        let model = WiltedListenerAppModel(
            repository: fixture.repository,
            sessionFactory: { _ in
                TestSyncSession(
                    transport: RecordingSyncTransport(),
                    accountChanges: signals.stream,
                    audioChunkLoader: { itemID, revisionID, manifest in
                        try await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
                    }
                )
            },
            cache: fixture.cache
        )
        await model.refresh()
        signals.send(.quarantined(.signOut))
        for _ in 0..<100 {
            if case .failed(_, retryable: false) = model.syncPhase { break }
            await Task.yield()
        }

        await model.download(itemID: fixture.itemID)

        let loadCount = await loader.count
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        XCTAssertEqual(model.syncPhase,
                       .failed("iCloud sign-out detected; sync is quarantined", retryable: false))
    }

    func makeChunkedCatalogFixture() throws -> ChunkedCatalogFixture {
        let url = URL(string: "https://example.test/chunked-listener")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-chunked-listener")
        let bytes = Data("chunked-listener-audio".utf8)
        let chunked = try AudioChunking.chunk(bytes, chunkSize: 4)
        let contentHash = "sha256:\(chunked.manifest.contentSHA256)"
        let asset = try WiltedAsset(assetID: "audio:\(revisionID.rawValue)", contentHash: contentHash)
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Chunked listener",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                         byteCount: Int64(bytes.count), contentHash: contentHash,
                                         mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let state = SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: revisionID),
            try codec.encode(revision: revision, manifest: chunked.manifest)
        ], engineState: Data([1]))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-listener-chunked-\(UUID().uuidString)", isDirectory: true)
        return try ChunkedCatalogFixture(itemID: itemID, bytes: bytes, asset: asset,
                                         repository: StaticSyncRepository(state: state),
                                         cache: ListenerAudioCache(rootURL: root))
    }
}
