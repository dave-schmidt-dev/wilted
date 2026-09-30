import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// `HandoffPositionImport.candidates`: which other-device record speaks for an entry.
final class HandoffPositionImportTests: XCTestCase {
    private let entry = try! ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
    private let other = try! ItemID(rawValue: "item-" + String(repeating: "b", count: 64))
    private let revision = try! RevisionID(rawValue: "rev-a")

    private func observed(
        _ device: String, _ id: ItemID? = nil, position: Double, epoch: Int, at server: TimeInterval,
        playing: Bool = false, published: TimeInterval? = nil
    ) -> ObservedPlayback {
        ObservedPlayback(
            record: try! DevicePlaybackPosition(
                deviceID: device, entryID: id ?? entry, revision: revision, positionSeconds: position,
                isPlaying: playing, epoch: epoch, publishedAt: published.map { Date(timeIntervalSince1970: $0) }),
            serverModifiedAt: Date(timeIntervalSince1970: server))
    }

    private func candidates(_ progress: [ObservedPlayback], nowPlaying: [ObservedPlayback] = []) -> [ImportablePosition] {
        HandoffPositionImport.candidates(
            records: LibraryDeviceRecords(nowPlaying: nowPlaying, progress: progress), localDeviceID: "mac")
    }

    func testAPhonesPausedRecordIsACandidateAtItsPosition() throws {
        let result = candidates([observed("phone", position: 321, epoch: 2, at: 1_000)])
        let position = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(position.entryID, entry)
        XCTAssertEqual(position.revision, revision)
        XCTAssertEqual(position.positionSeconds, 321)
        XCTAssertEqual(position.sourceDeviceID, "phone")
        XCTAssertEqual(position.observedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testTheImportersOwnRecordsAreNeverCandidates() {
        XCTAssertTrue(candidates([observed("mac", position: 50, epoch: 1, at: 1_000)]).isEmpty)
    }

    func testARecordBelowTheEntrysHighestEpochIsStale() {
        // The Mac took over at epoch 5; the phone's pause from epoch 4 was published later.
        let result = candidates([
            observed("mac", position: 900, epoch: 5, at: 1_000),
            observed("phone", position: 20, epoch: 4, at: 1_005),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testTheNewestOfSeveralOtherDevicesWins() throws {
        let result = candidates([
            observed("phone-a", position: 100, epoch: 3, at: 1_000),
            observed("phone-b", position: 250, epoch: 3, at: 2_000),
            observed("phone-c", position: 999, epoch: 2, at: 3_000),
        ])
        XCTAssertEqual(try XCTUnwrap(result.first).sourceDeviceID, "phone-b")
        XCTAssertEqual(result.count, 1)
    }

    func testNowPlayingAndProgressAreBothRead() {
        let playing = observed("phone", position: 40, epoch: 2, at: 1_000, playing: true)
        XCTAssertEqual(candidates([], nowPlaying: [playing]).first?.positionSeconds, 40)
    }

    func testAPositionOfZeroIsNotAPosition() {
        XCTAssertTrue(candidates([observed("phone", position: 0, epoch: 1, at: 1_000)]).isEmpty)
    }

    func testTheServerDateIsMovedOntoTheImportersClock() throws {
        // The Mac's own record shows the server running 30 s ahead of the Mac's clock.
        let own = observed("mac", other, position: 5, epoch: 1, at: 1_030, published: 1_000)
        let result = candidates([own, observed("phone", position: 70, epoch: 1, at: 2_030)])
        XCTAssertEqual(try XCTUnwrap(result.first).observedAt, Date(timeIntervalSince1970: 2_000))
    }

    func testResultIsSortedByEntryAndOnePerEntry() {
        let result = candidates([
            observed("phone", other, position: 10, epoch: 1, at: 1_000),
            observed("phone", position: 20, epoch: 1, at: 1_001),
            observed("phone", position: 25, epoch: 1, at: 1_002),
        ])
        XCTAssertEqual(result.map(\.entryID), [entry, other])
        XCTAssertEqual(result.first?.positionSeconds, 25)
    }

    func testARealPhonePauseIsReadBackAsACandidate() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        await server.setClock(Date(timeIntervalSince1970: 5_000))
        let phone = HandoffCoordinator(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone",
            clock: { Date(timeIntervalSince1970: 5_000) }, sleep: { _ in })
        try await phone.takeover(entryID: entry, revision: revision, positionSeconds: 10)
        try await phone.paused(at: 1_234)
        let records = try await InMemoryLibraryTransport(deviceID: "mac", server: server).fetchDeviceRecords()
        let result = HandoffPositionImport.candidates(records: records, localDeviceID: "mac")
        XCTAssertEqual(result.map(\.positionSeconds), [1_234])
    }

    // MARK: - A playing phone's position moves on while nobody publishes

    private func playing(_ position: Double, saved: TimeInterval, rate: Double = 1) -> ObservedPlayback {
        ObservedPlayback(
            record: try! DevicePlaybackPosition(
                deviceID: "phone", entryID: entry, revision: revision, positionSeconds: position, rate: rate,
                isPlaying: true, epoch: 2),
            serverModifiedAt: Date(timeIntervalSince1970: saved))
    }

    private func candidate(_ record: ObservedPlayback, now: TimeInterval) -> ImportablePosition? {
        HandoffPositionImport.candidates(
            records: LibraryDeviceRecords(nowPlaying: [record], progress: []), localDeviceID: "mac",
            now: Date(timeIntervalSince1970: now)).first
    }

    func testAFreshPlayingRecordResumesAheadByTheTimeSinceItWasSaved() throws {
        let result = try XCTUnwrap(candidate(playing(600, saved: 1_000), now: 1_020))
        XCTAssertEqual(result.positionSeconds, 600)
        XCTAssertEqual(result.advanceSeconds, 20)
        XCTAssertEqual(result.resumeSeconds, 620)
        XCTAssertTrue(result.isPlaying)
        XCTAssertEqual(result.observedAt, Date(timeIntervalSince1970: 1_020), "valid as of now, so a later read is newer")
    }

    func testTheAdvanceFollowsThePlaybackRate() throws {
        XCTAssertEqual(try XCTUnwrap(candidate(playing(600, saved: 1_000, rate: 2), now: 1_020)).advanceSeconds, 40)
    }

    func testTheAdvanceIsCappedAtOneAndAHalfCadences() throws {
        let result = try XCTUnwrap(candidate(playing(600, saved: 1_000), now: 1_080))
        XCTAssertEqual(result.advanceSeconds, SyncCadence.maxPlayingAdvance)
        XCTAssertEqual(result.observedAt, Date(timeIntervalSince1970: 1_000 + SyncCadence.maxPlayingAdvance))
    }

    func testADeadPlayingRecordIsPausedAtItsRecordedPosition() throws {
        let result = try XCTUnwrap(candidate(playing(600, saved: 1_000), now: 1_000 + SyncCadence.staleAfter + 1))
        XCTAssertEqual(result.advanceSeconds, 0)
        XCTAssertFalse(result.isPlaying)
        XCTAssertEqual(result.observedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testAPausedRecordNeverAdvances() throws {
        let result = try XCTUnwrap(candidate(observed("phone", position: 300, epoch: 2, at: 1_000), now: 1_010))
        XCTAssertEqual(result.advanceSeconds, 0)
        XCTAssertEqual(result.resumeSeconds, 300)
    }
}
