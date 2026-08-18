import Foundation
import Observation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

struct WiltedMacArticle: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let source: String
    let url: URL
    let isReady: Bool
}

struct WiltedMacPreparation: Equatable, Sendable {
    enum Phase: String, Sendable {
        case preparing
        case extracting
        case synthesizing
        case assembling
        case saving
        case cancelling
        case completed
        case cancelled
        case failed

        var title: String {
            switch self {
            case .preparing: "Preparing article"
            case .extracting: "Extracting article"
            case .synthesizing: "Generating speech"
            case .assembling: "Assembling audio"
            case .saving: "Saving revision"
            case .cancelling: "Cancelling preparation"
            case .completed: "Ready to play"
            case .cancelled: "Preparation cancelled"
            case .failed: "Preparation failed"
            }
        }
    }

    let phase: Phase
    let detail: String
    let fraction: Double?
    let cancellable: Bool
}

/// Main-actor presentation state for the local Mac producer.
@Observable
@MainActor
final class WiltedMacModel {
    var urlDraft = ""
    private(set) var articles: [WiltedMacArticle] = []
    private(set) var preparation: WiltedMacPreparation?
    private(set) var selectedArticleID: String?
    private(set) var isNowPlaying = false
    private(set) var isPlaying = false
    private(set) var playbackError: String?

    let fixtureMode: Bool

#if canImport(WiltedProducer)
    private let store: LocalLibraryStore?
    private let coordinator: PreparationCoordinator?
    private let playback: PlaybackController?
    private let syncLifecycle: WiltedMacSyncLifecycle?
    private var preparationRun: PreparationRun?
    private var preparationTask: Task<Void, Never>?
    private var fixtureRevision: StoredAudioRevision?
#endif

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         syncTransportFactory: WiltedMacSyncTransportFactory? = nil,
         assetResolver: @escaping LocalLibraryAssetResolver = { _, _ in nil }) {
        let usesFixtureMode = arguments.contains("--wilted-ui-fixture-article-flow")
            || arguments.contains("--wilted-ui-fixture-quarantined")
        fixtureMode = usesFixtureMode

#if canImport(WiltedProducer)
        let stateDirectory = Self.stateDirectory(fixtureMode: usesFixtureMode)
        let libraryURL = stateDirectory.appendingPathComponent("library.sqlite")
        let mediaDirectory = stateDirectory.appendingPathComponent("media", isDirectory: true)
        let configuredStore = try? LocalLibraryStore(url: libraryURL)
        store = configuredStore
        coordinator = configuredStore.map {
            PreparationCoordinator(store: $0, mediaDirectory: mediaDirectory)
        }
        playback = configuredStore.map {
            PlaybackController(
                store: $0,
                backend: usesFixtureMode ? WiltedFixturePlaybackBackend() : AVAudioPlayerBackend(),
                deviceID: "mac"
            )
        }
        var selectedSyncFactory = syncTransportFactory
#if WILTED_CLOUDKIT_LIVE
        if !usesFixtureMode, selectedSyncFactory == nil, let configuredStore {
            let liveConfiguration = WiltedMacLiveSyncConfiguration(
                database: CKContainer(identifier: "iCloud.com.zerodelta.wilted").privateCloudDatabase,
                assetRootURL: mediaDirectory,
                store: configuredStore,
                assetResolver: assetResolver
            )
            selectedSyncFactory = makeWiltedMacLiveSyncTransportFactory(configuration: liveConfiguration)
        }
#endif
        syncLifecycle = configuredStore.map {
            WiltedMacSyncLifecycle(
                store: $0,
                transportFactory: usesFixtureMode ? nil : selectedSyncFactory,
                assetResolver: assetResolver
            )
        }

        if usesFixtureMode {
            installFixture(ready: arguments.contains("--wilted-ui-fixture-ready"))
            if arguments.contains("--wilted-ui-fixture-quarantined") {
                syncLifecycle?.quarantineAccount()
            }
        } else {
            refresh()
        }
#else
        _ = arguments
#endif
    }

    var syncStatus: WiltedMacSyncStatus {
#if canImport(WiltedProducer)
        syncLifecycle?.status ?? .disabled
#else
        .disabled
#endif
    }

    /// Starts the explicit manual refresh action.
    func refreshSync() {
#if canImport(WiltedProducer)
        syncLifecycle?.startRefresh()
#endif
    }

    /// Starts the explicit manual upload action.
    func uploadPendingSync() {
#if canImport(WiltedProducer)
        syncLifecycle?.startUpload()
#endif
    }

    /// Cancels the current bounded sync action.
    func cancelSync() {
#if canImport(WiltedProducer)
        syncLifecycle?.cancel()
#endif
    }

    /// Quarantines sync after an account-owner change.
    func quarantineSyncAccount() {
#if canImport(WiltedProducer)
        syncLifecycle?.quarantineAccount()
#endif
    }

    /// Clears the explicit account quarantine after review.
    func resetSyncAccount() {
#if canImport(WiltedProducer)
        syncLifecycle?.resetAfterAccountChange()
#endif
    }

    var currentArticle: WiltedMacArticle? {
        guard let selectedArticleID else { return nil }
        return articles.first(where: { $0.id == selectedArticleID })
    }

    var canCancelPreparation: Bool { preparation?.cancellable == true }

    func addArticle() {
        guard let url = URL(string: urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "Enter a complete HTTPS article URL.", fraction: nil, cancellable: false
            )
            return
        }
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "Enter a complete HTTPS article URL.", fraction: nil, cancellable: false
            )
            return
        }
        guard let preparedItemID = try? ItemID.derive(from: url) else { return }

        if fixtureMode {
            preparation = WiltedMacPreparation(
                phase: .preparing, detail: "Validating article URL", fraction: 0, cancellable: true
            )
            return
        }

#if canImport(WiltedProducer)
        guard let coordinator else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "The local library is unavailable.", fraction: nil, cancellable: false
            )
            return
        }
        preparationTask?.cancel()
        preparation = WiltedMacPreparation(
            phase: .preparing, detail: "Validating article URL", fraction: 0, cancellable: true
        )
        preparationTask = Task { [weak self] in
            let run = await coordinator.start(url: url)
            guard let self else { await run.cancel(); return }
            self.preparationRun = run
            for await status in run.statuses {
                guard !Task.isCancelled else { await run.cancel(); return }
                self.update(status)
                if status.terminal { break }
            }
            if self.preparation?.phase == .completed {
                await self.queuePreparedPublication(itemID: preparedItemID)
            }
            self.preparationRun = nil
            self.refresh()
        }
#endif
    }

    func cancelPreparation() {
        guard canCancelPreparation else { return }
        preparation = WiltedMacPreparation(
            phase: .cancelling, detail: "The current work will stop without replacing saved audio.",
            fraction: preparation?.fraction, cancellable: false
        )
        if fixtureMode { return }
#if canImport(WiltedProducer)
        let run = preparationRun
        Task { await run?.cancel() }
#endif
    }

    func openNowPlaying(for article: WiltedMacArticle) {
        selectedArticleID = article.id
        isNowPlaying = true
        playbackError = nil
#if canImport(WiltedProducer)
        guard let playback else { return }
        guard let fixtureRevision else {
            if fixtureMode { return }
            Task { [weak self] in
                guard let self, let store = self.store,
                      let itemID = try? ItemID(rawValue: article.id),
                      let revision = try? await store.readyRevision(for: itemID) else { return }
                do {
                    try await playback.load(revision)
                    self.isPlaying = playback.isPlaying
                } catch { self.playbackError = "Audio could not be loaded." }
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.load(fixtureRevision)
                self.isPlaying = playback.isPlaying
            } catch { self.playbackError = "Audio could not be loaded." }
        }
#endif
    }

    func togglePlayback() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.toggle()
                self.isPlaying = playback.isPlaying
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.playbackError = "Playback is unavailable." }
        }
#else
        isPlaying.toggle()
#endif
    }

    func rewind() { seek(by: -15) }
    func forward() { seek(by: 30) }

    /// Starts a new playback session and publishes its durable checkpoint.
    func restartPlayback() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.restart()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.playbackError = "Playback restart is unavailable." }
        }
#endif
    }

    func recoverAudioRoute() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await playback.recoverFromRouteChange() }
            catch { self.playbackError = "Audio route recovery failed." }
        }
#endif
    }

    func checkpointForQuit() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await playback.handlePauseOrQuit()
            await self.queueCurrentPlaybackCheckpoint()
        }
#endif
    }

#if canImport(WiltedProducer)
    private func update(_ status: PreparationStatus) {
        let phase: WiltedMacPreparation.Phase
        switch status.stage {
        case .preparing: phase = .preparing
        case .fetching: phase = .preparing
        case .extracting: phase = .extracting
        case .synthesizing: phase = .synthesizing
        case .assembling: phase = .assembling
        case .saving: phase = .saving
        case .completed: phase = .completed
        case .cancelled: phase = .cancelled
        case .failed: phase = .failed
        }
        preparation = WiltedMacPreparation(
            phase: phase, detail: status.detail, fraction: status.fraction, cancellable: status.cancellable
        )
    }

    private func queuePreparedPublication(itemID: ItemID) async {
        guard let store, let syncLifecycle,
              let article = try? await store.article(for: itemID),
              let stored = try? await store.readyRevision(for: itemID),
              let asset = try? WiltedAsset(assetID: stored.revision.revisionID.rawValue,
                                           contentHash: stored.revision.contentHash) else { return }
        _ = await syncLifecycle.queueItem(article, currentRevisionID: stored.revision.revisionID)
        _ = await syncLifecycle.queueRevision(stored.revision, audioAsset: asset)
    }

    private func queueCurrentPlaybackCheckpoint() async {
        guard let store, let syncLifecycle, let playbackItemID = playback?.itemID,
              let playbackRevisionID = playback?.revisionID,
              let state = try? await store.playbackState(for: playbackItemID, revisionID: playbackRevisionID) else { return }
        let sidecar = try? await store.playbackSidecar(for: playbackItemID, revisionID: playbackRevisionID)
        let opaque = sidecar.map {
            WiltedOpaqueSidecar(changeTag: $0.changeTag, encodedSystemFields: $0.encodedSystemFields)
        }
        _ = await syncLifecycle.queuePlayback(state, sidecar: opaque)
    }

    private func refresh() {
        guard let store else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let stored = try? await store.articles() else { return }
            var values: [WiltedMacArticle] = []
            for article in stored where !article.isDeleted {
                let revision = try? await store.readyRevision(for: article.itemID)
                values.append(WiltedMacArticle(
                    id: article.itemID.rawValue, title: article.title, source: article.source,
                    url: article.canonicalURL, isReady: revision != nil
                ))
            }
            self.articles = values
        }
    }

    private func installFixture(ready: Bool) {
        guard ready, let store else { return }
        let url = URL(string: "https://example.test/wilted-fixture")!
        guard let itemID = try? ItemID.derive(from: url),
              let article = try? Article(
                itemID: itemID, canonicalURL: url, title: "Fixture article", source: "Example source",
                createdAt: Timestamp(Date())
              ),
              let revisionID = try? RevisionID(rawValue: "fixture-revision"),
              let revision = try? AudioRevision(
                itemID: itemID, revisionID: revisionID, durationSeconds: 120, byteCount: 1,
                contentHash: "sha256:\(String(repeating: "0", count: 64))", mediaType: "audio/mp4",
                createdAt: Timestamp(Date()), schemaVersion: 1
              ) else { return }
        let mediaURL = URL(fileURLWithPath: "/tmp/wilted-fixture.m4a")
        fixtureRevision = StoredAudioRevision(revision: revision, mediaURL: mediaURL)
        articles = [WiltedMacArticle(
            id: itemID.rawValue, title: article.title, source: article.source,
            url: article.canonicalURL, isReady: true
        )]
        Task {
            try? await store.save(article: article)
            try? await store.saveReadyRevision(revision, mediaURL: mediaURL)
        }
    }

    private func seek(by seconds: TimeInterval) {
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(by: seconds)
                self.isPlaying = playback.isPlaying
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.playbackError = "Playback is unavailable." }
        }
    }

    private static func stateDirectory(fixtureMode: Bool) -> URL {
        if fixtureMode {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "wilted-ui-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true
                )
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Wilted", isDirectory: true)
    }
#endif
}

#if canImport(WiltedProducer)
@MainActor
private final class WiltedFixturePlaybackBackend: PlaybackBackend {
    var duration: TimeInterval = 120
    var currentTime: TimeInterval = 0
    var isPlaying = false
    func load(url: URL) throws { _ = url }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}
#endif
