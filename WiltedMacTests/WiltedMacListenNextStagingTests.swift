import Foundation
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacListenNextStagingTests: XCTestCase {
    private let deviceID = "staging-mac"
    private let owner = "staging-owner"

    func testStartupSweepRemovesOnlyAbandonedScopedStaging() throws {
        let directory = wiltedTemporaryDirectory("listen-next-staging-sweep")
        let staging = WiltedMacListenNextStaging(directory: directory, coordinatorDeviceID: deviceID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let orphan = try writeStagingFile(
            staging, ownerToken: owner, requesterDeviceID: "phone-1", requestID: "orphan",
            operationGeneration: 8, taskID: UUID(), bytes: Data("orphan".utf8))
        let foreignOwner = try writeStagingFile(
            staging, ownerToken: "another-owner", requesterDeviceID: "phone-1", requestID: "foreign",
            operationGeneration: 8, taskID: UUID(), bytes: Data("foreign".utf8))
        let active = try staging.acquire(
            ownerToken: owner, operationGeneration: 9, requesterDeviceID: "phone-1",
            requestID: "active", taskID: UUID())
        defer { active.finish() }
        try Data("active".utf8).write(to: active.stagingURL)

        let finalAudio = directory.appendingPathComponent("listen-next-final.m4a")
        try Data("ready audio".utf8).write(to: finalAudio)

        XCTAssertTrue(staging.sweepAbandoned(ownerToken: owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leaseURL(for: orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignOwner.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: leaseURL(for: foreignOwner).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.stagingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.leaseURL.path))
        XCTAssertEqual(try Data(contentsOf: finalAudio), Data("ready audio".utf8))
    }

    private func writeStagingFile(
        _ staging: WiltedMacListenNextStaging,
        ownerToken: String,
        requesterDeviceID: String,
        requestID: String,
        operationGeneration: UInt64,
        taskID: UUID,
        bytes: Data
    ) throws -> URL {
        let metadata = WiltedMacListenNextStaging.LeaseMetadata(
            coordinatorDeviceID: deviceID, ownerToken: ownerToken,
            operationGeneration: operationGeneration, requesterDeviceID: requesterDeviceID,
            requestID: requestID, taskID: taskID)
        let url = staging.stagingURL(
            ownerToken: ownerToken, operationGeneration: operationGeneration,
            requesterDeviceID: requesterDeviceID, requestID: requestID, taskID: taskID)
        try bytes.write(to: url)
        try JSONEncoder().encode(metadata).write(to: leaseURL(for: url))
        return url
    }

    private func leaseURL(for stagingURL: URL) -> URL {
        URL(fileURLWithPath: stagingURL.path + ".lease")
    }
}
