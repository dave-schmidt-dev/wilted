import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacDeviceManagementTests: XCTestCase {
    private let macID = "mac-device-management"
    private let firstID = "synthetic-phone-a"
    private let secondID = "synthetic-ipad-b"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testDeviceRowsUseSavedNameThenKindThenNeutralAndShowLastAnnouncement() throws {
        let entry = try ItemID(rawValue: "synthetic-episode")
        let request = LibraryMediaRequestStatus(
            intentID: "synthetic-request", entryID: entry, stage: .sending, updatedAt: start)
        let rows = WiltedMacLibrarySyncStatus.deviceRows([
            WiltedMacLinkedDevice(
                deviceID: firstID, kind: nil, isLinked: true, inFlight: [request],
                displayName: "Kitchen phone", lastAnnouncedAt: start),
            WiltedMacLinkedDevice(deviceID: secondID, kind: "iPad", isLinked: true, inFlight: []),
            WiltedMacLinkedDevice(deviceID: "synthetic-unknown", kind: nil, isLinked: true, inFlight: []),
        ])

        XCTAssertEqual(rows.map(\.label), ["Kitchen phone", "iPad", "Linked device"])
        XCTAssertEqual(rows[0].lastAnnouncedLabel, start.formatted(date: .abbreviated, time: .shortened))
        XCTAssertEqual(rows[1].lastAnnouncedLabel, "Unknown")
        XCTAssertTrue(rows[0].hasInFlightTransfer)
        XCTAssertFalse(rows[1].hasInFlightTransfer)
    }

    func testRenameRoundTripsAcrossDeviceLinksRelaunch() async throws {
        let defaults = WiltedMacTestPreferences.ephemeral()
        let preferences = WiltedMacLANPreferences(defaults: defaults)
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        let transport = HandshakeTransport(InMemoryLibraryTransport(deviceID: macID, server: server))
        let directory = LibraryDeviceDirectory(devices: [announcement(firstID, "iPad", at: start)])
        let links = WiltedMacDeviceLinks(
            transport: transport, macDeviceID: macID, now: { [start] in start },
            preferences: preferences)

        await links.noteDirectory(directory)
        await links.flush()
        try await links.renameDevice(firstID, to: "Kitchen iPad")

        let relaunched = WiltedMacDeviceLinks(
            transport: transport, macDeviceID: macID, now: { [start] in start },
            preferences: preferences)
        await relaunched.noteDirectory(directory)
        let devices = await relaunched.devices()
        let row = try XCTUnwrap(WiltedMacLibrarySyncStatus.deviceRows(devices).first)
        XCTAssertEqual(row.label, "Kitchen iPad")
        XCTAssertEqual(preferences.deviceDisplayNames[firstID], "Kitchen iPad")
    }

    func testRemovalDeletesOnlySelectedLinkAndPreservesLibraryAndListeningHistory() async throws {
        let defaults = WiltedMacTestPreferences.ephemeral()
        let preferences = WiltedMacLANPreferences(defaults: defaults)
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        let mac = HandshakeTransport(InMemoryLibraryTransport(deviceID: macID, server: server))
        let first = InMemoryLibraryTransport(deviceID: firstID, server: server)
        let second = InMemoryLibraryTransport(deviceID: secondID, server: server)
        let oldDate = start.addingTimeInterval(-60)
        let directory = LibraryDeviceDirectory(devices: [
            announcement(firstID, "iPhone", at: oldDate, key: Data([1, 2, 3])),
            announcement(secondID, "iPad", at: oldDate, key: Data([4, 5, 6])),
        ])
        let links = WiltedMacDeviceLinks(
            transport: mac, macDeviceID: macID, now: { [start] in start }, preferences: preferences)
        await links.setMacLANPublicKey(Data([9, 8, 7]))
        await links.noteDirectory(directory)
        await links.flush()
        try await links.renameDevice(firstID, to: "Removed phone")

        let episodeID = try ItemID(rawValue: "synthetic-preserved-episode")
        let sourceID = try ItemID(rawValue: "synthetic-preserved-feed")
        let entry = try LibraryEntry(
            id: episodeID, kind: .podcastEpisode, sourceID: sourceID,
            title: "Preserved episode", summary: "fixture", publishedAt: start)
        let history = ListeningRecord(itemID: episodeID, completedAt: start, updatedAt: start, deviceID: firstID)
        _ = try await mac.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .entry(entry), baseVersion: 0),
            PendingLibraryChange(localSeq: 2, change: .listening(history), baseVersion: 0),
        ])
        let progress = try DevicePlaybackPosition(
            deviceID: firstID, entryID: episodeID, revision: try RevisionID(rawValue: "synthetic-revision"),
            positionSeconds: 42, isPlaying: false, epoch: 1, publishedAt: start)
        try await first.publish(progress, as: .progress)
        let libraryBefore = await server.currentSnapshot
        let recordsBefore = try await second.fetchDeviceRecords()

        try await links.removeDevice(firstID)

        XCTAssertEqual(mac.deletedLinkIDs, [firstID])
        let removedLink = try await first.fetchDeviceLink()
        let keptLink = try await second.fetchDeviceLink()
        let libraryAfter = await server.currentSnapshot
        let removedKey = await links.phonePublicKey(for: firstID)
        let keptKey = await links.phonePublicKey(for: secondID)
        XCTAssertNil(removedLink)
        XCTAssertNotNil(keptLink)
        XCTAssertNil(removedKey)
        XCTAssertEqual(keptKey, Data([4, 5, 6]))
        XCTAssertEqual(libraryAfter, libraryBefore)
        XCTAssertEqual(libraryBefore.entries[episodeID], entry)
        XCTAssertEqual(libraryBefore.listening[episodeID], history)
        let recordsAfter = try await second.fetchDeviceRecords()
        XCTAssertEqual(recordsAfter.progress, recordsBefore.progress)
        XCTAssertEqual(recordsBefore.progress.count, 1)
        XCTAssertEqual(preferences.stoppedPhones, [firstID], "removal must preserve the stopped mark")
        XCTAssertEqual(preferences.deviceRemovalDates[firstID], start)
        XCTAssertNil(preferences.deviceDisplayNames[firstID])
    }

    func testRemovalPreservesBothSurvivorsImmediatelyAndAfterRelaunch() async throws {
        let defaults = WiltedMacTestPreferences.ephemeral()
        let stoppedID = "synthetic-stopped-phone"
        let preferences = WiltedMacLANPreferences(defaults: defaults)
        preferences.insertStoppedPhone(stoppedID)
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        let mac = HandshakeTransport(InMemoryLibraryTransport(deviceID: macID, server: server))
        let tablet = InMemoryLibraryTransport(deviceID: secondID, server: server)
        let phone = InMemoryLibraryTransport(deviceID: stoppedID, server: server)
        let tabletKey = Data([1, 2])
        let phoneKey = Data([3, 4])
        let macKey = Data([5, 6])
        let directory = LibraryDeviceDirectory(devices: [
            announcement(firstID, "iPhone", at: start),
            announcement(secondID, "iPad", at: start, key: tabletKey),
            announcement(stoppedID, "iPhone", at: start, key: phoneKey),
        ])
        func launch() -> WiltedMacDeviceLinks {
            WiltedMacDeviceLinks(transport: mac, macDeviceID: macID, now: { [start] in start },
                                 preferences: WiltedMacLANPreferences(defaults: defaults))
        }
        let links = launch()
        await links.setMacLANPublicKey(macKey)
        await links.noteDirectory(directory)
        await links.flush()
        try await links.renameDevice(secondID, to: "Kitchen tablet")
        try await links.renameDevice(stoppedID, to: "Travel phone")
        let before = await links.devices().filter { $0.deviceID != firstID }
        XCTAssertEqual(before.map(\.deviceID), [secondID, stoppedID])
        XCTAssertEqual(before.map(\.displayName), ["Kitchen tablet", "Travel phone"])
        XCTAssertEqual(before.map(\.isDirectDownloadsStopped), [false, true])
        XCTAssertTrue(before.allSatisfy(\.isLinked))
        let tabletLink = try await tablet.fetchDeviceLink()
        let phoneLink = try await phone.fetchDeviceLink()
        XCTAssertNotNil(tabletLink)
        XCTAssertNotNil(phoneLink)

        func assertSurvivors(_ current: WiltedMacDeviceLinks) async throws {
            let rows = await current.devices()
            XCTAssertEqual(rows, before)
            XCTAssertEqual(WiltedMacLibrarySyncStatus.deviceRows(rows), WiltedMacLibrarySyncStatus.deviceRows(before))
            let cachedTabletKey = await current.phonePublicKey(for: secondID)
            let cachedPhoneKey = await current.phonePublicKey(for: stoppedID)
            XCTAssertEqual(cachedTabletKey, tabletKey)
            XCTAssertEqual(cachedPhoneKey, phoneKey)
            let currentTablet = try await tablet.fetchDeviceLink()
            let currentPhone = try await phone.fetchDeviceLink()
            XCTAssertEqual(currentTablet, tabletLink)
            XCTAssertEqual(currentPhone, phoneLink)
        }

        try await links.removeDevice(firstID)
        try await assertSurvivors(links)
        let relaunched = launch()
        await relaunched.setMacLANPublicKey(macKey)
        await relaunched.noteDirectory(directory)
        await relaunched.flush()
        try await assertSurvivors(relaunched)

        let request = try LibraryIntent.requestMedia(
            entryID: ItemID(rawValue: "synthetic-next-episode"), deviceID: secondID,
            createdAt: start, id: "synthetic-next-request")
        await relaunched.record(request, stage: .answered)
        let answer = try await tablet.fetchDeviceLink()
        XCTAssertEqual(answer?.status(intentID: request.id)?.stage, .answered)
    }

    func testRemovalKeepsSurvivorsPendingPublicationForNextFlush() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        let mac = HandshakeTransport(InMemoryLibraryTransport(deviceID: macID, server: server))
        let tablet = InMemoryLibraryTransport(deviceID: secondID, server: server)
        let links = WiltedMacDeviceLinks(transport: mac, macDeviceID: macID)
        await links.noteDevices([firstID, secondID])
        await links.flush()
        let request = try LibraryIntent.requestMedia(
            entryID: ItemID(rawValue: "synthetic-pending-episode"), deviceID: secondID,
            createdAt: start, id: "synthetic-pending-request")
        await links.noteReceived([request])
        let previous = try await tablet.fetchDeviceLink()
        XCTAssertNil(previous?.status(intentID: request.id))

        try await links.removeDevice(firstID)
        await links.flush()
        let published = try await tablet.fetchDeviceLink()
        XCTAssertEqual(published?.status(intentID: request.id)?.stage, .received)
    }

    func testStaleDirectoryReplayAndRelaunchKeepRemovedDeviceGone() async throws {
        let defaults = WiltedMacTestPreferences.ephemeral()
        let preferences = WiltedMacLANPreferences(defaults: defaults)
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        let transport = HandshakeTransport(InMemoryLibraryTransport(deviceID: macID, server: server))
        let links = WiltedMacDeviceLinks(
            transport: transport, macDeviceID: macID, now: { [start] in start }, preferences: preferences)
        let futureAnnouncement = start.addingTimeInterval(3_600)
        let stale = LibraryDeviceDirectory(devices: [announcement(firstID, "iPhone", at: futureAnnouncement)])
        await links.noteDirectory(stale)
        await links.flush()
        try await links.removeDevice(firstID)

        let relaunched = WiltedMacDeviceLinks(
            transport: transport, macDeviceID: macID, now: { [start] in start }, preferences: preferences)
        await relaunched.noteDirectory(stale)
        let entryID = try ItemID(rawValue: "synthetic-stale-request")
        await relaunched.noteDevices([firstID])
        let staleRequest = try LibraryIntent.requestMedia(
            entryID: entryID, deviceID: firstID, createdAt: start, id: "stale-request")
        await relaunched.record(staleRequest, stage: .sending)
        await relaunched.flush()

        let devices = await relaunched.devices()
        let remoteLink = try await InMemoryLibraryTransport(deviceID: firstID, server: server).fetchDeviceLink()
        XCTAssertTrue(devices.isEmpty)
        XCTAssertNil(remoteLink)
        XCTAssertEqual(transport.deletedLinkIDs, [firstID])
        XCTAssertEqual(preferences.deviceRemovalDates[firstID], futureAnnouncement,
                       "a future-dated stale announcement must not pass the removal boundary")
    }

    func testFreshAnnouncementRestoresRowButKeepsDirectDownloadsStoppedUntilPairing() async throws {
        let defaults = WiltedMacTestPreferences.ephemeral()
        let preferences = WiltedMacLANPreferences(defaults: defaults)
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        let transport = HandshakeTransport(InMemoryLibraryTransport(deviceID: macID, server: server))
        let links = WiltedMacDeviceLinks(
            transport: transport, macDeviceID: macID, now: { [start] in start }, preferences: preferences)
        let oldDate = start.addingTimeInterval(-1)
        await links.noteDirectory(LibraryDeviceDirectory(devices: [announcement(firstID, "iPhone", at: oldDate)]))
        await links.flush()
        try await links.removeDevice(firstID)

        let relaunched = WiltedMacDeviceLinks(
            transport: transport, macDeviceID: macID, now: { [start] in start }, preferences: preferences)
        let freshDate = start.addingTimeInterval(60)
        await relaunched.noteDirectory(LibraryDeviceDirectory(devices: [
            announcement(firstID, "iPhone", at: freshDate, key: Data([4, 3, 2, 1]))
        ]))
        await relaunched.flush()

        let devices = await relaunched.devices()
        let row = try XCTUnwrap(WiltedMacLibrarySyncStatus.deviceRows(devices).first)
        XCTAssertEqual(row.id, firstID)
        XCTAssertTrue(row.isDirectDownloadsStopped)
        let remoteLink = try await InMemoryLibraryTransport(deviceID: firstID, server: server).fetchDeviceLink()
        let link = try XCTUnwrap(remoteLink)
        XCTAssertNil(link.lanPublicKey)
        XCTAssertNil(link.knownPhoneKeyFingerprint)
    }

    func testFailedCloudDeletionKeepsRowAndCanRetry() async throws {
        let defaults = WiltedMacTestPreferences.ephemeral()
        let preferences = WiltedMacLANPreferences(defaults: defaults)
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        let transport = HandshakeTransport(InMemoryLibraryTransport(deviceID: macID, server: server))
        let links = WiltedMacDeviceLinks(
            transport: transport, macDeviceID: macID, now: { [start] in start }, preferences: preferences)
        await links.noteDirectory(LibraryDeviceDirectory(devices: [announcement(firstID, "iPhone", at: start)]))
        await links.flush()
        transport.failNextLinkDeletes(1)

        do {
            try await links.removeDevice(firstID)
            XCTFail("the injected CloudKit delete failure must reach the caller")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let afterFailure = await links.devices()
        XCTAssertEqual(afterFailure.map(\.deviceID), [firstID])
        XCTAssertNil(preferences.deviceRemovalDates[firstID])
        XCTAssertFalse(preferences.stoppedPhones.contains(firstID))

        try await links.removeDevice(firstID)

        let afterRetry = await links.devices()
        XCTAssertTrue(afterRetry.isEmpty)
        XCTAssertEqual(transport.deletedLinkIDs, [firstID, firstID])
    }

    private func announcement(_ id: String, _ kind: String, at date: Date, key: Data? = nil)
        -> LibraryDeviceAnnouncement {
        LibraryDeviceAnnouncement(deviceID: id, kind: kind, announcedAt: date, lanPublicKey: key)
    }
}
