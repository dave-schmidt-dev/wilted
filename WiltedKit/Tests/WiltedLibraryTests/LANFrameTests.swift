import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// The LAN wire format: strict, length-capped, and refusing anything the Mac or phone would not send.
final class LANFrameTests: XCTestCase {
    private func request(
        byteCount: Int64 = 1_000, offset: Int64 = 0, version: UInt8 = LANFrameCodec.version
    ) throws -> LANMediaRequest {
        LANMediaRequest(
            entryID: try ItemID(rawValue: "ep-1"), revisionID: try RevisionID(rawValue: "rev-1"),
            contentHash: "sha256:" + String(repeating: "ab", count: 32), byteCount: byteCount, offset: offset, version: version)
    }

    private func header(
        status: LANMediaHeader.Status = .ok, byteCount: Int64 = 1_000, version: UInt8 = LANFrameCodec.version
    ) throws -> LANMediaHeader {
        LANMediaHeader(
            status: status, revisionID: try RevisionID(rawValue: "rev-1"),
            contentHash: "sha256:" + String(repeating: "cd", count: 32), byteCount: byteCount, version: version)
    }

    /// A frame around `payload` with a correct length prefix, for building malformed payloads.
    private func framed(_ payload: [UInt8]) -> Data {
        Data(LANFrameCodec.bigEndian32(UInt32(payload.count)) + payload)
    }

    // MARK: round trips

    func testARequestRoundTrips() throws {
        let original = try request(byteCount: 123_456_789, offset: 4_096)
        let decoded = try LANMediaRequest.decode(frame: original.encoded())
        XCTAssertEqual(decoded, original)
    }

    func testEveryHeaderStatusRoundTrips() throws {
        for status in LANMediaHeader.Status.allCases {
            let original = try header(status: status, byteCount: status == .ok ? 77 : 0)
            XCTAssertEqual(try LANMediaHeader.decode(frame: original.encoded()), original, "\(status)")
        }
    }

    func testTheDeclaredLengthAndTheLimitsAreTheDocumentedOnes() throws {
        let frame = try request().encoded()
        XCTAssertEqual(try LANFrameCodec.payloadLength(prefix: frame), frame.count - LANFrameCodec.prefixBytes)
        XCTAssertEqual(LANFrameCodec.maximumFrameBytes, 4096)
        XCTAssertEqual(LANFrameCodec.maximumByteCount, 250 * 1024 * 1024)
        XCTAssertEqual(try request(byteCount: LANFrameCodec.maximumByteCount, offset: LANFrameCodec.maximumByteCount).encoded().isEmpty, false)
    }

    // MARK: refused frames

    func testAnOversizeDeclaredLengthIsRefusedBeforeTheBodyIsRead() throws {
        let prefixOnly = Data(LANFrameCodec.bigEndian32(UInt32(LANFrameCodec.maximumFrameBytes + 1)))
        XCTAssertThrowsError(try LANFrameCodec.payloadLength(prefix: prefixOnly)) {
            XCTAssertEqual($0 as? LANFrameError, .oversize)
        }
        let huge = Data(LANFrameCodec.bigEndian32(UInt32.max))
        XCTAssertThrowsError(try LANMediaRequest.decode(frame: huge)) { XCTAssertEqual($0 as? LANFrameError, .oversize) }
        XCTAssertThrowsError(try LANMediaHeader.decode(frame: huge)) { XCTAssertEqual($0 as? LANFrameError, .oversize) }
    }

    func testBytesAfterTheFrameAreRefused() throws {
        var frame = try request().encoded()
        frame.append(0)
        XCTAssertThrowsError(try LANMediaRequest.decode(frame: frame)) { XCTAssertEqual($0 as? LANFrameError, .oversize) }
        var inner = Array(try request().encoded().dropFirst(4))
        inner.append(0)
        XCTAssertThrowsError(try LANMediaRequest.decode(frame: framed(inner)), "extra payload bytes") {
            XCTAssertEqual($0 as? LANFrameError, .oversize)
        }
    }

    func testEveryTruncationIsRefused() throws {
        let frame = try request().encoded()
        for length in 0..<frame.count {
            XCTAssertThrowsError(try LANMediaRequest.decode(frame: frame.prefix(length)), "request cut at \(length)") {
                XCTAssertEqual($0 as? LANFrameError, .truncated)
            }
        }
        let answer = try header().encoded()
        for length in 0..<answer.count {
            XCTAssertThrowsError(try LANMediaHeader.decode(frame: answer.prefix(length)), "header cut at \(length)")
        }
        // A prefix that is right about a payload that is itself cut short.
        let payload = Array(frame.dropFirst(4))
        for length in 0..<payload.count {
            XCTAssertThrowsError(try LANMediaRequest.decode(frame: framed(Array(payload.prefix(length)))), "payload cut at \(length)")
        }
    }

    func testAWrongVersionIsRefused() throws {
        for version: UInt8 in [0, 2, 255] {
            XCTAssertThrowsError(try request(version: version).encoded()) {
                XCTAssertEqual($0 as? LANFrameError, .wrongVersion(version))
            }
            var bytes = Array(try request().encoded().dropFirst(4))
            bytes[0] = version
            XCTAssertThrowsError(try LANMediaRequest.decode(frame: framed(bytes))) {
                XCTAssertEqual($0 as? LANFrameError, .wrongVersion(version))
            }
            var answer = Array(try header().encoded().dropFirst(4))
            answer[0] = version
            XCTAssertThrowsError(try LANMediaHeader.decode(frame: framed(answer))) {
                XCTAssertEqual($0 as? LANFrameError, .wrongVersion(version))
            }
        }
    }

    func testAnOffsetThatIsNegativeOrPastTheLengthIsRefused() throws {
        for offset: Int64 in [-1, Int64.min, 1_001, Int64.max] {
            XCTAssertThrowsError(try request(byteCount: 1_000, offset: offset).encoded(), "encode \(offset)") {
                XCTAssertEqual($0 as? LANFrameError, .invalidOffset)
            }
            // Decode a hand-built frame: the encoder would not produce it.
            XCTAssertThrowsError(try LANMediaRequest.decode(frame: rawRequest(byteCount: 1_000, offset: offset)), "decode \(offset)") {
                XCTAssertEqual($0 as? LANFrameError, .invalidOffset)
            }
        }
        XCTAssertNoThrow(try LANMediaRequest.decode(frame: rawRequest(byteCount: 1_000, offset: 1_000)), "an offset at the end is a complete file")
        XCTAssertNoThrow(try LANMediaRequest.decode(frame: rawRequest(byteCount: 1_000, offset: 0)))
    }

    func testAByteCountOverTheCapOrNotPositiveIsRefused() throws {
        for count: Int64 in [-1, 0, LANFrameCodec.maximumByteCount + 1, Int64.max] {
            XCTAssertThrowsError(try LANMediaRequest.decode(frame: rawRequest(byteCount: count, offset: 0)), "\(count)") {
                XCTAssertEqual($0 as? LANFrameError, .invalidByteCount)
            }
        }
        XCTAssertThrowsError(try header(byteCount: LANFrameCodec.maximumByteCount + 1).encoded())
        XCTAssertThrowsError(try header(byteCount: -1).encoded())
        XCTAssertThrowsError(try header(status: .ok, byteCount: 0).encoded(), "an ok header promises bytes")
    }

    func testAnUnknownStatusAndBadFieldsAreRefused() throws {
        var answer = Array(try header().encoded().dropFirst(4))
        answer[1] = 9
        XCTAssertThrowsError(try LANMediaHeader.decode(frame: framed(answer))) { XCTAssertEqual($0 as? LANFrameError, .invalidStatus(9)) }

        // An empty entry ID, an identifier with a space, and bytes that are not UTF-8.
        for entry in [[UInt8](), Array("bad id".utf8), [0xFF, 0xFE]] {
            XCTAssertThrowsError(try LANMediaRequest.decode(frame: rawRequest(entry: entry, byteCount: 10, offset: 0)))
        }
        XCTAssertThrowsError(try request().withHash(String(repeating: "a", count: 300)).encoded()) {
            XCTAssertEqual($0 as? LANFrameError, .invalidField)
        }
    }

    // MARK: helpers

    private func rawRequest(entry: [UInt8] = Array("ep-1".utf8), byteCount: Int64, offset: Int64) -> Data {
        func string(_ bytes: [UInt8]) -> [UInt8] { [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes }
        func int64(_ value: Int64) -> [UInt8] {
            let bits = UInt64(bitPattern: value)
            return stride(from: 56, through: 0, by: -8).map { UInt8(bits >> UInt64($0) & 0xFF) }
        }
        let payload = [LANFrameCodec.version] + string(entry) + string(Array("rev-1".utf8)) + string(Array("sha256:00".utf8))
            + int64(byteCount) + int64(offset)
        return framed(payload)
    }

    func testTheServerKeepsOnlyTheMostRecentTransferRecords() {
        var records: [LANMediaServer.TransferRecord] = []
        for sent in 0 ... Int64(LANMediaServer.recordLimit) {
            records = LANMediaServer.appending(.init(request: nil, status: nil, bytesSent: sent), to: records)
        }
        XCTAssertEqual(records.count, LANMediaServer.recordLimit)
        XCTAssertEqual(records.first?.bytesSent, 1, "the oldest record is dropped")
        XCTAssertEqual(records.last?.bytesSent, Int64(LANMediaServer.recordLimit))
    }
}

private extension LANMediaRequest {
    func withHash(_ hash: String) -> LANMediaRequest {
        LANMediaRequest(entryID: entryID, revisionID: revisionID, contentHash: hash, byteCount: byteCount, offset: offset, version: version)
    }
}
