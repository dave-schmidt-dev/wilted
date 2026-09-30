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
        let cached = try await cache.adopt(verifiedFile: try verifiedFile(), for: try offer())

        try assertReadableWhileLocked(cached)
        try assertReadableWhileLocked(cached.deletingLastPathComponent())
        try assertReadableWhileLocked(cached.deletingLastPathComponent().deletingLastPathComponent())
        try assertReadableWhileLocked(cached.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }

    func testAudioCachedBeforeTheFixIsRepairedOnTheFirstListing() async throws {
        let root = scratch.appendingPathComponent("cache")
        let cache = FileMediaCache(rootURL: root)
        let cached = try await cache.adopt(verifiedFile: try verifiedFile(), for: try offer())
        // A download from an earlier build, left with a class that needs an unlocked phone.
        let stronger: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        try? FileManager.default.setAttributes(stronger, ofItemAtPath: cached.path)
        try? FileManager.default.setAttributes(stronger, ofItemAtPath: cached.deletingLastPathComponent().path)

        let fresh = FileMediaCache(rootURL: root)
        let entries = await fresh.cachedEntries()

        XCTAssertEqual(entries[entryID]?.url, cached)
        try assertReadableWhileLocked(cached)
        try assertReadableWhileLocked(cached.deletingLastPathComponent())
    }

    func testTranscriptAndLibrarySnapshotAreWrittenReadableWhileLocked() async throws {
        let cacheRoot = scratch.appendingPathComponent("cache")
        let cache = FileMediaCache(rootURL: cacheRoot)
        _ = try await cache.adopt(verifiedFile: try verifiedFile(), for: try offer())

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
        try await store.commit(StagedLibraryBatch(
            batch: LibraryChangeBatch(generationID: "g1", changes: [], token: nil),
            priorState: prior, nextState: prior))
        try assertReadableWhileLocked(storeURL)
    }

    // MARK: fixtures

    private func hash(_ data: Data) -> String {
        MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func offer() throws -> LibraryMediaOffer {
        try LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash(Data((0..<64).map { UInt8($0 % 251) })),
            byteCount: 64, mediaType: "audio/mp4")
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
