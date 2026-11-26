import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedMac

extension WiltedMacAdFeedbackActionTests {
    func testHandledBatchLimitAcceptsTwoHundredAndRejectsTwoHundredOne() async throws {
        for count in [200, 201] {
            let root = wiltedTemporaryDirectory("handled-batch-\(count)")
            let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
            let actions = root.appendingPathComponent("actions", isDirectory: true)
            try makePrivateDirectory(actions)
            let entries = try (0..<count).map { index in
                try feedback(id: "batch-\(index)", kind: .adHere, played: 25, timeline: timeline())
            }
            let legacyStore = try WiltedMacAdFeedbackInbox.encoder.encode(
                VersionOneStore(version: 1, entries: entries))
            try legacyStore.write(to: store, options: .atomic)
            let inbox = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
            let (_, requestURL) = try writeRequest(payload: payload(entries), to: actions)

            let processed = await inbox.processPendingHandledActions(at: now)
            if count == 200 {
                XCTAssertNil(processed.failure)
                XCTAssertEqual(processed.receipts.map(\.outcome), [.applied])
                let saved = await inbox.all()
                XCTAssertEqual(saved.count, count)
                XCTAssertTrue(saved.allSatisfy { $0.handledAt == now })
                XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))
            } else {
                XCTAssertNotNil(processed.failure)
                XCTAssertTrue(processed.receipts.isEmpty)
                let unchanged = await inbox.all()
                XCTAssertEqual(unchanged.count, count)
                XCTAssertTrue(unchanged.allSatisfy { $0.handledAt == nil })
                XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.appendingPathExtension("invalid").path))
            }
        }
    }

    func testRollbackKeepsFeedbackAndReceiptsReadableAcrossRepeatedPriorVersionLoads() async throws {
        let root = wiltedTemporaryDirectory("handled-repeated-rollback")
        let store = root.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let actions = root.appendingPathComponent("actions", isDirectory: true)
        try makePrivateDirectory(actions)
        let original = try feedback(id: "handled-before-rollback", kind: .adHere, played: 25, timeline: timeline())
        let firstApp = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        try await firstApp.add(original)
        try writeRequest(payload: payload([original]), to: actions)
        let handled = await firstApp.processPendingHandledActions(at: now)
        XCTAssertEqual(handled.receipts.map(\.outcome), [.applied])
        let v2Bytes = try Data(contentsOf: store)

        // The first prior-version launch preserves the unsupported receipt store.
        let archive = store.appendingPathExtension("unreadable")
        try FileManager.default.moveItem(at: store, to: archive)

        // Two more prior-version launches read and rewrite only their v1 entries.
        for index in 1...2 {
            var entries: [WiltedMacAdFeedbackEntry]
            if FileManager.default.fileExists(atPath: store.path) {
                entries = try WiltedMacAdFeedbackInbox.decoder.decode(
                    VersionOneStore.self, from: Data(contentsOf: store)).entries
            } else {
                entries = []
            }
            entries.append(try feedback(
                id: "written-by-prior-version-\(index)", kind: .adHere,
                played: 25 + Double(index), timeline: timeline()))
            let priorVersionBytes = try WiltedMacAdFeedbackInbox.encoder.encode(
                VersionOneStore(version: 1, entries: entries))
            try priorVersionBytes.write(to: store, options: .atomic)
        }

        let upgraded = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        let recovered = await upgraded.all()
        XCTAssertEqual(Set(recovered.map(\.id)), Set([
            "handled-before-rollback", "written-by-prior-version-1", "written-by-prior-version-2"
        ]))
        XCTAssertEqual(recovered.first(where: { $0.id == original.id })?.handledAt, now)
        XCTAssertTrue(recovered.filter { $0.id != original.id }.allSatisfy { $0.handledAt == nil })

        // A normal v2 write commits the in-memory fusion; reopening verifies the receipt and
        // feedback survive after another prior-version round trip.
        try await upgraded.add(try feedback(
            id: "written-after-upgrade", kind: .adHere, played: 29, timeline: timeline()))
        let reopened = WiltedMacAdFeedbackInbox(fileURL: store, actionDirectory: actions)
        let reopenedEntries = await reopened.all()
        XCTAssertEqual(Set(reopenedEntries.map(\.id)), Set([
            "handled-before-rollback", "written-by-prior-version-1", "written-by-prior-version-2",
            "written-after-upgrade"
        ]))
        XCTAssertEqual(reopenedEntries.first(where: { $0.id == original.id })?.handledAt, now)
        let fused = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any])
        XCTAssertEqual(fused["version"] as? Int, 2)
        XCTAssertEqual((fused["entries"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((fused["handledActions"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try Data(contentsOf: archive), v2Bytes)
    }

    func testHostedTestURLDoesNotDrainOwnerSpool() async throws {
        XCTAssertTrue(WiltedMacModel.hostsTests, "this regression test requires XCTest's app host")
        let model = try hostedLaunchModel("url")
        let inbox = model.adFeedback.inbox
        let stateDirectory = model.libraryURL.deletingLastPathComponent()
        let actions = stateDirectory
            .appendingPathComponent("ad-feedback-actions", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        try makePrivateDirectory(actions)
        let entry = try feedback(id: "hosted-url", kind: .adHere, played: 25, timeline: timeline())
        try await inbox.add(entry)
        let (_, requestURL) = try writeRequest(payload: payload([entry]), to: actions)

        await WiltedMacApp.handleOpenURL(URL(string: "wilted://ad-feedback/process")!, model: model)

        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        let unchanged = await inbox.all()
        XCTAssertNil(unchanged.first?.handledAt)
    }

    func testHostedTestCompositionUsesDisposableStore() async throws {
        XCTAssertTrue(WiltedMacModel.hostsTests, "this regression test requires XCTest's app host")
        let model = WiltedMacApp.makeLaunchModel(
            arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let stateDirectory = model.libraryURL.deletingLastPathComponent().standardizedFileURL
        XCTAssertFalse(model.fixtureMode)
        let expectedLibrary = WiltedMacModel.testHostStateDirectory.appendingPathComponent("library.sqlite")
        XCTAssertEqual(model.libraryURL.path, expectedLibrary.path)
        let testRoot = ProcessInfo.processInfo.environment["WILTED_TEST_TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        XCTAssertTrue(isInside(stateDirectory, testRoot))

        let ownerBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let ownerDirectory = ownerBase.appendingPathComponent("Wilted", isDirectory: true).standardizedFileURL
        XCTAssertFalse(stateDirectory.path == ownerDirectory.path
                       || stateDirectory.path.hasPrefix(ownerDirectory.path + "/"))

        let entry = try feedback(id: "hosted-composition", kind: .adHere, played: 25, timeline: timeline())
        let saved = await model.adFeedback.file(entry)
        XCTAssertTrue(saved)
        let actions = stateDirectory
            .appendingPathComponent("ad-feedback-actions", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        try makePrivateDirectory(actions)
        let (_, requestURL) = try writeRequest(payload: payload([entry]), to: actions)

        await model.adFeedback.processPendingHandledActions()

        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDirectory
            .appendingPathComponent(WiltedMacAdFeedbackInbox.fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        let stored = await model.adFeedback.inbox.all()
        XCTAssertNil(stored.first(where: { $0.id == entry.id })?.handledAt)
    }

    private func hostedLaunchModel(_ name: String) throws -> WiltedMacModel {
        let stateDirectory = WiltedMacModel.testHostStateDirectory
            .appendingPathComponent("handled-\(name)-\(UUID().uuidString)", isDirectory: true)
        try makePrivateDirectory(stateDirectory)
        return WiltedMacApp.makeLaunchModel(
            arguments: ["--wilted-ui-fixture-state-directory", stateDirectory.path],
            preferences: WiltedMacTestPreferences.ephemeral())
    }

    private func isInside(_ candidate: URL, _ parent: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == parentPath || candidatePath.hasPrefix(parentPath + "/")
    }
}
