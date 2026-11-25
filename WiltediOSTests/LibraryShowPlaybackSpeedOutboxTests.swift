import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltediOS

@MainActor
final class LibraryShowPlaybackSpeedOutboxTests: XCTestCase {
    private struct Rig {
        let model: LibraryAppModel
        let mac: InMemoryLibraryTransport
        let phone: LibraryTransport
        let feed: ItemID
        let outboxURL: URL
    }

    func testAppliedOutcomeStaysEffectiveAcrossMissingAndStaleStatsThenResetRefreshes() async throws {
        let directory = try makeDirectory("show-speed-outcome")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = try await makeRig(directory: directory, initialSpeed: nil)
        XCTAssertEqual(rig.model.macSupportsShowPlaybackSpeeds, true)
        XCTAssertNil(rig.model.showPlaybackSpeed(for: rig.feed))

        await rig.model.setShowPlaybackSpeed(1.75, for: rig.feed)
        let first = try XCTUnwrap(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue])
        guard case let .setShowPlaybackSpeed(_, firstSpeed, firstRevision) = first.intent.action else {
            return XCTFail("expected a show speed command")
        }
        XCTAssertEqual(firstSpeed, 1.75)
        XCTAssertEqual(firstRevision, 0)
        rig.model.resolveShowPlaybackSpeedOutcomes([try .applied(for: first.intent, at: Date())])
        XCTAssertEqual(rig.model.showPlaybackSpeed(for: rig.feed), 1.75,
                       "an applied outcome keeps its value even while policy stats are missing")

        await refreshSpeedStats(rig)
        XCTAssertEqual(rig.model.showPlaybackSpeed(for: rig.feed), 1.75,
                       "a missing stats field cannot erase a confirmed local result")
        XCTAssertEqual(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue]?.appliedRevision, 1)

        try await publishSpeedStats(rig, speed: 1.75, revision: 1)
        await refreshSpeedStats(rig)
        XCTAssertNil(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue])
        XCTAssertEqual(rig.model.showPlaybackSpeed(for: rig.feed), 1.75)

        await rig.model.setShowPlaybackSpeed(nil, for: rig.feed)
        let reset = try XCTUnwrap(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue])
        guard case let .setShowPlaybackSpeed(_, resetSpeed, resetRevision) = reset.intent.action else {
            return XCTFail("expected a revisioned reset")
        }
        XCTAssertNil(resetSpeed)
        XCTAssertEqual(resetRevision, 1)
        rig.model.resolveShowPlaybackSpeedOutcomes([try .applied(for: reset.intent, at: Date())])
        XCTAssertNil(rig.model.showPlaybackSpeed(for: rig.feed), "the accepted reset immediately returns playback to this phone's default")

        await refreshSpeedStats(rig)
        XCTAssertNil(rig.model.showPlaybackSpeed(for: rig.feed), "stale speed stats cannot undo a confirmed reset")
        XCTAssertEqual(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue]?.appliedRevision, 2)
        try await publishSpeedStats(rig, speed: nil, revision: 2)
        await refreshSpeedStats(rig)
        XCTAssertNil(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue])
        XCTAssertNil(rig.model.showPlaybackSpeed(for: rig.feed))
    }

    func testConflictUsesMacValueAndExplicitReapplyUsesRefreshedRevision() async throws {
        let directory = try makeDirectory("show-speed-conflict")
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try LibraryShowPlaybackSpeed(feedID: try ItemID(rawValue: "feed-speed"), speed: 1.25, revision: 4)
        let rig = try await makeRig(directory: directory, initialSpeed: initial)
        await rig.model.setShowPlaybackSpeed(1.75, for: rig.feed)
        let conflictCommand = try XCTUnwrap(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue])
        rig.model.resolveShowPlaybackSpeedOutcomes([try .rejected(
            for: conflictCommand.intent, reason: LibraryAppModel.showPlaybackSpeedConflictReason, at: Date())])
        XCTAssertTrue(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue]?.conflict == true)
        XCTAssertEqual(rig.model.showPlaybackSpeed(for: rig.feed), 1.25,
                       "a conflict returns playback and the picker to Mac authority")

        try await publishSpeedStats(rig, speed: 1.5, revision: 5)
        await rig.model.reapplyShowPlaybackSpeed(for: rig.feed)
        let reapplied = try XCTUnwrap(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue])
        XCTAssertNotEqual(reapplied.intent.id, conflictCommand.intent.id)
        guard case let .setShowPlaybackSpeed(_, speed, basedOnRevision) = reapplied.intent.action else {
            return XCTFail("expected an explicit reapply command")
        }
        XCTAssertEqual(speed, 1.75)
        XCTAssertEqual(basedOnRevision, 5)
    }

    func testDelayedSpeedSendKeepsOneDurablePerFeedReservation() async throws {
        let directory = try makeDirectory("show-speed-delay")
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = OutboxSendScript(.hold)
        let rig = try await makeRig(directory: directory, initialSpeed: nil, script: script)
        let firstEdit = Task { await rig.model.setShowPlaybackSpeed(1.5, for: rig.feed) }
        let sendStarted = await waitOnClock { script.attempts.count == 1 }
        XCTAssertTrue(sendStarted)
        let first = try XCTUnwrap(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue])
        XCTAssertNotNil(first.reservedAt)
        guard case let .saved(saved) = LibraryShowPlaybackSpeedOutbox(url: rig.outboxURL).load() else {
            return XCTFail("the send reservation must be durable before transport yields")
        }
        XCTAssertEqual(saved.commands.first?.intent.id, first.intent.id)
        XCTAssertNotNil(saved.commands.first?.reservedAt)

        await rig.model.setShowPlaybackSpeed(2, for: rig.feed)
        XCTAssertEqual(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue]?.intent.id, first.intent.id)
        XCTAssertEqual(script.attempts, [first.intent.id])

        script.release()
        await firstEdit.value
        XCTAssertNotNil(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue]?.sentAt)
        XCTAssertNil(rig.model.showPlaybackSpeedCommands[rig.feed.rawValue]?.reservedAt)
    }

    private func makeRig(
        directory: URL, initialSpeed: LibraryShowPlaybackSpeed?, script: OutboxSendScript? = nil
    ) async throws -> Rig {
        let feed = try ItemID(rawValue: "feed-speed")
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        try await mac.push(changes: [PendingLibraryChange(
            localSeq: 1, change: .source(LibrarySource(id: feed, kind: .podcastFeed, title: "Speed Show")), baseVersion: 0)])
        try await mac.publishStats(LibraryStats(
            supportedIntentActions: ["setShowPlaybackSpeed"],
            showPlaybackSpeeds: initialSpeed.map { [feed.rawValue: $0] }))
        let base = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        let phone: LibraryTransport = script.map { OutboxScriptedTransport(base: base, script: $0) } ?? base
        let suite = "show-speed-outbox-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        let outboxURL = directory.appendingPathComponent("show-playback-speeds.json")
        let model = LibraryAppModel(
            transport: phone, store: FileLibraryStore(url: directory.appendingPathComponent("library.json")),
            deviceID: "phone", preferences: preferences, showPlaybackSpeedOutboxURL: outboxURL)
        await model.refresh()
        return Rig(model: model, mac: mac, phone: phone, feed: feed, outboxURL: outboxURL)
    }

    private func refreshSpeedStats(_ rig: Rig) async {
        let generation = await rig.phone.operationGeneration()
        await rig.model.refreshShowPlaybackSpeedStats(
            owner: "fixture-owner", generation: generation,
            storeIdentity: ObjectIdentifier(rig.model.store as AnyObject))
    }

    private func publishSpeedStats(_ rig: Rig, speed: Double?, revision: Int64) async throws {
        let value = try LibraryShowPlaybackSpeed(feedID: rig.feed, speed: speed, revision: revision)
        try await rig.mac.publishStats(LibraryStats(
            supportedIntentActions: ["setShowPlaybackSpeed"], showPlaybackSpeeds: [rig.feed.rawValue: value]))
    }

    private func makeDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitOnClock(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
