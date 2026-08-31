import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

private enum StartupTestError: Error {
    case expectedFailure
}

private actor BootstrapGate {
    private var held = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        held = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { holdContinuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        holdContinuation?.resume()
        holdContinuation = nil
    }
}

private actor FailingBootstrap {
    private(set) var attempts = 0

    func run(at url: URL) throws -> LocalLibraryStore {
        attempts += 1
        if attempts == 1 {
            let retainedDirectory = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).v5-test", isDirectory: true)
            try FileManager.default.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
            try Data("retained-v5".utf8).write(to: retainedDirectory.appendingPathComponent(url.lastPathComponent))
        }
        throw StartupTestError.expectedFailure
    }
}

private actor SuccessfulBootstrap {
    private(set) var attempts = 0

    func run(at url: URL) throws -> LocalLibraryStore {
        attempts += 1
        return try LocalLibraryStore(url: url)
    }
}

@MainActor
final class WiltedMacModelTests: XCTestCase {
    func testLoadingIsObservableUntilBootstrapAndInitialRefreshComplete() async throws {
        let directory = temporaryDirectory("loading")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = BootstrapGate()
        let articleURL = try XCTUnwrap(URL(string: "https://example.test/migrated-article"))
        let itemID = try ItemID.derive(from: articleURL)
        let article = try Article(
            itemID: itemID,
            canonicalURL: articleURL,
            title: "Migrated article",
            source: "Example",
            createdAt: Timestamp(Date())
        )
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                await gate.hold()
                let store = try LocalLibraryStore(url: url)
                try await store.save(article: article)
                return store
            }
        )

        XCTAssertEqual(model.startupState, .loading(attempt: 0))
        XCTAssertTrue(model.articles.isEmpty)
        model.startStoreBootstrap()
        await gate.waitUntilHeld()
        XCTAssertEqual(model.startupState, .loading(attempt: 1))

        await gate.release()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.articles.map(\.title), ["Migrated article"])
    }

    func testFailureExposesRetainedV5ArtifactAndInjectedRecoveryAction() async throws {
        let directory = temporaryDirectory("failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = FailingBootstrap()
        var presentedURL: URL?
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in try await bootstrap.run(at: url) },
            retainedArtifactPresenter: { presentedURL = $0 }
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        guard case let .failed(failure) = model.startupState else {
            return XCTFail("A failed store bootstrap must not look like a ready empty larder")
        }
        let retainedURL = try XCTUnwrap(failure.retainedV5StoreURL)
        XCTAssertEqual(retainedURL.lastPathComponent, "library.sqlite")
        XCTAssertTrue(retainedURL.path.contains("library.sqlite.v5-test"))
        XCTAssertTrue(failure.canRetry)
        XCTAssertTrue(model.articles.isEmpty)

        model.presentRetainedV5Store()
        XCTAssertEqual(presentedURL, retainedURL)
    }

    func testRetryIsBoundedToOneRecoveryAttempt() async {
        let directory = temporaryDirectory("retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = FailingBootstrap()
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in try await bootstrap.run(at: url) }
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        model.retryStoreBootstrap()
        await model.waitForStoreBootstrap()

        guard case let .failed(failure) = model.startupState else {
            return XCTFail("The second failure must remain a recovery state")
        }
        XCTAssertFalse(failure.canRetry)
        model.retryStoreBootstrap()
        let attempts = await bootstrap.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testReadyModelDoesNotBootstrapAgainWhenRootTaskReappears() async {
        let directory = temporaryDirectory("ready-terminal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = SuccessfulBootstrap()
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in try await bootstrap.run(at: url) }
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let attempts = await bootstrap.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(model.startupState, .ready)
    }

    func testFixtureModeRemainsImmediatelyUsable() {
        let directory = temporaryDirectory("fixture")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: directory
        )

        XCTAssertTrue(model.fixtureMode)
        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.articles.map(\.title), ["Fixture article"])
    }

    func testStartupSurfacesHaveDistinctAccessibilityIdentifiers() {
        XCTAssertEqual(WiltedMacStartupAccessibility.loading, "wilted-mac-startup-loading")
        XCTAssertEqual(WiltedMacStartupAccessibility.recovery, "wilted-mac-startup-recovery")
        XCTAssertNotEqual(WiltedMacStartupAccessibility.loading, WiltedMacStartupAccessibility.recovery)
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-mac-model-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }
}
