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

    func testSparseObservedPairsDoNotQueryCartesianProductOfPassiveOffers() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone1 = try fixture.endpoint("phone1", writer: false)
        let phone2 = try fixture.endpoint("phone2", writer: false)

        // Seed 120 passive media offers into the offer index and server
        let offerEntryIDs = try (1...120).map { try item("ep-offer-\($0)") }
        let offerIndex = LibraryOfferIndex(entryIDs: offerEntryIDs)
        _ = await fixture.server.putEngine(try LibraryRecordMapper().record(offerIndex: offerIndex))

        // Sparse observed pairs: phone1 on ep-1; phone2 on ep-2
        try await phone1.transport.publish(makePosition(device: "phone1", entry: "ep-1"), as: .nowPlaying)
        try await phone1.transport.publish(makePosition(device: "phone1", entry: "ep-1"), as: .progress)
        try await phone2.transport.publish(makePosition(device: "phone2", entry: "ep-2"), as: .nowPlaying)
        try await phone2.transport.publish(makePosition(device: "phone2", entry: "ep-2"), as: .progress)

        // Track devices on mac, plus one explicit seed entry
        await mac.transport.track(devices: ["phone1", "phone2"], entries: [try item("ep-seed")])

        // First poll reads offers and device records
        let firstPolled = try await mac.transport.poll([.deviceRecords, .offers])
        let firstRecords = try XCTUnwrap(firstPolled.records)
        XCTAssertEqual(firstRecords.nowPlaying.map(\.record.deviceID), ["phone1", "phone2"])
        XCTAssertEqual(firstRecords.progress.map(\.record.entryID.rawValue).sorted(), ["ep-1", "ep-2"])

        // Repeated poll when idle: verify request count, 100-ID batch count, and requested names
        let fetchesBefore = await mac.driver.targetedFetches
        let askedBefore = await mac.driver.askedNames.count
        let polled = try await mac.transport.poll([.deviceRecords])
        let fetchesAfter = await mac.driver.targetedFetches
        let askedAfter = await mac.driver.askedNames.count

        // An idle poll should be exactly 1 operation (1 batch), not scaling with 3 devices x 120 offers = 360+ IDs (which would require 4+ batches)
        XCTAssertEqual(fetchesAfter - fetchesBefore, 1, "sparse pairs should require only a single fetch operation")
        XCTAssertEqual(askedAfter - askedBefore, 1)

        let askedNames = await mac.driver.askedNames
        let lastBatch = try XCTUnwrap(askedNames.last)
        // Batches must scale with observed pairs (2) + explicit seeds (3 devices x 1 seed = 3) + nowPlaying (3 devices) = 8 names, not 360+ names!
        XCTAssertEqual(lastBatch.count, 8)
        // Ensure no speculative names for passive offer entries were asked
        for offerID in offerEntryIDs {
            let speculativeName = try LibraryRecordMapper().recordID(progressFor: "phone1", entryID: offerID).recordName
            XCTAssertFalse(lastBatch.contains(speculativeName), "passive offer entry \(offerID.rawValue) must not be queried speculatively")
        }

        // Equivalence check: fetchDeviceRecords returns equivalent records without Cartesian fanout
        let separateRecords = try await mac.transport.fetchDeviceRecords()
        XCTAssertEqual(polled.records, separateRecords)
        let separateBatch = await mac.driver.askedNames.last
        XCTAssertEqual(Set(try XCTUnwrap(separateBatch)), Set(lastBatch))
    }

    func testExistingProgressPairsContinueToReturnChangedRewoundPositions() async throws {
        let (fixture, mac, phone) = try await seeded()
        _ = try await mac.transport.poll([.deviceRecords])
        // Keep polling the learned pair even when now-playing no longer names it.
        await fixture.server.remove(try LibraryRecordMapper().recordID(nowPlayingFor: "phone"), via: "test")
        // A token/zone bootstrap reset does not change the account or forget known pairs.
        try await mac.transport.resetAfterServerReset()
        let rewound = try DevicePlaybackPosition(
            deviceID: "phone", entryID: item("ep-1"), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: 3.0, rate: 1.0, isPlaying: false, epoch: 3
        )
        try await phone.transport.publish(rewound, as: .progress)

        let result = try await mac.transport.poll([.deviceRecords])
        let progress = try XCTUnwrap(result.records?.progress.first)
        XCTAssertEqual(progress.record.positionSeconds, 3.0, "rewound position should be returned for known pair")

        let separate = try await mac.transport.fetchDeviceRecords()
        XCTAssertEqual(separate.progress.first?.record.positionSeconds, 3.0)
    }

    func testNewNowPlayingEntryYieldsItsProgressInSameRound() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)

        await mac.transport.track(devices: ["phone"])

        // Phone starts playback of a previously unknown entry ep-new
        let newPos = try DevicePlaybackPosition(
            deviceID: "phone", entryID: item("ep-new"), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: 42.0, rate: 1.0, isPlaying: true, epoch: 1
        )
        try await phone.transport.publish(newPos, as: .nowPlaying)
        try await phone.transport.publish(newPos, as: .progress)

        // Mac polls with no prior knowledge of ep-new
        let result = try await mac.transport.poll([.deviceRecords])
        XCTAssertEqual(result.records?.nowPlaying.map(\.record.entryID.rawValue), ["ep-new"])
        XCTAssertEqual(result.records?.progress.map(\.record.entryID.rawValue), ["ep-new"], "progress for entry introduced by now-playing must be fetched in the same round")
        XCTAssertEqual(result.records?.progress.first?.record.positionSeconds, 42.0)
    }

    func testExplicitTrackSeedsRetainIntentionalCartesianBehaviorAcrossDevices() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        _ = try fixture.endpoint("phone1", writer: false)

        // Successive track calls: first phone1 and seed-1
        await mac.transport.track(devices: ["phone1"], entries: [try item("seed-1")])
        // Second track call: adds phone2
        await mac.transport.track(devices: ["phone2"])

        // When polling, Cartesian seed pairs (mac x seed-1, phone1 x seed-1, phone2 x seed-1) are queried
        _ = try await mac.transport.poll([.deviceRecords])
        let askedNames = await mac.driver.askedNames
        let asked = try XCTUnwrap(askedNames.first)
        let mapper = LibraryRecordMapper()
        let expectedSeedNames = [
            try mapper.recordID(progressFor: "mac", entryID: item("seed-1")).recordName,
            try mapper.recordID(progressFor: "phone1", entryID: item("seed-1")).recordName,
            try mapper.recordID(progressFor: "phone2", entryID: item("seed-1")).recordName,
        ]
        for name in expectedSeedNames {
            XCTAssertTrue(asked.contains(name), "explicit Cartesian seed name \(name) must be asked")
        }

        // Later passive device discovery: a directory record introduces phone3
        let directory = LibraryDeviceDirectory(devices: [
            LibraryDeviceAnnouncement(deviceID: "phone1", kind: "iPhone", announcedAt: Date()),
            LibraryDeviceAnnouncement(deviceID: "phone2", kind: "iPhone", announcedAt: Date()),
            LibraryDeviceAnnouncement(deviceID: "phone3", kind: "iPhone", announcedAt: Date()),
        ])
        _ = await fixture.server.putEngine(try mapper.record(deviceDirectory: directory))

        _ = try await mac.transport.poll([.deviceRecords, .deviceDirectory])
        let secondAskedNames = await mac.driver.askedNames
        let secondAsked = try XCTUnwrap(secondAskedNames.last)
        let phone3SeedName = try mapper.recordID(progressFor: "phone3", entryID: item("seed-1")).recordName
        XCTAssertTrue(secondAsked.contains(phone3SeedName), "later passively discovered device must also be paired with explicit seed")
    }

    func testNewDirectoryDeviceYieldsNowPlayingAndProgressInSameRound() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("new-phone", writer: false)
        let mapper = LibraryRecordMapper()
        let position = try makePosition(device: "new-phone", entry: "new-entry")
        try await phone.transport.publish([(position, .nowPlaying), (position, .progress)])
        let directory = LibraryDeviceDirectory(devices: [
            LibraryDeviceAnnouncement(deviceID: "new-phone", kind: "iPhone", announcedAt: Date())
        ])
        _ = await fixture.server.putEngine(try mapper.record(deviceDirectory: directory))

        let result = try await mac.transport.poll([.deviceRecords, .deviceDirectory])
        XCTAssertEqual(result.records?.nowPlaying.map(\.record.entryID.rawValue), ["new-entry"])
        XCTAssertEqual(result.records?.progress.map(\.record.entryID.rawValue), ["new-entry"])
        let requests = await mac.driver.askedNames
        XCTAssertEqual(requests.count, 3)
    }

    func testScanIngestionDiscoversPreviouslyUnseenProgressOnlyPairAndPollsIt() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        _ = try fixture.endpoint("phone", writer: false)

        await mac.transport.track(devices: ["phone"])

        // Save a progress-only record on the server that has never been active (no now-playing)
        let offlinePos = try DevicePlaybackPosition(
            deviceID: "phone", entryID: item("ep-offline"), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: 88.0, rate: 1.0, isPlaying: false, epoch: 1
        )
        let offlineRecord = try LibraryRecordMapper().record(playback: offlinePos, channel: .progress)
        _ = await fixture.server.putEngine(offlineRecord)

        // Before scan, regular poll does not know ep-offline and must NOT ask for it
        let beforePoll = try await mac.transport.poll([.deviceRecords])
        XCTAssertEqual(beforePoll.records?.progress, [])
        let askedNamesBefore = await mac.driver.askedNames
        let askedBefore = try XCTUnwrap(askedNamesBefore.last)
        XCTAssertFalse(askedBefore.contains(offlineRecord.recordID.recordName))

        // Whole-zone scan runs (e.g. periodic scan or discoverPeers)
        let discovered = try await mac.transport.discoverPeers()
        XCTAssertGreaterThanOrEqual(discovered, 1)

        // Subsequent poll now knows the pair from scan ingestion and asks for it
        let afterPoll = try await mac.transport.poll([.deviceRecords])
        XCTAssertEqual(afterPoll.records?.progress.map(\.record.entryID.rawValue), ["ep-offline"])
        XCTAssertEqual(afterPoll.records?.progress.first?.record.positionSeconds, 88.0)
        let askedNamesAfter = await mac.driver.askedNames
        let askedAfter = try XCTUnwrap(askedNamesAfter.last)
        XCTAssertTrue(askedAfter.contains(offlineRecord.recordID.recordName))
    }

    func testFailedPublicationDoesNotTeachPair() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        await mac.driver.setFailSends(true)

        let pos = try DevicePlaybackPosition(
            deviceID: "mac", entryID: item("ep-fail"), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: 10.0, rate: 1.0, isPlaying: true, epoch: 1
        )
        await XCTAssertThrowsErrorAsync(try await mac.transport.publish(pos, as: .progress)) { _ in }

        await mac.driver.setFailSends(false)
        let records = try await mac.transport.fetchDeviceRecords()
        XCTAssertTrue(records.progress.isEmpty, "failed write must not claim remote existence or teach pair")
        let requested = await mac.driver.askedNames.last
        let progressName = try LibraryRecordMapper().recordID(progressFor: "mac", entryID: pos.entryID).recordName
        XCTAssertFalse(try XCTUnwrap(requested).contains(progressName))
    }

    func testResetAfterAccountChangeClearsPairCache() async throws {
        let fixture = try MediaFixture()
        let mac = try fixture.endpoint("mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)

        try await phone.transport.publish(makePosition(device: "phone", entry: "ep-1"), as: .nowPlaying)
        try await phone.transport.publish(makePosition(device: "phone", entry: "ep-1"), as: .progress)
        await mac.transport.track(devices: ["phone"], entries: [try item("old-seed")])

        let polled = try await mac.transport.poll([.deviceRecords])
        XCTAssertEqual(polled.records?.progress.map(\.record.entryID.rawValue), ["ep-1"])

        // Account reset
        await mac.transport.resetAfterAccountChange()
        await fixture.server.remove(try LibraryRecordMapper().recordID(nowPlayingFor: "phone"), via: "test")
        await mac.transport.track(devices: ["phone"])

        // Fetch present on new call: pair cache is cleared
        let afterReset = try await mac.transport.fetchDeviceRecords()
        XCTAssertTrue(afterReset.progress.isEmpty, "account reset must clear pair cache")
        let requested = await mac.driver.askedNames.last
        let oldName = try LibraryRecordMapper().recordID(progressFor: "phone", entryID: item("ep-1")).recordName
        XCTAssertFalse(try XCTUnwrap(requested).contains(oldName))
        let oldSeed = try LibraryRecordMapper().recordID(progressFor: "phone", entryID: item("old-seed")).recordName
        XCTAssertFalse(try XCTUnwrap(requested).contains(oldSeed))
    }
}
