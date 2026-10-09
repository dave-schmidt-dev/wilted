import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// CarPlay reads the cache, the snapshot and the positions while the phone is locked, so every
/// file it touches must be `completeUntilFirstUserAuthentication` — never a stronger class.
final class LibraryFileProtectionTests: XCTestCase {
    private var scratch: URL!
    private let entryID = try! ItemID(rawValue: "item-a")
    private let revisionID = try! RevisionID(rawValue: "rev-1")

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-file-protection-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    // MARK: source audit

    func testNoScannedSourceRequiresAnUnlockedPhone() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let patterns = [
            "\\.completeFileProtection(?!UntilFirstUserAuthentication)",
            "NSFileProtectionComplete(?!UntilFirstUserAuthentication)",
            "FileProtectionType\\.complete(?!UntilFirstUserAuthentication)",
            "completeFileProtectionUnlessOpen",
            "kSecAttrAccessibleWhenUnlocked",
            "kSecAttrAccessibleWhenPasscodeSet",
        ]
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        let scanned = ["WiltediOS", "WiltedKit/Sources", "CloudSync/Sources", "Shared"]
            .map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        var sources: [URL] = []
        for directory in scanned { sources += try swiftSources(under: directory) }
        XCTAssertFalse(sources.isEmpty, "the audit found nothing to scan; the repo layout changed")

        // This file quotes the patterns as literals, so the scan skips it by name.
        for source in sources where source.lastPathComponent != "LibraryFileProtectionTests.swift" {
            let contents = try String(contentsOf: source, encoding: .utf8)
            for regex in regexes where regex.firstMatch(
                in: contents, range: NSRange(contents.startIndex..., in: contents)) != nil
            {
                XCTFail("\(source.path) contains a protection class that needs an unlocked phone")
            }
        }

        for entitlements in ["WiltediOS/WiltediOS.entitlements", "WiltediOS/WiltediOSProduction.entitlements"] {
            let contents = try String(contentsOf: root.appendingPathComponent(entitlements), encoding: .utf8)
            XCTAssertFalse(
                contents.contains("default-data-protection"),
                "\(entitlements) must not opt into default data protection")
        }
    }

    // MARK: files on disk

    func testAdoptedAudioAndDirectoriesAreReadableWhileLocked() async throws {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let cached = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: try verifiedFile(), for: try offer(), owner: "fixture-owner")

        try assertReadableWhileLocked(cached)
        try assertReadableWhileLocked(cached.deletingLastPathComponent())
        try assertReadableWhileLocked(cached.deletingLastPathComponent().deletingLastPathComponent())
        try assertReadableWhileLocked(cached.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }

    func testAudioCachedBeforeTheFixIsRepairedOnTheFirstListing() async throws {
        let root = scratch.appendingPathComponent("cache")
        let cache = FileMediaCache(rootURL: root)
        let cached = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: try verifiedFile(), for: try offer(), owner: "fixture-owner")
        // A download from an earlier build, left with a class that needs an unlocked phone.
        let stronger: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try? FileManager.default.setAttributes(stronger, ofItemAtPath: cached.path)
        try? FileManager.default.setAttributes(stronger, ofItemAtPath: cached.deletingLastPathComponent().path)

        let fresh = FileMediaCache(rootURL: root)
        let scope = await LibraryAppModel.mediaLibraryScope
        try await fresh.bindOwner(ownerToken: "fixture-owner", libraryScope: scope, held: false)
        let entries = await fresh.cachedEntries()

        XCTAssertEqual(entries[entryID]?.url, cached)
        try assertReadableWhileLocked(cached)
        try assertReadableWhileLocked(cached.deletingLastPathComponent())
    }

    func testUnboundLegacyAudioCanBeDeletedWithoutGrantingAdmissionWithMissingOrCorruptLedger() async throws {
        let scope = await LibraryAppModel.mediaLibraryScope
        for journal in ["missing", "corrupt"] {
            let root = scratch.appendingPathComponent("legacy-\(journal)")
            let directory = root.appendingPathComponent(entryID.rawValue)
                .appendingPathComponent(revisionID.rawValue)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bytes = Data((0..<64).map { UInt8($0 % 251) })
            let audio = directory.appendingPathComponent(String(hash(bytes).dropFirst(MediaHash.prefix.count)) + ".m4a")
            try bytes.write(to: audio)
            if journal == "corrupt" {
                try Data("invalid ledger".utf8).write(to: root.appendingPathComponent(".preparation-ledger.json"))
            }
            let cache = FileMediaCache(rootURL: root)
            let before = await cache.admission(entryID: entryID, ownerToken: "fixture-owner",
                libraryScope: scope, transportGeneration: 0)
            XCTAssertNil(before, "Legacy bytes do not grant permission")
            do { try await cache.remove(entryID: entryID) }
            catch { XCTFail("Deleting unbound \(journal)-ledger legacy audio must not require admission: \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), "Explicit deletion removes legacy bytes")
            let after = await cache.admission(entryID: entryID, ownerToken: "fixture-owner",
                libraryScope: scope, transportGeneration: 0)
            XCTAssertNil(after, "Deletion must not bind an owner or grant permission")
            let inventory = await cache.cachedEntries()
            XCTAssertTrue(inventory.isEmpty)
        }
    }

    func testFailedValidJournalWithdrawalKeepsAudioAndCannotFallBackToLegacyDeletion() async throws {
        let root = scratch.appendingPathComponent("valid-journal-failure")
        let cache = FileMediaCache(rootURL: root)
        let audio = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: try verifiedFile(),
            for: try offer(), owner: "fixture-owner")
        let scope = await LibraryAppModel.mediaLibraryScope
        let before = await cache.admission(entryID: entryID, ownerToken: "fixture-owner",
            libraryScope: scope, transportGeneration: 0)
        XCTAssertNotNil(before, "The fault starts after a valid journal and admission exist")
        let journal = root.appendingPathComponent(".preparation-ledger.json")
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        for attempt in 1...2 {
            do {
                try await cache.remove(entryID: entryID)
                XCTFail("Valid journal withdrawal failure must block deletion on attempt \(attempt)")
            } catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "Failed durable withdrawal preserves audio")
            let issued = await cache.admission(entryID: entryID, ownerToken: "fixture-owner",
                libraryScope: scope, transportGeneration: 0)
            XCTAssertNil(issued, "A failed valid journal cannot issue another admission")
            let inventory = await cache.cachedEntries()
            XCTAssertTrue(inventory.isEmpty)
        }
        let reopened = FileMediaCache(rootURL: root)
        do {
            try await reopened.bindOwner(ownerToken: "fixture-owner", libraryScope: scope, held: false)
            XCTFail("The persisted journal fault must remain closed after relaunch")
        } catch {}
        let restored = await reopened.cachedEntries()
        XCTAssertTrue(restored.isEmpty)
        let restoredAdmission = await reopened.admission(entryID: entryID, ownerToken: "fixture-owner",
            libraryScope: scope, transportGeneration: 0)
        XCTAssertNil(restoredAdmission)
    }

    func testPhysicalStorageCountsLegacyAndRevokedRevisionsWithoutAdmittingUnsafeFiles() async throws {
        let root = scratch.appendingPathComponent("physical-cache")
        let cache = FileMediaCache(rootURL: root)
        let certifiedURL = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: try verifiedFile(),
            for: try offer(), owner: "fixture-owner")
        let certified = await cache.cachedEntries()
        let prior = try XCTUnwrap(certified[entryID])
        try await cache.revokePreparation(entryID: entryID)
        let revoked = await cache.cachedEntries()
        XCTAssertTrue(revoked.isEmpty)
        let verified = await cache.verifies(prior)
        XCTAssertFalse(verified)

        func legacy(_ entry: String, _ revision: String, bytes: Int) throws -> URL {
            let directory = root.appendingPathComponent(entry).appendingPathComponent(revision)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = Data(repeating: 19, count: bytes)
            let file = directory.appendingPathComponent(String(hash(data).dropFirst(MediaHash.prefix.count)) + ".m4a")
            try data.write(to: file)
            return file
        }
        let second = try legacy(entryID.rawValue, "rev-2", bytes: 3)
        let third = try legacy(entryID.rawValue, "rev-3", bytes: 5)
        _ = try legacy("other", "rev-1", bytes: 17)
        _ = try legacy("invalid entry", "rev-1", bytes: 100)
        _ = try legacy(entryID.rawValue, "invalid revision", bytes: 100)
        let revision = certifiedURL.deletingLastPathComponent()
        try Data(repeating: 9, count: 100).write(to: revision.appendingPathComponent("not-a-hash.m4a"))
        try Data(repeating: 9, count: 100).write(to: revision.appendingPathComponent(String(repeating: "a", count: 64) + ".txt"))
        try Data(repeating: 9, count: 100).write(to: revision.appendingPathComponent(FileMediaCache.transcriptFileName))
        let outside = scratch.appendingPathComponent("outside-audio")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent(String(repeating: "b", count: 64) + ".m4a")
        try Data(repeating: 2, count: 1_000).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(atPath: revision.appendingPathComponent(String(repeating: "c", count: 64) + ".m4a").path,
            withDestinationPath: outsideFile.path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(entryID.rawValue).appendingPathComponent("linked-revision").path,
            withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked-entry").path,
            withDestinationPath: root.appendingPathComponent(entryID.rawValue).path)
        let counts = await cache.storedAudioByteCounts()
        XCTAssertEqual(counts, [entryID: 72, try ItemID(rawValue: "other"): 17], "every retained revision counts; unsafe and nonaudio paths do not")
        XCTAssertTrue(FileManager.default.fileExists(atPath: certifiedURL.path))
        XCTAssertEqual(try Data(contentsOf: second), Data(repeating: 19, count: 3))
        XCTAssertEqual(try Data(contentsOf: third), Data(repeating: 19, count: 5))
        let afterCounting = await cache.cachedEntries()
        XCTAssertTrue(afterCounting.isEmpty, "physical accounting does not restore revoked or legacy proof")

        let reopened = FileMediaCache(rootURL: root)
        let unboundCounts = await reopened.storedAudioByteCounts()
        XCTAssertEqual(unboundCounts, counts)
        let unboundInventory = await reopened.cachedEntries()
        XCTAssertTrue(unboundInventory.isEmpty)
        let unboundAdmission = await reopened.admission(entryID: entryID, ownerToken: "fixture-owner",
            libraryScope: await LibraryAppModel.mediaLibraryScope, transportGeneration: 0)
        XCTAssertNil(unboundAdmission, "accounting cannot confirm the stored owner")
        let linkedRoot = scratch.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(atPath: linkedRoot.path, withDestinationPath: root.path)
        let linkedCounts = await FileMediaCache(rootURL: linkedRoot).storedAudioByteCounts()
        XCTAssertTrue(linkedCounts.isEmpty)
    }

    func testTranscriptAndLibrarySnapshotAreWrittenReadableWhileLocked() async throws {
        let cacheRoot = scratch.appendingPathComponent("cache")
        let cache = FileMediaCache(rootURL: cacheRoot)
        _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: try verifiedFile(), for: try offer(), owner: "fixture-owner")

        let transcript = try LibraryTranscript(
            entryID: entryID, revisionID: revisionID, cues: [LibraryTranscriptCue(start: 0, end: 2, text: "Hello")])
        await cache.storeTranscript(transcript)
        let transcriptURL = cacheRoot
            .appendingPathComponent(entryID.rawValue, isDirectory: true)
            .appendingPathComponent(revisionID.rawValue, isDirectory: true)
            .appendingPathComponent(FileMediaCache.transcriptFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))
        try assertReadableWhileLocked(transcriptURL)

        let storeURL = scratch.appendingPathComponent("library-state.json")
        let store = FileLibraryStore(url: storeURL)
        let prior = await store.state()
        let transport = InMemoryLibraryTransport(deviceID: "phone", server: InMemoryLibraryServer(writerDeviceID: "mac"),
            verifiedOwnerToken: "test-owner")
        let batch = try await transport.fetchChanges(since: nil)
        try await store.commit(StagedLibraryBatch(batch: batch, priorState: prior, nextState: prior),
            transport: transport, expectedGeneration: 0)
        try assertReadableWhileLocked(storeURL)
    }

    // MARK: fixtures

    private func hash(_ data: Data) -> String {
        MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func offer() throws -> LibraryMediaOffer {
        try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash(Data((0..<64).map { UInt8($0 % 251) })),
            byteCount: 64, mediaType: "audio/mp4"))
    }

    private func verifiedFile() throws -> URL {
        let url = scratch.appendingPathComponent("verified")
        try Data((0..<64).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    /// Fails unless `url` carries no reported protection class or the one CarPlay can read while
    /// locked; the simulator does not always report the attribute, which is why nil passes.
    private func assertReadableWhileLocked(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let reported = attributes[.protectionKey] else { return }
        let readable: Bool
        if let type = reported as? FileProtectionType {
            readable = type == .completeUntilFirstUserAuthentication
        } else if let raw = reported as? String {
            readable = raw == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        } else {
            readable = false
        }
        XCTAssertTrue(readable, "\(url.path) is protected with \(reported) and would be unreadable while locked")
    }

    private func swiftSources(under directory: URL) throws -> [URL] {
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        var found: [URL] = []
        for child in children {
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                found += try swiftSources(under: child)
            } else if child.pathExtension == "swift" {
                found.append(child)
            }
        }
        return found
    }
}
