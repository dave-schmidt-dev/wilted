import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// "Last played on iPhone at mm:ss": which records speak for it and its wording, plus how the
/// sync round's position importer adopts what the phone published.
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

    // MARK: importer fixture

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

    private func makeImporter() -> (WiltedMacPositionImporter, Host) {
        let host = Host(target: WiltedMacImportTarget(revision: revision, durationSeconds: 3_000), episode: episode)
        let clock = now
        return (WiltedMacPositionImporter(host: host, deviceID: macID, now: { clock }), host)
    }

    // MARK: importer

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
}
