import Foundation
import Darwin

#if canImport(WiltedProducer)
import WiltedProducer
#endif

/// A fixture directory this process created and may therefore remove.
///
/// Overrides are deliberately excluded: a caller can share one across model
/// instances to simulate a relaunch, and production state is never temporary.
final class WiltedMacTemporaryState {
    typealias OwnerMarkerWriter = (URL) throws -> Void

    fileprivate struct FixtureDirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private static let ownershipFile = ".wilted-fixture-owner"
    private static let testRootFile = ".wilted-model-test-root"
    // A marked XCTest root owns its models until awaited teardown. A fixture
    // writer can retain only its store, so weak model references cannot drain
    // that writer after a test drops its last local model reference.
    @MainActor private static var modelsByTestRoot: [String: [WiltedMacModel]] = [:]
    let directory: URL
    /// Present only when the fixture factory created this exact directory.
    /// The marker remains the recovery proof for a later process; this identity
    /// permits this live instance to close an otherwise unmarked root safely.
    private let createdDirectoryIdentity: FixtureDirectoryIdentity?
    private(set) var ownerMarkerWriteError: Error? = nil
    private var isClosed = false

    fileprivate init(
        directory: URL,
        createdDirectoryIdentity: FixtureDirectoryIdentity?,
        markerWriter: OwnerMarkerWriter = WiltedMacTemporaryState.writeOwnerMarker
    ) {
        self.directory = directory
        self.createdDirectoryIdentity = createdDirectoryIdentity
        guard createdDirectoryIdentity != nil else { return }
        do {
            try markerWriter(directory)
        } catch {
            ownerMarkerWriteError = error
        }
    }

    static func writeOwnerMarker(at directory: URL) throws {
        let owner = "pid=\(ProcessInfo.processInfo.processIdentifier)\n"
        try Data(owner.utf8).write(to: directory.appendingPathComponent(ownershipFile))
    }

    func closeSynchronously(fileManager: FileManager = .default) {
        guard !isClosed else { return }
        isClosed = true
        // This check binds cleanup to the factory's exact live directory. The
        // owner marker remains required for stale-process sweeping below.
        guard let createdDirectoryIdentity,
              Self.matchesCreatedFixtureDirectory(
                  directory, identity: createdDirectoryIdentity, fileManager: fileManager
              )
        else { return }
        try? fileManager.removeItem(at: directory)
    }

    private static func matchesCreatedFixtureDirectory(
        _ directory: URL,
        identity: FixtureDirectoryIdentity,
        fileManager: FileManager
    ) -> Bool {
        guard directory.lastPathComponent.hasPrefix("wilted-ui-fixture-"),
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              directoryIdentity(at: directory) == identity
        else { return false }
        return true
    }

    fileprivate static func directoryIdentity(at directory: URL) -> FixtureDirectoryIdentity? {
        directory.withUnsafeFileSystemRepresentation { path -> FixtureDirectoryIdentity? in
            guard let path else { return nil }
            var metadata = stat()
            guard lstat(path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR
            else { return nil }
            return FixtureDirectoryIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
        }
    }

    fileprivate static func createFixtureDirectory(at directory: URL) -> FixtureDirectoryIdentity? {
        guard directory.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            return mkdir(path, mode_t(S_IRWXU)) == 0
        }) else { return nil }
        return directoryIdentity(at: directory)
    }

    static func isOwnedFixtureDirectory(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        guard directory.lastPathComponent.hasPrefix("wilted-ui-fixture-"),
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              let data = try? Data(contentsOf: directory.appendingPathComponent(ownershipFile)),
              String(data: data, encoding: .utf8)?.hasPrefix("pid=") == true
        else { return false }
        return true
    }

    static func ownerIsLive(_ directory: URL) -> Bool? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(ownershipFile)),
              let value = String(data: data, encoding: .utf8)?.split(separator: "=").last,
              let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        if kill(pid, 0) == 0 { return true }
        return errno == ESRCH ? false : nil
    }

    static func markTestRoot(_ directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("owned-by-xctest\n".utf8).write(to: directory.appendingPathComponent(testRootFile))
    }

    static func isMarkedTestRoot(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: directory.appendingPathComponent(testRootFile).path)
    }

    static func markedTestRoot(containing directory: URL) -> URL? {
        let candidate = directory.standardizedFileURL
        if isMarkedTestRoot(candidate) { return candidate }
        let parent = candidate.deletingLastPathComponent()
        return isMarkedTestRoot(parent) ? parent : nil
    }

    @MainActor static func register(_ model: WiltedMacModel, forTestRoot root: URL) {
        let key = root.standardizedFileURL.path
        var models = modelsByTestRoot[key] ?? []
        if !models.contains(where: { $0 === model }) { models.append(model) }
        modelsByTestRoot[key] = models
    }

    /// XCTest calls this before removing its marked root. It deliberately
    /// releases the root's ownership only after awaiting its finite writers.
    @MainActor static func closeRegisteredModels(forTestRoot root: URL) async {
        let key = root.standardizedFileURL.path
        let models = modelsByTestRoot.removeValue(forKey: key) ?? []
        for model in models {
            await model.close()
        }
    }

    @MainActor static func unregister(_ model: WiltedMacModel, forTestRoot root: URL) {
        let key = root.standardizedFileURL.path
        guard var models = modelsByTestRoot[key] else { return }
        models.removeAll { $0 === model }
        if models.isEmpty { modelsByTestRoot[key] = nil }
        else { modelsByTestRoot[key] = models }
    }
}

#if canImport(WiltedProducer)
/// Settles work captured before a model deinitializes without retaining the
/// model itself. A fixture writer can retain its store after the model goes
/// away, so its owned directory must outlive that writer.
@MainActor
func closeOwnedTemporaryStateAfterDeinit(
    _ temporaryState: WiltedMacTemporaryState?,
    voidTasks: [Task<Void, Never>],
    downloadTasks: [Task<PodcastDownloadResult, Error>],
    automation: WiltedAutomationCoordinator?,
    syncLifecycle: WiltedMacSyncLifecycle?
) async {
    for task in voidTasks {
        await task.value
    }
    for task in downloadTasks {
        _ = try? await task.value
    }
    await automation?.cancel()
    await syncLifecycle?.close()
    temporaryState?.closeSynchronously()
}
#endif

extension WiltedMacModel {
#if canImport(WiltedProducer)
    static func makeOwnedFixtureState(
        in root: URL = FileManager.default.temporaryDirectory,
        markerWriter: @escaping WiltedMacTemporaryState.OwnerMarkerWriter = WiltedMacTemporaryState.writeOwnerMarker
    ) -> WiltedMacTemporaryState {
        sweepStaleFixtureDirectories(in: root)
        let directory = root.appendingPathComponent(
            "wilted-ui-fixture-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
        return makeOwnedFixtureState(at: directory, markerWriter: markerWriter)
    }

    static func makeOwnedFixtureState(
        at directory: URL,
        markerWriter: @escaping WiltedMacTemporaryState.OwnerMarkerWriter = WiltedMacTemporaryState.writeOwnerMarker
    ) -> WiltedMacTemporaryState {
        let createdDirectoryIdentity = WiltedMacTemporaryState.createFixtureDirectory(at: directory)
        return WiltedMacTemporaryState(
            directory: directory,
            createdDirectoryIdentity: createdDirectoryIdentity,
            markerWriter: markerWriter
        )
    }

    /// Explicit teardown is the correctness path. It settles all finite work
    /// before removing only a root this fixture created itself.
    func close() async {
        if let temporaryStateCloseTask {
            await temporaryStateCloseTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.finishClosingTemporaryState()
        }
        temporaryStateCloseTask = task
        await task.value
    }

    private func finishClosingTemporaryState() async {
        isClosingTemporaryState = true
        cancelPendingTemporaryStateWork()
        await waitForPendingTemporaryStateWork()
        if let registeredTestRoot {
            WiltedMacTemporaryState.unregister(self, forTestRoot: registeredTestRoot)
        }
        temporaryState?.closeSynchronously()
        temporaryStateCloseTask = nil
    }

    func cancelPendingTemporaryStateWork() {
        startupTask?.cancel()
        preparationTask?.cancel()
        syncReconciliationTask?.cancel()
        podcastRefreshTask?.cancel()
        bootstrapRecoveryTask?.cancel()
        linkClassificationTask?.cancel()
        podcastSubscriptionClassificationTask?.cancel()
        fixturePodcastInstallTask?.cancel()
        fixtureInstallTask?.cancel()
        playbackOperationTask?.cancel()
        menuAdditionTask?.cancel()
        for task in podcastDownloadTasks.values { task.cancel() }
        for task in podcastPreparationTasks.values { task.cancel() }
        for task in podcastRestoreTasks.values { task.cancel() }
        for task in subscriptionWriteTasks.values { task.cancel() }
        cancelAutomationForTemporaryState()
        syncLifecycle?.cancel()
    }

    func waitForPendingTemporaryStateWork() async {
        let startup = startupTask
        await startup?.value
        // Startup can schedule a recovery or refresh after its first await.
        // Drain two post-start snapshots so that child work cannot outlive a
        // root merely because it appeared after the original cancellation.
        for _ in 0..<2 {
            let preparation = preparationTask
            let reconciliation = syncReconciliationTask
            let refresh = podcastRefreshTask
            let recovery = bootstrapRecoveryTask
            let classification = linkClassificationTask
            let subscriptionClassification = podcastSubscriptionClassificationTask
            let fixtureInstall = fixturePodcastInstallTask
            let articleFixtureInstall = fixtureInstallTask
            let playbackOperation = playbackOperationTask
            let menuAddition = menuAdditionTask
            let downloads = Array(podcastDownloadTasks.values)
            let preparations = Array(podcastPreparationTasks.values)
            let restores = Array(podcastRestoreTasks.values)
            let subscriptionWrites = Array(subscriptionWriteTasks.values)
            await preparation?.value
            await reconciliation?.value
            await refresh?.value
            await recovery?.value
            await classification?.value
            await subscriptionClassification?.value
            await fixtureInstall?.value
            await articleFixtureInstall?.value
            await playbackOperation?.value
            await menuAddition?.value
            for task in downloads { _ = try? await task.value }
            for task in preparations { await task.value }
            for task in restores { await task.value }
            for task in subscriptionWrites { await task.value }
        }
        await waitForAutomationForTemporaryState()
        await syncLifecycle?.close()
    }
#endif
}
