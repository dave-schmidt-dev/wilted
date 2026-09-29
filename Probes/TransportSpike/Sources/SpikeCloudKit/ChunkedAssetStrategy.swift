import CloudKit
import Foundation
import SpikeCore

/// Splits a byte count into fixed-size chunks. Pure arithmetic, so it is testable without CloudKit.
public struct ChunkPlan: Equatable, Sendable {
    public struct Chunk: Equatable, Sendable {
        public let index: Int
        public let offset: Int64
        public let length: Int64
    }

    /// 45 MB, using the same 1_048_576-byte megabyte as the payload sizes under test.
    public static let defaultChunkBytes: Int64 = 45 * 1_048_576

    public let byteCount: Int64
    public let chunkBytes: Int64
    public let chunks: [Chunk]

    public init(byteCount: Int64, chunkBytes: Int64 = ChunkPlan.defaultChunkBytes) {
        let size = max(1, chunkBytes)
        var chunks: [Chunk] = []
        var offset: Int64 = 0
        while offset < byteCount {
            let length = min(size, byteCount - offset)
            chunks.append(Chunk(index: chunks.count, offset: offset, length: length))
            offset += length
        }
        self.byteCount = max(0, byteCount)
        self.chunkBytes = size
        self.chunks = chunks
    }
}

/// A payload split into 45 MB `CKAsset` records, saved and fetched a few records per operation.
/// The chunk count is derived from the handle's byte count, so no manifest record is needed.
public struct ChunkedAssetStrategy: TransferStrategy {
    public let name: String
    private let context: SpikeCloudKitContext
    private let chunkBytes: Int64
    private let recordsPerOperation: Int

    public init(
        context: SpikeCloudKitContext = SpikeCloudKitContext(),
        chunkBytes: Int64 = ChunkPlan.defaultChunkBytes,
        recordsPerOperation: Int = 4
    ) {
        self.context = context
        self.chunkBytes = max(1, chunkBytes)
        self.recordsPerOperation = max(1, recordsPerOperation)
        self.name = "cloudkit-chunked-asset-\(self.chunkBytes / 1_048_576)mb"
    }

    public func upload(file: URL, progress: @escaping TransferProgress) async -> UploadOutcome {
        let counter = ProgressCounter()
        let byteCount = CloudKitOperations.fileSize(of: file)
        let transferID = SpikeNames.chunkedTransferID(UUID().uuidString)
        var handle: TransferHandle?
        let measurement = await measure(strategy: name, direction: .upload, bytes: byteCount, counter: counter) {
            guard byteCount > 0 else { throw SpikeCloudKitError.emptyFile(file.path) }
            try await context.ensureZone()
            let plan = ChunkPlan(byteCount: byteCount, chunkBytes: chunkBytes)
            let sizes = Dictionary(uniqueKeysWithValues: plan.chunks.map {
                (SpikeNames.chunkRecordName(chunkedTransferID: transferID, index: $0.index), $0.length)
            })
            let aggregator = ByteProgressAggregator(sizes: sizes, counter: counter, forward: progress)
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("SpikeChunks-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }

            // Chunk files are materialized one batch at a time to bound scratch disk use.
            for batch in stride(from: 0, to: plan.chunks.count, by: recordsPerOperation) {
                let slice = plan.chunks[batch ..< min(batch + recordsPerOperation, plan.chunks.count)]
                var records: [CKRecord] = []
                for chunk in slice {
                    let name = SpikeNames.chunkRecordName(chunkedTransferID: transferID, index: chunk.index)
                    let chunkURL = scratch.appendingPathComponent(name)
                    try reader.seek(toOffset: UInt64(chunk.offset))
                    let data = try reader.read(upToCount: Int(chunk.length)) ?? Data()
                    guard Int64(data.count) == chunk.length else { throw SpikeCloudKitError.emptyFile(file.path) }
                    try data.write(to: chunkURL)
                    let record = CKRecord(recordType: SpikeNames.chunkRecordType, recordID: context.recordID(named: name))
                    record[SpikeNames.assetField] = CKAsset(fileURL: chunkURL)
                    record[SpikeNames.byteCountField] = chunk.length as NSNumber
                    records.append(record)
                }
                try await CloudKitOperations.save(records, in: context.database, progress: aggregator)
                for record in records {
                    if let url = (record[SpikeNames.assetField] as? CKAsset)?.fileURL { try? FileManager.default.removeItem(at: url) }
                }
            }
            handle = TransferHandle(id: transferID, byteCount: byteCount)
        }
        return UploadOutcome(handle: measurement.succeeded ? handle : nil, measurement: measurement)
    }

    public func download(handle: TransferHandle, progress: @escaping TransferProgress) async -> SpikeCore.Measurement {
        let counter = ProgressCounter()
        var received: Int64 = 0
        let measurement = await measure(strategy: name, direction: .download, bytes: handle.byteCount, counter: counter) {
            let plan = ChunkPlan(byteCount: handle.byteCount, chunkBytes: chunkBytes)
            let names = plan.chunks.map { SpikeNames.chunkRecordName(chunkedTransferID: handle.id, index: $0.index) }
            let sizes = Dictionary(uniqueKeysWithValues: zip(names, plan.chunks.map(\.length)))
            let aggregator = ByteProgressAggregator(sizes: sizes, counter: counter, forward: progress)
            for batch in stride(from: 0, to: names.count, by: recordsPerOperation) {
                let ids = names[batch ..< min(batch + recordsPerOperation, names.count)].map(context.recordID(named:))
                let records = try await CloudKitOperations.fetch(ids, desiredKeys: nil, in: context.database, progress: aggregator)
                guard records.count == ids.count else { throw SpikeCloudKitError.missingAsset(handle.id) }
                for record in records {
                    guard let url = (record[SpikeNames.assetField] as? CKAsset)?.fileURL else {
                        throw SpikeCloudKitError.missingAsset(record.recordID.recordName)
                    }
                    received += CloudKitOperations.fileSize(of: url)
                }
            }
        }
        return SpikeCore.Measurement(
            strategy: measurement.strategy,
            direction: .download,
            bytes: measurement.succeeded ? received : counter.bytes,
            wallSeconds: measurement.wallSeconds,
            progressCallbackCount: measurement.progressCallbackCount,
            errorText: measurement.errorText ?? (received == handle.byteCount ? nil : "size mismatch: got \(received), expected \(handle.byteCount)")
        )
    }
}
