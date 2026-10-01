import CloudKit
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

/// The request budget of one sync round, counted where CloudKit would count it: one targeted
/// fetch or one send is one operation. A fake transport counting method calls would hide that one
/// `fetchDeviceRecords` can be several operations.
final class LibraryPollRequestCountTests: XCTestCase {
    private func seeded() async throws -> (MediaFixture, MediaFixture.Endpoint, MediaFixture.Endpoint) {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        try await phone.transport.publish(makePosition(device: "phone", entry: "ep-1"), as: .nowPlaying)
        try await phone.transport.publish(makePosition(device: "phone", entry: "ep-1"), as: .progress)
        await mac.transport.track(devices: ["phone"])
        return (fixture, mac, phone)
    }

    func testAnIdleMacRoundIsOneOperation() async throws {
        let (_, mac, _) = try await seeded()
        _ = try await mac.transport.poll([.intents, .deviceRecords])  // learns the entries
        let before = await mac.driver.targetedFetches
        for _ in 0..<10 {
            let result = try await mac.transport.poll([.intents, .deviceRecords])
            XCTAssertEqual(result.records?.nowPlaying.map(\.record.deviceID), ["phone"])
            XCTAssertEqual(result.records?.progress.map(\.record.entryID.rawValue), ["ep-1"])
        }
        let after = await mac.driver.targetedFetches
        XCTAssertEqual(after - before, 10, "ten idle rounds, ten operations: intents and records share one")
    }

    func testThePollReturnsWhatTheSeparateReadsReturn() async throws {
        let (fixture, mac, phone) = try await seeded()
        let intent = try LibraryIntent.requestMedia(entryID: item("ep-1"), deviceID: "phone", createdAt: Date(timeIntervalSince1970: 5), id: "i-1")
        try await phone.transport.send(intent: intent)
        try await mac.transport.publishMedia(offer: try fixture.offer(), fileURL: try fixture.audioFile())
        let polled = try await mac.transport.poll([.intents, .deviceRecords, .offers])
        let intents = try await mac.transport.listIntents()
        let records = try await mac.transport.fetchDeviceRecords()
        let offers = try await mac.transport.mediaOffers()
        XCTAssertEqual(polled.intents, intents)
        XCTAssertEqual(polled.records, records)
        XCTAssertEqual(polled.offers, offers)
        XCTAssertEqual(polled.intents, [intent])
    }

    func testTheOwnIntentIndexIsAskedForOnceWhenItDoesNotExistAndAgainAfterASend() async throws {
        let (_, mac, _) = try await seeded()
        let ownIndex = try LibraryRecordMapper().recordID(intentIndexFor: "mac").recordName
        _ = try await mac.transport.poll([.intents])
        _ = try await mac.transport.poll([.intents])
        _ = try await mac.transport.poll([.intents])
        var asked = await mac.driver.askedNames
        XCTAssertEqual(asked.filter { $0.contains(ownIndex) }.count, 1, "a known-missing record is not refetched every round")
        let intent = try LibraryIntent.requestMedia(entryID: item("ep-1"), deviceID: "mac", createdAt: Date(timeIntervalSince1970: 9), id: "m-1")
        try await mac.transport.send(intent: intent)
        let result = try await mac.transport.poll([.intents])
        XCTAssertEqual(result.intents, [intent], "sending creates the index, so it is read again")
        asked = await mac.driver.askedNames
        // One more for the send itself, which loads the index before extending it, and one for this read.
        XCTAssertEqual(asked.filter { $0.contains(ownIndex) }.count, 3)
    }

    func testNowPlayingAndProgressGoUpInOneSend() async throws {
        let fixture = try MediaFixture()
        let phone = try fixture.endpoint("phone", writer: false)
        let before = await phone.driver.sendCount
        try await phone.transport.publish([
            (try makePosition(device: "phone", entry: "ep-1"), .nowPlaying),
            (try makePosition(device: "phone", entry: "ep-1"), .progress),
        ])
        let after = await phone.driver.sendCount
        XCTAssertEqual(after - before, 1)
        let mac = try fixture.endpoint("mac", writer: true)
        await mac.transport.track(devices: ["phone"], entries: [try item("ep-1")])
        let records = try await mac.transport.fetchDeviceRecords()
        XCTAssertEqual(records.nowPlaying.count, 1)
        XCTAssertEqual(records.progress.count, 1)
    }

    func testAWrongDeviceCannotBePublishedInABatch() async throws {
        let fixture = try MediaFixture()
        let phone = try fixture.endpoint("phone", writer: false)
        do {
            try await phone.transport.publish([(try makePosition(device: "mac", entry: "ep-1"), .nowPlaying)])
            XCTFail("expected an ownership violation")
        } catch let error as LibraryTransportError {
            guard case .ownershipViolation = error else { return XCTFail("wrong error \(error)") }
        }
    }
}
