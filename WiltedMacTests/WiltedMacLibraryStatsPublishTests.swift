import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

private struct EmptyStateSource: LibraryStateSource {
    func currentState() async throws -> LibraryStateSnapshot { LibraryStateSnapshot() }
}

private struct DiscardingSink: LibraryIntentSink {
    func receive(_ intent: LibraryIntent) async throws {}
}

private actor StatsBox {
    var value: LifetimeStatistics?
    func set(_ value: LifetimeStatistics?) { self.value = value }
}

final class WiltedMacLibraryStatsPublishTests: XCTestCase {
    private func makePublisher(
        server: InMemoryLibraryServer, box: StatsBox?, transport: (any LibraryTransport)? = nil
    ) -> WiltedMacLibraryPublisher {
        let stamps = LockedCounter()
        var provider: (@Sendable () async -> LifetimeStatistics?)?
        if let box { provider = { await box.value } }
        return WiltedMacLibraryPublisher(
            source: EmptyStateSource(), transport: transport ?? InMemoryLibraryTransport(deviceID: "mac", server: server),
            sink: DiscardingSink(), isEnabled: true,
            statsProvider: provider,
            clock: { Date(timeIntervalSince1970: TimeInterval(100 + stamps.next())) }
        )
    }

    func testFirstPassPublishesTheMappedStatsAndUnchangedValuesAreNotRepublished() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let box = StatsBox()
        await box.set(LifetimeStatistics(audioProcessedSeconds: 60, speechGeneratedSeconds: 5))
        let pub = makePublisher(server: server, box: box)
        let first = try await pub.sync()
        XCTAssertTrue(first.statsPublished)
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        let published = try await phone.readStats()
        XCTAssertEqual(published?.audioProcessedSeconds, 60)
        XCTAssertEqual(published?.speechGeneratedSeconds, 5)
        let firstStamp = published?.updatedAt
        XCTAssertNotNil(firstStamp)

        let unchanged = try await pub.sync()
        XCTAssertFalse(unchanged.statsPublished)
        let stillFirst = try await phone.readStats()
        XCTAssertEqual(stillFirst?.updatedAt, firstStamp, "a restamp alone does not write")

        await box.set(LifetimeStatistics(audioProcessedSeconds: 90, speechGeneratedSeconds: 5))
        let changed = try await pub.sync()
        XCTAssertTrue(changed.statsPublished)
        let updated = try await phone.readStats()
        XCTAssertEqual(updated?.audioProcessedSeconds, 90)
    }

    func testPublishedStatsAdvertiseSubscribeAndAddArticle() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let box = StatsBox()
        await box.set(LifetimeStatistics(audioProcessedSeconds: 1))
        _ = try await makePublisher(server: server, box: box).sync()
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        let published = try await phone.readStats()
        let actions = try XCTUnwrap(published?.supportedIntentActions)
        XCTAssertTrue(actions.contains("subscribe"))
        XCTAssertTrue(actions.contains("addArticle"))
    }

    func testNoProviderOrNoValuePublishesNothing() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        _ = try await makePublisher(server: server, box: nil).sync()
        let none = try await makePublisher(server: server, box: StatsBox()).sync()
        XCTAssertFalse(none.statsPublished)
        let seen = try await phone.readStats()
        XCTAssertNil(seen)
    }

    func testAStatsFailureIsCountedRetriedAndDoesNotFailThePass() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let box = StatsBox()
        await box.set(LifetimeStatistics(audioProcessedSeconds: 1))
        // A transport without statistics support throws from publishStats.
        let unsupported = StatsUnsupportedTransport(base: InMemoryLibraryTransport(deviceID: "mac", server: server))
        let pub = makePublisher(server: server, box: box, transport: unsupported)
        let report = try await pub.sync()
        XCTAssertEqual(report.statsFailures, 1)
        XCTAssertFalse(report.statsPublished)
        let again = try await pub.sync()
        XCTAssertEqual(again.statsFailures, 1, "not marked published, so it is retried")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Forwards state operations but keeps the protocol-extension `publishStats` default (throws).
private struct StatsUnsupportedTransport: LibraryTransport {
    let base: InMemoryLibraryTransport
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await base.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await base.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await base.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await base.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await base.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await base.fetchDeviceRecords() }
}
