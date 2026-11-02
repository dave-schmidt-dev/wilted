import Foundation
import WiltedDomain

/// Why a LAN frame was refused. Every decode failure ends the connection; none is recoverable.
public enum LANFrameError: Error, Equatable, Sendable {
    /// The frame, or the four-byte length prefix, ended before its declared length.
    case truncated
    /// The declared length is over `LANFrameCodec.maximumFrameBytes`, or more bytes follow the frame.
    case oversize
    case wrongVersion(UInt8)
    /// A field is empty, too long, not valid text, or fails its identifier rules.
    case invalidField
    case invalidStatus(UInt8)
    /// `byteCount` is negative or over `LANFrameCodec.maximumByteCount`.
    case invalidByteCount
    /// `offset` is negative or past `byteCount`.
    case invalidOffset
}

/// The shared limits and primitives of the LAN wire format (v1). Frames are a four-byte big-endian
/// payload length, then the payload; audio bytes follow an `ok` header unframed.
public enum LANFrameCodec {
    public static let version: UInt8 = 1
    /// Header frames are tiny; anything bigger is a confused or hostile peer, refused before it is read.
    public static let maximumFrameBytes = 4096
    /// The same cap the Mac enforces on prepared audio (`WiltedMacMediaService.maximumByteCount`).
    public static let maximumByteCount: Int64 = 250 * 1024 * 1024
    public static let prefixBytes = 4
    static let maximumFieldBytes = 256

    /// The payload length a four-byte prefix declares, checked against the cap before any body is read.
    public static func payloadLength(prefix: Data) throws -> Int {
        guard prefix.count >= prefixBytes else { throw LANFrameError.truncated }
        let length = prefix.prefix(prefixBytes).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard length <= UInt32(maximumFrameBytes) else { throw LANFrameError.oversize }
        return Int(length)
    }

    static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maximumFrameBytes else { throw LANFrameError.oversize }
        var out = Data()
        out.append(contentsOf: bigEndian32(UInt32(payload.count)))
        out.append(payload)
        return out
    }

    /// The payload of one complete frame: exactly the prefix and the bytes it declares.
    static func payload(of frame: Data) throws -> Data {
        let frame = Data(frame)
        let length = try payloadLength(prefix: frame)
        let available = frame.count - prefixBytes
        guard available >= length else { throw LANFrameError.truncated }
        guard available == length else { throw LANFrameError.oversize }
        return Data(frame.suffix(length))
    }

    static func bigEndian32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

/// Reads fields off a payload, failing on any shortfall.
struct LANFrameReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ payload: Data) { bytes = Array(payload) }

    var isAtEnd: Bool { position == bytes.count }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw LANFrameError.truncated }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func int64() throws -> Int64 {
        guard bytes.count - position >= 8 else { throw LANFrameError.truncated }
        let value = bytes[position..<position + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        position += 8
        return Int64(bitPattern: value)
    }

    mutating func string() throws -> String {
        let high = try byte(), low = try byte()
        let length = Int(high) << 8 | Int(low)
        guard length > 0, length <= LANFrameCodec.maximumFieldBytes else { throw LANFrameError.invalidField }
        guard bytes.count - position >= length else { throw LANFrameError.truncated }
        defer { position += length }
        guard let text = String(bytes: bytes[position..<position + length], encoding: .utf8) else {
            throw LANFrameError.invalidField
        }
        return text
    }
}

/// Appends fields to a payload.
struct LANFrameWriter {
    private(set) var data = Data()

    mutating func byte(_ value: UInt8) { data.append(value) }

    mutating func int64(_ value: Int64) {
        let bits = UInt64(bitPattern: value)
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(bits >> UInt64(shift) & 0xFF)) }
    }

    mutating func string(_ value: String) throws {
        let utf8 = Data(value.utf8)
        guard !utf8.isEmpty, utf8.count <= LANFrameCodec.maximumFieldBytes else { throw LANFrameError.invalidField }
        data.append(UInt8(utf8.count >> 8))
        data.append(UInt8(utf8.count & 0xFF))
        data.append(utf8)
    }
}

/// Phone to Mac: asks for the bytes of one prepared revision, from `offset` (a resumed partial file).
public struct LANMediaRequest: Equatable, Sendable {
    public let version: UInt8
    public let entryID: ItemID
    public let revisionID: RevisionID
    public let contentHash: String
    public let byteCount: Int64
    public let offset: Int64

    public init(
        entryID: ItemID, revisionID: RevisionID, contentHash: String, byteCount: Int64, offset: Int64,
        version: UInt8 = LANFrameCodec.version
    ) {
        self.version = version
        self.entryID = entryID
        self.revisionID = revisionID
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.offset = offset
    }

    /// The complete frame, length prefix included. Throws for a request the Mac would refuse.
    public func encoded() throws -> Data {
        try validate()
        var writer = LANFrameWriter()
        writer.byte(version)
        try writer.string(entryID.rawValue)
        try writer.string(revisionID.rawValue)
        try writer.string(contentHash)
        writer.int64(byteCount)
        writer.int64(offset)
        return try LANFrameCodec.frame(writer.data)
    }

    /// Decodes one complete frame, strictly: nothing is guessed, defaulted or skipped.
    public static func decode(frame: Data) throws -> LANMediaRequest {
        var reader = LANFrameReader(try LANFrameCodec.payload(of: frame))
        let version = try reader.byte()
        guard version == LANFrameCodec.version else { throw LANFrameError.wrongVersion(version) }
        let entry = try reader.string(), revision = try reader.string(), hash = try reader.string()
        let byteCount = try reader.int64(), offset = try reader.int64()
        guard reader.isAtEnd else { throw LANFrameError.oversize }
        guard let entryID = try? ItemID(rawValue: entry), let revisionID = try? RevisionID(rawValue: revision) else {
            throw LANFrameError.invalidField
        }
        let request = LANMediaRequest(
            entryID: entryID, revisionID: revisionID, contentHash: hash, byteCount: byteCount, offset: offset,
            version: version)
        try request.validate()
        return request
    }

    private func validate() throws {
        guard version == LANFrameCodec.version else { throw LANFrameError.wrongVersion(version) }
        guard byteCount > 0, byteCount <= LANFrameCodec.maximumByteCount else { throw LANFrameError.invalidByteCount }
        guard offset >= 0, offset <= byteCount else { throw LANFrameError.invalidOffset }
    }
}

/// Mac to phone: the answer to a `LANMediaRequest`. After an `ok` header the Mac sends the raw bytes from
/// the requested offset to `byteCount`, then closes the connection.
public struct LANMediaHeader: Equatable, Sendable {
    public enum Status: UInt8, Sendable, CaseIterable {
        case ok = 0
        /// The Mac has no prepared audio for the entry yet.
        case notReady = 1
        /// The Mac's ready revision is not the one asked for.
        case different = 2
        case busy = 3
        case refused = 4
    }

    public let version: UInt8
    public let status: Status
    public let revisionID: RevisionID
    public let contentHash: String
    public let byteCount: Int64

    public init(
        status: Status, revisionID: RevisionID, contentHash: String, byteCount: Int64,
        version: UInt8 = LANFrameCodec.version
    ) {
        self.version = version
        self.status = status
        self.revisionID = revisionID
        self.contentHash = contentHash
        self.byteCount = byteCount
    }

    /// The complete frame, length prefix included.
    public func encoded() throws -> Data {
        try validate()
        var writer = LANFrameWriter()
        writer.byte(version)
        writer.byte(status.rawValue)
        try writer.string(revisionID.rawValue)
        try writer.string(contentHash)
        writer.int64(byteCount)
        return try LANFrameCodec.frame(writer.data)
    }

    /// Decodes one complete frame, strictly.
    public static func decode(frame: Data) throws -> LANMediaHeader {
        var reader = LANFrameReader(try LANFrameCodec.payload(of: frame))
        let version = try reader.byte()
        guard version == LANFrameCodec.version else { throw LANFrameError.wrongVersion(version) }
        let rawStatus = try reader.byte()
        guard let status = Status(rawValue: rawStatus) else { throw LANFrameError.invalidStatus(rawStatus) }
        let revision = try reader.string(), hash = try reader.string()
        let byteCount = try reader.int64()
        guard reader.isAtEnd else { throw LANFrameError.oversize }
        guard let revisionID = try? RevisionID(rawValue: revision) else { throw LANFrameError.invalidField }
        let header = LANMediaHeader(
            status: status, revisionID: revisionID, contentHash: hash, byteCount: byteCount, version: version)
        try header.validate()
        return header
    }

    private func validate() throws {
        guard version == LANFrameCodec.version else { throw LANFrameError.wrongVersion(version) }
        guard byteCount >= 0, byteCount <= LANFrameCodec.maximumByteCount else { throw LANFrameError.invalidByteCount }
        guard status != .ok || byteCount > 0 else { throw LANFrameError.invalidByteCount }
    }
}
