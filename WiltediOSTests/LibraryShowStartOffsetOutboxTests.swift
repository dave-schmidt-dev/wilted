import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltediOS

@MainActor
final class LibraryShowStartOffsetOutboxTests: XCTestCase {
    func testVersionedOffsetCommandAndCachedMacPolicySurviveRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("show-offset-outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = try ItemID(rawValue: "feed-offset")
        let intent = try LibraryIntent.setShowStartOffset(
            feedID: feed, seconds: 90, basedOnRevision: 4, deviceID: "phone", id: "offset-command")
        let command = LibraryShowStartOffsetOutbox.Command(intent: intent, sentAt: nil)
        let offset = try LibraryShowStartOffset(feedID: feed, seconds: 45, revision: 4)
        let saved = LibraryShowStartOffsetOutbox.Saved(
            ownerToken: "sha256:owner", offsets: [feed.rawValue: offset], commands: [command])
        let outbox = LibraryShowStartOffsetOutbox(url: directory.appendingPathComponent("offsets.json"))

        try outbox.save(saved)

        guard case let .saved(restored) = outbox.load() else {
            return XCTFail("Expected the saved owner-bound offset command")
        }
        XCTAssertEqual(restored, saved)
        XCTAssertEqual(restored.commands.first?.intent.id, "offset-command")
        XCTAssertEqual(restored.commands.first?.sentAt, nil)
    }

    func testUnreadableOutboxAndExistingRecoveryCopyStayUntouched() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("show-offset-outbox-unreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("offsets.json")
        let recovery = directory.appendingPathComponent("offsets.unreadable.json")
        let damaged = Data("damaged offset state".utf8)
        let priorRecovery = Data("prior recovery copy".utf8)
        try damaged.write(to: url)
        try priorRecovery.write(to: recovery)
        let outbox = LibraryShowStartOffsetOutbox(url: url)

        XCTAssertEqual(outbox.load(), .unreadable)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        XCTAssertEqual(try Data(contentsOf: recovery), priorRecovery)
    }

    func testDelayedSendReservesFeedUntilMacAcceptsFirstEdit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("show-offset-delayed-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = try ItemID(rawValue: "feed-offset")
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        try await mac.push(changes: [PendingLibraryChange(
            localSeq: 1,
            change: .source(LibrarySource(id: feed, kind: .podcastFeed, title: "The Show")),
            baseVersion: 0
        )])
        try await mac.publishStats(LibraryStats(supportedIntentActions: ["setShowStartOffset"]))

        let script = OutboxSendScript(.hold)
        let outboxURL = directory.appendingPathComponent("show-offsets.json")
        let suite = "show-offset-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = LibraryAppModel(
            transport: OutboxScriptedTransport(
                base: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
                script: script),
            store: FileLibraryStore(url: directory.appendingPathComponent("library.json")),
            deviceID: "phone", preferences: UserDefaults(suiteName: suite)!,
            showStartOffsetOutboxURL: outboxURL)
        await model.refresh()
        XCTAssertEqual(model.macSupportsShowStartOffsets, true)

        let firstEdit = Task { await model.setShowStartOffset(90, for: feed) }
        let sendStarted = await waitOnClock { script.attempts.count == 1 }
        XCTAssertTrue(sendStarted, "the first edit reaches the delayed send")
        let pending = try XCTUnwrap(model.showStartOffsetCommands[feed.rawValue])
        XCTAssertNotNil(pending.reservedAt, "the feed is reserved before transport yields")
        guard case let .saved(savedWhileSending) = LibraryShowStartOffsetOutbox(url: outboxURL).load() else {
            return XCTFail("the in-flight reservation should be durable")
        }
        XCTAssertEqual(savedWhileSending.commands.first?.intent.id, pending.intent.id)
        XCTAssertNotNil(savedWhileSending.commands.first?.reservedAt)

        await model.setShowStartOffset(120, for: feed)
        let afterSecondEdit = try XCTUnwrap(model.showStartOffsetCommands[feed.rawValue])
        XCTAssertEqual(afterSecondEdit.intent.id, pending.intent.id)
        XCTAssertEqual(afterSecondEdit.seconds, 90)
        XCTAssertEqual(script.attempts, [pending.intent.id], "a second picker edit cannot replace or duplicate the send")

        script.release()
        await firstEdit.value
        XCTAssertNotNil(model.showStartOffsetCommands[feed.rawValue]?.sentAt)
        XCTAssertNil(model.showStartOffsetCommands[feed.rawValue]?.reservedAt)
        let accepted = try await mac.listIntents().map(\.id)
        XCTAssertEqual(accepted, [pending.intent.id])
    }

    func testRelaunchClearsDurableReservationAndRetriesSameIntentID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("show-offset-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = try ItemID(rawValue: "feed-offset")
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        try await mac.push(changes: [PendingLibraryChange(
            localSeq: 1,
            change: .source(LibrarySource(id: feed, kind: .podcastFeed, title: "The Show")),
            baseVersion: 0
        )])
        try await mac.publishStats(LibraryStats(supportedIntentActions: ["setShowStartOffset"]))

        let intent = try LibraryIntent.setShowStartOffset(
            feedID: feed, seconds: 90, basedOnRevision: 0, deviceID: "phone", id: "offset-crash-window")
        let outboxURL = directory.appendingPathComponent("show-offsets.json")
        let reservationTime = Date(timeIntervalSince1970: 1_800_000_000)
        try LibraryShowStartOffsetOutbox(url: outboxURL).save(.init(
            ownerToken: "fixture-owner",
            commands: [.init(intent: intent, sentAt: nil, reservedAt: reservationTime)]))

        let script = OutboxSendScript(.deliver)
        let suite = "show-offset-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let model = LibraryAppModel(
            transport: OutboxScriptedTransport(
                base: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
                script: script),
            store: FileLibraryStore(url: directory.appendingPathComponent("library.json")),
            deviceID: "phone", preferences: UserDefaults(suiteName: suite)!,
            showStartOffsetOutboxURL: outboxURL)
        let restored = try XCTUnwrap(model.showStartOffsetCommands[feed.rawValue])
        XCTAssertEqual(restored.intent.id, intent.id)
        XCTAssertEqual(restored.seconds, 90)
        XCTAssertNil(restored.reservedAt, "a recovered reservation is released for retry")
        guard case let .saved(recovered) = LibraryShowStartOffsetOutbox(url: outboxURL).load() else {
            return XCTFail("the recovered reservation should remain on disk")
        }
        XCTAssertNil(recovered.commands.first?.reservedAt)
        XCTAssertEqual(recovered.commands.first?.intent.id, intent.id)

        await model.refresh()
        XCTAssertEqual(script.attempts, [intent.id])
        XCTAssertNotNil(model.showStartOffsetCommands[feed.rawValue]?.sentAt)
        let accepted = try await mac.listIntents().map(\.id)
        XCTAssertEqual(accepted, [intent.id])
    }
}
