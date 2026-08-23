import CryptoKit
import Foundation

/// The immutable description of one byte range in a chunked audio file.
public struct AudioChunkDescriptor: Codable, Equatable, Hashable, Sendable {
    public let identity: String
    public let index: Int
    public let byteCount: Int64
    public let sha256: String

    public init(identity: String, index: Int, byteCount: Int64, sha256: String) throws {
        guard !identity.isEmpty else {
            throw AudioChunkError.invalidManifest("chunk identity must not be empty")
        }
        guard index >= 0 else {
            throw AudioChunkError.invalidManifest("chunk index must not be negative")
        }
        guard byteCount >= 0 else {
            throw AudioChunkError.invalidManifest("chunk byte count must not be negative")
        }
        guard AudioChunking.isSHA256(sha256) else {
            throw AudioChunkError.invalidManifest("chunk SHA-256 must be 64 lowercase hexadecimal characters")
        }
        self.identity = identity
        self.index = index
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: container.decode(String.self, forKey: .identity),
            index: container.decode(Int.self, forKey: .index),
            byteCount: container.decode(Int64.self, forKey: .byteCount),
            sha256: container.decode(String.self, forKey: .sha256)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case identity, index, byteCount, sha256
    }
}

/// The integrity contract for a byte-preserving, ordered audio transfer.
public struct AudioChunkManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumChunkByteCount: Int64 = 45_000_000

    public let schemaVersion: Int
    public let chunkSize: Int64
    public let totalByteCount: Int64
    public let contentSHA256: String
    public let chunks: [AudioChunkDescriptor]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        chunkSize: Int64,
        totalByteCount: Int64,
        contentSHA256: String,
        chunks: [AudioChunkDescriptor]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AudioChunkError.invalidManifest("unsupported schema version \(schemaVersion)")
        }
        guard chunkSize > 0 && chunkSize <= Self.maximumChunkByteCount else {
            throw AudioChunkError.invalidChunkSize(chunkSize)
        }
        guard totalByteCount >= 0 else {
            throw AudioChunkError.invalidManifest("total byte count must not be negative")
        }
        guard AudioChunking.isSHA256(contentSHA256) else {
            throw AudioChunkError.invalidManifest("content SHA-256 must be 64 lowercase hexadecimal characters")
        }
        guard chunks.enumerated().allSatisfy({ $0.element.index == $0.offset }) else {
            throw AudioChunkError.invalidManifest("chunks must be contiguous and ordered")
        }
        guard Set(chunks.map(\.identity)).count == chunks.count else {
            throw AudioChunkError.invalidManifest("chunk identities must be unique")
        }
        guard chunks.allSatisfy({ $0.byteCount <= chunkSize }) else {
            throw AudioChunkError.invalidManifest("chunk exceeds the configured chunk size")
        }
        guard chunks.reduce(Int64.zero, { $0 + $1.byteCount }) == totalByteCount else {
            throw AudioChunkError.invalidManifest("chunk byte counts do not equal total byte count")
        }
        guard totalByteCount == 0 || !chunks.isEmpty else {
            throw AudioChunkError.invalidManifest("non-empty content requires at least one chunk")
        }

        self.schemaVersion = schemaVersion
        self.chunkSize = chunkSize
        self.totalByteCount = totalByteCount
        self.contentSHA256 = contentSHA256
        self.chunks = chunks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            chunkSize: container.decode(Int64.self, forKey: .chunkSize),
            totalByteCount: container.decode(Int64.self, forKey: .totalByteCount),
            contentSHA256: container.decode(String.self, forKey: .contentSHA256),
            chunks: container.decode([AudioChunkDescriptor].self, forKey: .chunks)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, chunkSize, totalByteCount, contentSHA256, chunks
    }
}

/// A manifest and the corresponding ordered opaque byte chunks.
public struct AudioChunkedFile: Equatable, Sendable {
    public let manifest: AudioChunkManifest
    public let chunks: [Data]

    public init(manifest: AudioChunkManifest, chunks: [Data]) throws {
        try manifest.validate(chunks: chunks)
        self.manifest = manifest
        self.chunks = chunks
    }
}

/// Errors raised while validating or reconstructing a chunked audio file.
public enum AudioChunkError: Error, Equatable, Sendable {
    case invalidChunkSize(Int64)
    case invalidManifest(String)
    case chunkCountMismatch(expected: Int, actual: Int)
    case chunkIndexMismatch(expected: Int, actual: Int)
    case chunkByteCountMismatch(index: Int, expected: Int64, actual: Int64)
    case chunkHashMismatch(index: Int)
    case totalByteCountMismatch(expected: Int64, actual: Int64)
    case contentHashMismatch
}

extension AudioChunkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidChunkSize(size): "Invalid chunk size: \(size)"
        case let .invalidManifest(reason): "Invalid chunk manifest: \(reason)"
        case let .chunkCountMismatch(expected, actual): "Expected \(expected) chunks, received \(actual)"
        case let .chunkIndexMismatch(expected, actual): "Expected chunk index \(expected), received \(actual)"
        case let .chunkByteCountMismatch(index, expected, actual):
            "Chunk \(index) has \(actual) bytes, expected \(expected)"
        case let .chunkHashMismatch(index): "Chunk \(index) hash mismatch"
        case let .totalByteCountMismatch(expected, actual):
            "Expected \(expected) total bytes, received \(actual)"
        case .contentHashMismatch: "Reconstructed content hash mismatch"
        }
    }
}

public enum AudioChunking {
    /// Splits opaque bytes without decoding, re-encoding, or changing their order.
    public static func chunk(_ data: Data, chunkSize: Int64 = AudioChunkManifest.maximumChunkByteCount) throws -> AudioChunkedFile {
        guard chunkSize > 0 && chunkSize <= AudioChunkManifest.maximumChunkByteCount else {
            throw AudioChunkError.invalidChunkSize(chunkSize)
        }

        let contentHash = sha256(data)
        var descriptors: [AudioChunkDescriptor] = []
        var chunks: [Data] = []
        var offset = 0
        var index = 0
        let maxChunkSize = Int(chunkSize)
        while offset < data.count {
            let end = min(offset + maxChunkSize, data.count)
            let chunk = Data(data[offset..<end])
            chunks.append(chunk)
            descriptors.append(try AudioChunkDescriptor(
                identity: "chunk-\(index)-\(sha256(chunk))",
                index: index,
                byteCount: Int64(chunk.count),
                sha256: sha256(chunk)
            ))
            offset = end
            index += 1
        }

        let manifest = try AudioChunkManifest(
            chunkSize: chunkSize,
            totalByteCount: Int64(data.count),
            contentSHA256: contentHash,
            chunks: descriptors
        )
        return try AudioChunkedFile(manifest: manifest, chunks: chunks)
    }

    /// Validates count, order, lengths, per-chunk hashes, and the whole-file hash.
    public static func validate(manifest: AudioChunkManifest, chunks: [Data]) throws {
        guard chunks.count == manifest.chunks.count else {
            throw AudioChunkError.chunkCountMismatch(expected: manifest.chunks.count, actual: chunks.count)
        }

        var totalByteCount: Int64 = 0
        for (position, (descriptor, chunk)) in zip(manifest.chunks, chunks).enumerated() {
            guard descriptor.index == position else {
                throw AudioChunkError.chunkIndexMismatch(expected: position, actual: descriptor.index)
            }
            guard descriptor.byteCount == Int64(chunk.count) else {
                throw AudioChunkError.chunkByteCountMismatch(
                    index: position, expected: descriptor.byteCount, actual: Int64(chunk.count)
                )
            }
            guard descriptor.sha256 == sha256(chunk) else {
                throw AudioChunkError.chunkHashMismatch(index: position)
            }
            totalByteCount += Int64(chunk.count)
        }

        guard totalByteCount == manifest.totalByteCount else {
            throw AudioChunkError.totalByteCountMismatch(
                expected: manifest.totalByteCount, actual: totalByteCount
            )
        }
        var content = Data()
        content.reserveCapacity(Int(totalByteCount))
        chunks.forEach { content.append($0) }
        guard sha256(content) == manifest.contentSHA256 else {
            throw AudioChunkError.contentHashMismatch
        }
    }

    public static func reconstruct(manifest: AudioChunkManifest, chunks: [Data]) throws -> Data {
        try validate(manifest: manifest, chunks: chunks)
        var content = Data()
        content.reserveCapacity(Int(manifest.totalByteCount))
        chunks.forEach { content.append($0) }
        return content
    }

    /// Validates all bytes before atomically replacing the destination file.
    public static func reconstruct(manifest: AudioChunkManifest, chunks: [Data], to destinationURL: URL) throws {
        let content = try reconstruct(manifest: manifest, chunks: chunks)
        try content.write(to: destinationURL, options: [.atomic])
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension AudioChunkManifest {
    func validate(chunks: [Data]) throws {
        try AudioChunking.validate(manifest: self, chunks: chunks)
    }
}
