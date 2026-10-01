import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// A launch with no signal resumes where this phone left off (it used to start at 0, because the
/// phone's own last position came only from the server's device records).
@MainActor
final class LibraryOwnPositionTests: XCTestCase {
    private var scratch: URL!
    private var positionsURL: URL!
    private var cache: FileMediaCache!
    private let entryID = try! ItemID(rawValue: "item-a")
    private let revisionID = try! RevisionID(rawValue: "rev-1")
    private let payload = Data((0..<2_000).map { UInt8($0 % 251) })

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-own-position-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        positionsURL = scratch.appendingPathComponent("state/own-positions.json")
        cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let file = scratch.appendingPathComponent("incoming.mp4")
        try payload.write(to: file)
        let hash = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let offer = try LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash, byteCount: Int64(payload.count),
            mediaType: "audio/mp4", durationSeconds: 600)
        _ = try await cache.adopt(verifiedFile: file, for: offer)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func model(deviceID: String = "phone") -> LibraryAppModel {
        let suite = "wilted.ownposition.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "no signal"), deviceID: deviceID, mediaCache: cache,
            preferences: defaults, ownPositionsURL: positionsURL)
    }

    private func saved(_ seconds: Double, device: String = "phone", revision: RevisionID? = nil) throws -> ObservedPlayback {
        ObservedPlayback(
            record: try DevicePlaybackPosition(
                deviceID: device, entryID: entryID, revision: revision ?? revisionID, positionSeconds: seconds,
                isPlaying: false, epoch: 3, publishedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            serverModifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testOfflineLaunchResumesWhereThePhoneLeftOff() async throws {
        let first = model()
        first.handoffState.ownPositions[entryID] = try saved(123)

        let offline = model()
        XCTAssertEqual(offline.resumeStart(for: entryID, cachedRevision: revisionID), 0, "nothing loaded before loadLocalState")
        await offline.loadLocalState()
        XCTAssertEqual(offline.resumeStart(for: entryID, cachedRevision: revisionID), 123)
    }

    func testAnotherInstallsOrRevisionsPositionIsIgnored() async throws {
        let first = model(deviceID: "other-phone")
        first.handoffState.ownPositions[entryID] = try saved(200, device: "other-phone")

        let offline = model()
        await offline.loadLocalState()
        XCTAssertEqual(offline.resumeStart(for: entryID, cachedRevision: revisionID), 0, "another device's record is not this phone's")

        let sameDevice = model()
        sameDevice.handoffState.ownPositions[entryID] = try saved(50, revision: try RevisionID(rawValue: "rev-0"))
        let reloaded = model()
        await reloaded.loadLocalState()
        XCTAssertEqual(reloaded.resumeStart(for: entryID, cachedRevision: revisionID), 0, "a position in other audio is never used")
    }

    func testUnpublishedPositionSurvivesARelaunchAndAnOlderServerCopy() async throws {
        let first = model()
        first.handoffState.ownPositions[entryID] = try saved(123)
        first.handoffState.unpublished[entryID] = (position: 123, savedAt: Date(timeIntervalSince1970: 1_700_000_100))

        let relaunched = model()
        await relaunched.loadLocalState()
        XCTAssertEqual(relaunched.handoffState.unpublished[entryID]?.position, 123, "still owed to the server after a relaunch")
        XCTAssertEqual(relaunched.resumeStart(for: entryID, cachedRevision: revisionID), 123)
    }

    func testAnotherDevicesCheckpointIsRestoredOfflineAndLosesToANewerOwnPosition() async throws {
        let first = model()
        first.handoffState.savedCheckpoints[entryID] = try saved(300, device: "mac")

        let offline = model()
        await offline.loadLocalState()
        XCTAssertEqual(offline.resumeStart(for: entryID, cachedRevision: revisionID), 300, "the Mac's position resumes a cold offline start")

        let newer = ObservedPlayback(
            record: try DevicePlaybackPosition(
                deviceID: "phone", entryID: entryID, revision: revisionID, positionSeconds: 40, isPlaying: false,
                epoch: 9, publishedAt: Date(timeIntervalSince1970: 1_700_000_500)),
            serverModifiedAt: Date(timeIntervalSince1970: 1_700_000_500))
        offline.handoffState.ownPositions[entryID] = newer
        XCTAssertEqual(offline.resumeStart(for: entryID, cachedRevision: revisionID), 40, "a higher epoch still wins")
    }

    func testClearingPositionsClearsTheFile() async throws {
        let first = model()
        first.handoffState.ownPositions[entryID] = try saved(75)
        first.handoffState.ownPositions = [:]

        let offline = model()
        await offline.loadLocalState()
        XCTAssertEqual(offline.resumeStart(for: entryID, cachedRevision: revisionID), 0)
    }

    func testFileRoundTripsAndIsReadableWhileLocked() throws {
        let store = LibraryOwnPositionStore(url: positionsURL)
        store.save(.init(positions: [entryID: try saved(42)], unpublished: [entryID: (position: 42, savedAt: Date(timeIntervalSince1970: 5))]))
        XCTAssertEqual(store.load().positions[entryID]?.record.positionSeconds, 42)
        XCTAssertEqual(store.load().unpublished[entryID]?.position, 42)
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("WiltediOS/Library/LibraryOwnPositionStore.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("LibraryFileProtection.writingOption"), "positions must read while the phone is locked")
    }
}
