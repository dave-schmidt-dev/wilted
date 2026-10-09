import Foundation
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacOwnedFixtureLifetimeTests: XCTestCase {
    private let arguments = ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"]

    private func fixture() -> WiltedMacModel {
        WiltedMacModel(arguments: arguments, preferences: WiltedMacTestPreferences.ephemeral())
    }

    private func settle(_ model: WiltedMacModel) async {
        await model.fixtureInstallTask?.value
        await model.fixturePodcastInstallTask?.value
        await model.waitForLifetimeStatisticsForTesting()
    }

    func testDefaultFixtureBindsRunnerRootAndCloseRetainsRealDatabase() async throws {
        let model = fixture(); await settle(model)
        let root = model.libraryURL.deletingLastPathComponent()
        let parent = try WiltedMacTestRootOwnership.parent(rawValue: ProcessInfo.processInfo.environment["WILTED_TEST_TMPDIR"])
        XCTAssertEqual(root.deletingLastPathComponent(), parent)
        XCTAssertTrue(try WiltedMacTestRootOwnership.isManaged(root))
        let store = try XCTUnwrap(model.store); let before = try await store.inspect()
        await model.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.libraryURL.path))
        if FileManager.default.fileExists(atPath: model.libraryURL.path) {
            let after = try await store.inspect(); XCTAssertEqual(after, before)
        }
    }

    func testDefaultFixtureDeinitRetainsDatabaseWhileLifecycleAndStoreRemainLive() async throws {
        var model: WiltedMacModel? = fixture(); await settle(try XCTUnwrap(model))
        let store = try XCTUnwrap(model?.store); let lifecycle = try XCTUnwrap(model?.syncLifecycle)
        let state = try XCTUnwrap(model?.temporaryState); let before = try await store.inspect(); let database = await store.url
        let tasks = [model?.fixtureInstallTask, model?.fixturePodcastInstallTask, model?.statisticsTask].compactMap { $0 }
        weak var observedModel = model; model = nil
        await closeOwnedTemporaryStateAfterDeinit(state, voidTasks: tasks, downloadTasks: [],
            automation: nil, syncLifecycle: lifecycle)
        XCTAssertNil(observedModel)
        XCTAssertTrue(try WiltedMacTestRootOwnership.isManaged(state.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        if FileManager.default.fileExists(atPath: database.path) {
            let after = try await store.inspect(); XCTAssertEqual(after, before)
        }
    }

    func testUnmanagedOwnedDatabaseRetiresWithoutUnlinkingRetainedStore() async throws {
        let state = WiltedMacModel.makeOwnedFixtureState(in: wiltedTemporaryDirectory("unmanaged-database"))
        let store = try LocalLibraryStore(url: state.directory.appendingPathComponent("library.sqlite"))
        let before = try await store.inspect(); let database = await store.url
        XCTAssertFalse(try WiltedMacTestRootOwnership.isManaged(state.directory))
        state.closeSynchronously()
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        XCTAssertEqual(WiltedMacTemporaryState.ownerIsLive(state.directory), true)
        if FileManager.default.fileExists(atPath: database.path) {
            let after = try await store.inspect(); XCTAssertEqual(after, before)
        }
    }
    func testStaleSweepRetainsLiveRetiredRootAndRemovesOnlyOldDeadOwner() async throws {
        let parent = wiltedTemporaryDirectory("retired-owner-sweep")
        let live = WiltedMacModel.makeOwnedFixtureState(in: parent)
        let store = try LocalLibraryStore(url: live.directory.appendingPathComponent("library.sqlite"))
        _ = try await store.inspect(); live.closeSynchronously()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0"]; try process.run(); process.waitUntilExit()
        let dead = WiltedMacModel.makeOwnedFixtureState(in: parent) { directory in
            try "pid=\(process.processIdentifier)\n".write(
                to: directory.appendingPathComponent(".wilted-fixture-owner"), atomically: true, encoding: .utf8)
        }
        try Data([1]).write(to: dead.directory.appendingPathComponent("retired-media"))
        for root in [live.directory, dead.directory] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172_800)], ofItemAtPath: root.path)
        }
        XCTAssertEqual(WiltedMacTemporaryState.ownerIsLive(dead.directory), false)
        WiltedMacModel.sweepStaleFixtureDirectories(in: parent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.directory.path))
        _ = try await store.inspect()
    }

}
