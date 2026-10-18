import CryptoKit
import Foundation
import XCTest
@testable import WiltedLibrary

final class MediaHashTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Several chunks plus a partial one, so the streaming loop is exercised.
    func testBothFormsMatchAOneShotDigestAcrossChunks() throws {
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        let url = directory.appendingPathComponent("audio.m4a")
        try data.write(to: url)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(try MediaHash.sha256Hex(fileAt: url, chunkSize: 4_096), expected)
        XCTAssertEqual(try MediaHash.sha256(fileAt: url, chunkSize: 4_096), MediaHash.prefix + expected)
        XCTAssertTrue(MediaHash.isWellFormed(try MediaHash.sha256(fileAt: url)))
    }

    func testAnEmptyFileHashesToTheEmptyDigest() throws {
        let url = directory.appendingPathComponent("empty.m4a")
        try Data().write(to: url)
        XCTAssertEqual(try MediaHash.sha256Hex(fileAt: url),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAMissingFileThrows() {
        XCTAssertThrowsError(try MediaHash.sha256Hex(fileAt: directory.appendingPathComponent("missing.m4a")))
    }
}
