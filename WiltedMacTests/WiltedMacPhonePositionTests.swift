import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// "Last played on iPhone at mm:ss": which records speak for it, its wording, and the bounded
/// fetch a Mac Play press makes before the audio starts.
@MainActor
final class WiltedMacPhonePositionTests: XCTestCase {
    private let macID = "mac-test"
    private let phoneID = "iphone-1234"
    private let episode = try! ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
    private let revision = try! RevisionID(rawValue: "rev-a")
    private let now = Date(timeIntervalSince1970: 100_000)

    private func observed(
        device: String, position: Double, epoch: Int, playing: Bool = false, savedSecondsAgo: Double
    ) throws -> ObservedPlayback {
        let saved = now.addingTimeInterval(-savedSecondsAgo)
        let record = try DevicePlaybackPosition(
            deviceID: device, entryID: episode, revision: revision, positionSeconds: position,
            isPlaying: playing, epoch: epoch, publishedAt: saved)
        return ObservedPlayback(record: record, serverModifiedAt: saved)
    }

    private func records(_ items: ObservedPlayback...) -> LibraryDeviceRecords {
        LibraryDeviceRecords(nowPlaying: items, progress: items)
    }

    // MARK: selection

    func testThePhoneIsShownWhenItsRecordIsTheNewest() throws {
        let phone = try observed(device: phoneID, position: 754, epoch: 2, savedSecondsAgo: 60)
        let mac = try observed(device: macID, position: 100, epoch: 1, savedSecondsAgo: 600)
        let selected = WiltedMacPhonePlayback.selections(records: records(phone, mac), localDeviceID: macID, now: now)
        XCTAssertEqual(selected[episode]?.positionSeconds, 754)
        XCTAssertEqual(selected[episode].map(WiltedMacPhonePlayback.label), "Last played on iPhone at 12:34")
    }

    func testTheLineIsHiddenOnceTheMacListenedAfterThePhone() throws {
        let phone = try observed(device: phoneID, position: 754, epoch: 2, savedSecondsAgo: 600)
        let mac = try observed(device: macID, position: 800, epoch: 3, savedSecondsAgo: 60)
        XCTAssertTrue(WiltedMacPhonePlayback.selections(records: records(phone, mac), localDeviceID: macID, now: now).isEmpty)
    }

    func testAnEpisodeOnlyTheMacListenedToNeverShowsTheLine() throws {
        let mac = try observed(device: macID, position: 800, epoch: 1, savedSecondsAgo: 60)
        XCTAssertTrue(WiltedMacPhonePlayback.selections(records: records(mac), localDeviceID: macID, now: now).isEmpty)
    }

    func testAPhoneRecordBelowTheEntrysHighestEpochIsStaleAndHidden() throws {
        let phone = try observed(device: phoneID, position: 300, epoch: 1, savedSecondsAgo: 10)
        let mac = try observed(device: macID, position: 800, epoch: 2, savedSecondsAgo: 300)
        XCTAssertTrue(WiltedMacPhonePlayback.selections(records: records(phone, mac), localDeviceID: macID, now: now).isEmpty)
    }

    func testAPositionOfZeroIsNotAPosition() throws {
        let phone = try observed(device: phoneID, position: 0, epoch: 2, savedSecondsAgo: 10)
        XCTAssertTrue(WiltedMacPhonePlayback.selections(records: records(phone), localDeviceID: macID, now: now).isEmpty)
    }

    func testAPlayingPhoneIsShownAheadOfItsRecord() throws {
        let phone = try observed(device: phoneID, position: 300, epoch: 2, playing: true, savedSecondsAgo: 20)
        let selected = WiltedMacPhonePlayback.selections(records: records(phone), localDeviceID: macID, now: now)
        XCTAssertEqual(try XCTUnwrap(selected[episode]).positionSeconds, 320, accuracy: 0.001)
        XCTAssertEqual(selected[episode]?.isPlaying, true)
    }

    func testAnUnknownDeviceKindIsNotAPhone() throws {
        let other = try observed(device: "ipad-9", position: 300, epoch: 2, savedSecondsAgo: 20)
        XCTAssertTrue(WiltedMacPhonePlayback.selections(records: records(other), localDeviceID: macID, now: now).isEmpty)
    }

    func testTheLabelFormatsMinutesAndHours() {
        func label(_ seconds: Double) -> String {
            WiltedMacPhonePlayback.label(.init(entryID: episode, positionSeconds: seconds, isPlaying: false))
        }
        XCTAssertEqual(label(5), "Last played on iPhone at 00:05")
        XCTAssertEqual(label(754.9), "Last played on iPhone at 12:34")
        XCTAssertEqual(label(3_723), "Last played on iPhone at 1:02:03")
    }

    // MARK: Play-press refresh

    @MainActor private final class Host: WiltedMacPositionImportHost {
        var requests: [RemotePositionRequest] = []
        let target: WiltedMacImportTarget
        let episode: ItemID
        init(target: WiltedMacImportTarget, episode: ItemID) {
            self.target = target
            self.episode = episode
        }
        func importTargets() async -> [ItemID: WiltedMacImportTarget]? { [episode: target] }
        func applyRemotePosition(_ request: RemotePositionRequest) async -> RemotePositionOutcome? {
            requests.append(request)
            return .applied
        }
    }

    private struct FetchFailed: Error {}

    private func makeImporter() -> (WiltedMacPositionImporter, Host) {
        let host = Host(target: WiltedMacImportTarget(revision: revision, durationSeconds: 3_000), episode: episode)
        let clock = now
        return (WiltedMacPositionImporter(host: host, deviceID: macID, now: { clock }), host)
    }

    private func refresher(
        fetch: @escaping WiltedMacPlayPositionRefresher.Fetch, timeout: Duration = .seconds(2)
    ) -> (WiltedMacPlayPositionRefresher, Host) {
        let (importer, host) = makeImporter()
        return (WiltedMacPlayPositionRefresher(fetch: fetch, importer: importer, timeout: timeout), host)
    }

    func testPlayReadsThePhonesNewerPositionBeforeTheAudioStarts() async throws {
        let phone = try observed(device: phoneID, position: 1_200, epoch: 2, savedSecondsAgo: 10)
        let fresh = records(phone)
        let (refresher, host) = refresher(fetch: { fresh })
        await refresher.refreshBeforePlay()
        XCTAssertEqual(host.requests.map(\.positionSeconds), [1_200])
        XCTAssertEqual(refresher.refreshCount, 1)
        XCTAssertEqual(refresher.skippedCount, 0)
    }

    func testAFailedFetchProceedsWithTheStoredPosition() async {
        let (refresher, host) = refresher(fetch: { throw FetchFailed() })
        await refresher.refreshBeforePlay()
        XCTAssertTrue(host.requests.isEmpty)
        XCTAssertEqual(refresher.skippedCount, 1)
    }

    func testAClosedGateProceedsWithoutWaiting() async {
        let (refresher, host) = refresher(fetch: { throw TransportThrottled(retryAt: Date().addingTimeInterval(30)) })
        await refresher.refreshBeforePlay()
        XCTAssertTrue(host.requests.isEmpty)
        XCTAssertEqual(refresher.skippedCount, 1)
    }

    func testASlowFetchIsAbandonedAtTheTimeout() async throws {
        let phone = try observed(device: phoneID, position: 1_200, epoch: 2, savedSecondsAgo: 10)
        let late = records(phone)
        let (refresher, host) = refresher(
            fetch: {
                try await Task.sleep(for: .seconds(30))
                return late
            },
            timeout: .milliseconds(50))
        let started = ContinuousClock.now
        await refresher.refreshBeforePlay()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "Play is not held for a slow network")
        XCTAssertTrue(host.requests.isEmpty)
        XCTAssertEqual(refresher.skippedCount, 1)
    }

    func testPlayReportsWhatItReadToTheLine() async throws {
        let phone = try observed(device: phoneID, position: 1_200, epoch: 2, savedSecondsAgo: 10)
        let fresh = records(phone)
        let (importer, _) = makeImporter()
        var reported: LibraryDeviceRecords?
        let refresher = WiltedMacPlayPositionRefresher(
            fetch: { fresh }, importer: importer, onRecords: { reported = $0 })
        await refresher.refreshBeforePlay()
        XCTAssertEqual(reported?.nowPlaying.count, 1)
    }

    // MARK: importer additions

    func testAPlayingPhoneIsAdoptedAheadOfItsRecordAndRemembered() async throws {
        let phone = try observed(device: phoneID, position: 300, epoch: 2, playing: true, savedSecondsAgo: 20)
        let (importer, host) = makeImporter()
        await importer.handle(records(phone))
        XCTAssertEqual(try XCTUnwrap(host.requests.first).positionSeconds, 320, accuracy: 0.001)
        let adoption = try XCTUnwrap(importer.adopted[episode])
        XCTAssertEqual(adoption.positionSeconds, 320, accuracy: 0.001)
    }

    func testAnAdvanceIsBoundedSoAStalePlayingRecordDoesNotRunAway() async throws {
        // 80 s old is inside the 90 s staleness window; the advance still stops at 45 s.
        let phone = try observed(device: phoneID, position: 300, epoch: 2, playing: true, savedSecondsAgo: 80)
        let (importer, host) = makeImporter()
        await importer.handle(records(phone))
        XCTAssertEqual(try XCTUnwrap(host.requests.first).positionSeconds, 345, accuracy: 0.001)
    }

    func testAPausedRecordIsAdoptedAsIs() async throws {
        let phone = try observed(device: phoneID, position: 300, epoch: 2, savedSecondsAgo: 20)
        let (importer, host) = makeImporter()
        await importer.handle(records(phone))
        XCTAssertEqual(host.requests.first?.positionSeconds, 300)
    }

    func testHandleAwaitingReturnsOnlyAfterTheRecordsAreActedOn() async throws {
        let phone = try observed(device: phoneID, position: 300, epoch: 2, savedSecondsAgo: 20)
        let (importer, host) = makeImporter()
        await importer.handleAwaiting(records(phone))
        XCTAssertEqual(host.requests.count, 1, "stored before it returned")
    }
}
