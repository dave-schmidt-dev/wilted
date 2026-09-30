import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class LibraryStatsTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 2_000)

    func testMapsTheFourLifetimeMetricsAndLeavesReservedFieldsNil() {
        let lifetime = LifetimeStatistics(
            audioProcessedSeconds: 10, speechGeneratedSeconds: 20,
            confirmedAdTimeRemovedSeconds: 30, fasterPlaybackTimeSavedSeconds: 40
        )
        let stats = LibraryStats(lifetime, updatedAt: stamp)
        XCTAssertEqual(stats.audioProcessedSeconds, 10)
        XCTAssertEqual(stats.speechGeneratedSeconds, 20)
        XCTAssertEqual(stats.confirmedAdTimeRemovedSeconds, 30)
        XCTAssertEqual(stats.fasterPlaybackTimeSavedSeconds, 40)
        XCTAssertNil(stats.minutesPlayed)
        XCTAssertNil(stats.gigabytesDownloaded)
        XCTAssertNil(stats.minutesSkipped)
        XCTAssertEqual(stats.updatedAt, stamp)
    }

    func testInvalidLifetimeValuesAreClampedToZero() {
        let stats = LibraryStats(LifetimeStatistics(audioProcessedSeconds: -5, speechGeneratedSeconds: .nan, confirmedAdTimeRemovedSeconds: .infinity))
        XCTAssertEqual(stats.audioProcessedSeconds, 0)
        XCTAssertEqual(stats.speechGeneratedSeconds, 0)
        XCTAssertEqual(stats.confirmedAdTimeRemovedSeconds, 0)
    }

    func testRoundTripsThroughJSONIncludingReservedFields() throws {
        let stats = LibraryStats(
            audioProcessedSeconds: 1.5, speechGeneratedSeconds: 2.5, confirmedAdTimeRemovedSeconds: 3.5,
            fasterPlaybackTimeSavedSeconds: 4.5, minutesPlayed: 6, gigabytesDownloaded: 0.25, minutesSkipped: 7, updatedAt: stamp
        )
        let data = try JSONEncoder().encode(stats)
        XCTAssertEqual(try JSONDecoder().decode(LibraryStats.self, from: data), stats)
    }

    func testAnOlderPayloadWithoutReservedFieldsStillDecodes() throws {
        let json = #"{"audioProcessedSeconds":1,"speechGeneratedSeconds":2,"confirmedAdTimeRemovedSeconds":3,"fasterPlaybackTimeSavedSeconds":4}"#
        let stats = try JSONDecoder().decode(LibraryStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats, LibraryStats(audioProcessedSeconds: 1, speechGeneratedSeconds: 2, confirmedAdTimeRemovedSeconds: 3, fasterPlaybackTimeSavedSeconds: 4))
    }

    func testAFutureFieldIsIgnoredByThisReader() throws {
        let json = #"{"audioProcessedSeconds":1,"speechGeneratedSeconds":2,"confirmedAdTimeRemovedSeconds":3,"fasterPlaybackTimeSavedSeconds":4,"someFutureMetric":9}"#
        XCTAssertEqual(try JSONDecoder().decode(LibraryStats.self, from: Data(json.utf8)).audioProcessedSeconds, 1)
    }

    func testSameMetricsIgnoresTheTimestamp() {
        let a = LibraryStats(audioProcessedSeconds: 1, updatedAt: stamp)
        XCTAssertTrue(a.hasSameMetrics(as: LibraryStats(audioProcessedSeconds: 1, updatedAt: stamp.addingTimeInterval(60))))
        XCTAssertFalse(a.hasSameMetrics(as: LibraryStats(audioProcessedSeconds: 2, updatedAt: stamp)))
    }

    func testInMemoryTransportPublishesFromTheWriterAndReadsFromAnyDevice() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        let before = try await phone.readStats()
        XCTAssertNil(before, "nothing is published yet")
        let stats = LibraryStats(audioProcessedSeconds: 9, updatedAt: stamp)
        try await mac.publishStats(stats)
        let seen = try await phone.readStats()
        XCTAssertEqual(seen, stats)
        let newer = LibraryStats(audioProcessedSeconds: 12, updatedAt: stamp.addingTimeInterval(1))
        try await mac.publishStats(newer)
        let replaced = try await phone.readStats()
        XCTAssertEqual(replaced, newer)
    }

    func testOnlyTheWriterMayPublishStats() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        do {
            try await phone.publishStats(LibraryStats())
            XCTFail("a follower must not publish statistics")
        } catch let error as LibraryTransportError {
            guard case .ownershipViolation = error else { return XCTFail("\(error)") }
        }
        let seen = try await phone.readStats()
        XCTAssertNil(seen)
    }
}
