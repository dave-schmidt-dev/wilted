import Foundation
import XCTest
@testable import WiltedDomain

final class AudioChunkingTests: XCTestCase {
    func testChunkingPreservesBytesAndProducesStableManifest() throws {
        let input = Data((0..<251).map { UInt8($0) })
        let first = try AudioChunking.chunk(input, chunkSize: 100)
        let second = try AudioChunking.chunk(input, chunkSize: 100)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try AudioChunking.reconstruct(manifest: first.manifest, chunks: first.chunks), input)
        XCTAssertEqual(first.manifest.chunks.map(\.index), [0, 1, 2])
        XCTAssertEqual(first.manifest.chunks.map(\.byteCount), [100, 100, 51])
        XCTAssertEqual(first.manifest.chunks.map(\.identity).count, Set(first.manifest.chunks.map(\.identity)).count)
        XCTAssertEqual(try JSONDecoder().decode(AudioChunkManifest.self, from: JSONEncoder().encode(first.manifest)), first.manifest)
    }

    func testEmptyAndSmallInputsAreValid() throws {
        let empty = try AudioChunking.chunk(Data(), chunkSize: 10)
        XCTAssertTrue(empty.chunks.isEmpty)
        XCTAssertEqual(empty.manifest.totalByteCount, 0)
        XCTAssertEqual(try AudioChunking.reconstruct(manifest: empty.manifest, chunks: empty.chunks), Data())

        let small = try AudioChunking.chunk(Data([1, 2, 3]), chunkSize: 10)
        XCTAssertEqual(small.chunks, [Data([1, 2, 3])])
    }

    func testMaximumBoundarySplitsOnlyWhenNeeded() throws {
        let atBoundary = try AudioChunking.chunk(Data(repeating: 7, count: Int(AudioChunkManifest.maximumChunkByteCount)))
        XCTAssertEqual(atBoundary.chunks.count, 1)
        XCTAssertEqual(atBoundary.chunks[0].count, Int(AudioChunkManifest.maximumChunkByteCount))

        let overBoundary = try AudioChunking.chunk(Data(repeating: 7, count: Int(AudioChunkManifest.maximumChunkByteCount) + 1))
        XCTAssertEqual(overBoundary.chunks.map(\.count), [Int(AudioChunkManifest.maximumChunkByteCount), 1])
    }

    func testRejectsInvalidChunkSize() {
        XCTAssertThrowsError(try AudioChunking.chunk(Data([1]), chunkSize: 0)) { error in
            XCTAssertEqual(error as? AudioChunkError, .invalidChunkSize(0))
        }
        XCTAssertThrowsError(try AudioChunking.chunk(Data([1]), chunkSize: AudioChunkManifest.maximumChunkByteCount + 1))
    }

    func testRejectsMissingOutOfOrderAndCorruptChunks() throws {
        let file = try AudioChunking.chunk(Data((0..<10).map { UInt8($0) }), chunkSize: 4)

        XCTAssertThrowsError(try file.manifest.validate(chunks: Array(file.chunks.dropLast()))) { error in
            XCTAssertEqual(error as? AudioChunkError, .chunkCountMismatch(expected: 3, actual: 2))
        }

        var outOfOrder = file.chunks
        outOfOrder.swapAt(0, 1)
        XCTAssertThrowsError(try file.manifest.validate(chunks: outOfOrder)) { error in
            XCTAssertEqual(error as? AudioChunkError, .chunkHashMismatch(index: 0))
        }

        var corrupt = file.chunks
        corrupt[1][0] ^= 0xff
        XCTAssertThrowsError(try file.manifest.validate(chunks: corrupt)) { error in
            XCTAssertEqual(error as? AudioChunkError, .chunkHashMismatch(index: 1))
        }
    }

    func testFailedAtomicReconstructionLeavesDestinationUnchanged() throws {
        let file = try AudioChunking.chunk(Data([1, 2, 3, 4, 5]), chunkSize: 2)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data([99, 98]).write(to: destination)

        var corrupt = file.chunks
        corrupt[0][0] ^= 0xff
        XCTAssertThrowsError(try AudioChunking.reconstruct(manifest: file.manifest, chunks: corrupt, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data([99, 98]))

        try AudioChunking.reconstruct(manifest: file.manifest, chunks: file.chunks, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3, 4, 5]))
    }
}
