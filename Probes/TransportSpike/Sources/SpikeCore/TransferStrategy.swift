import Foundation

/// Opaque reference to an uploaded payload, valid for the strategy that produced it.
public struct TransferHandle: Codable, Hashable, Sendable {
    public let id: String
    public let byteCount: Int64

    public init(id: String, byteCount: Int64) {
        self.id = id
        self.byteCount = byteCount
    }
}

/// Result of an upload: a handle to download later (nil on failure) plus the measurement.
public struct UploadOutcome: Sendable {
    public let handle: TransferHandle?
    public let measurement: Measurement

    public init(handle: TransferHandle?, measurement: Measurement) {
        self.handle = handle
        self.measurement = measurement
    }
}

/// Reports cumulative bytes transferred so far.
public typealias TransferProgress = @Sendable (Int64) -> Void

/// A way of moving a large file through a transport (single CKAsset, chunked CKAssets, iCloud Drive, ...).
///
/// Implementations report failures through `Measurement.errorText` rather than throwing, so a run
/// always yields a measurement to record.
public protocol TransferStrategy: Sendable {
    var name: String { get }
    func upload(file: URL, progress: @escaping TransferProgress) async -> UploadOutcome
    func download(handle: TransferHandle, progress: @escaping TransferProgress) async -> Measurement
}

/// Failure injected into `InMemoryTransferStrategy`.
public enum FakeTransferError: Error, Equatable, Sendable {
    case injected
    case unknownHandle(String)
    case unreadableFile(String)
}

/// In-memory strategy for exercising the harness without a network. It stores only byte counts,
/// so 120 MB payloads cost nothing, and reports progress in `stepBytes` increments.
public final class InMemoryTransferStrategy: TransferStrategy, @unchecked Sendable {
    public let name: String
    private let stepBytes: Int64
    private let failUploads: Bool
    private let lock = NSLock()
    private var stored: [String: Int64] = [:]
    private var nextID = 0

    public init(name: String = "in-memory", stepBytes: Int64 = 1_048_576, failUploads: Bool = false) {
        self.name = name
        self.stepBytes = max(1, stepBytes)
        self.failUploads = failUploads
    }

    public func upload(file: URL, progress: @escaping TransferProgress) async -> UploadOutcome {
        let counter = ProgressCounter()
        var handle: TransferHandle?
        var size: Int64 = 0
        let measurement = await measure(strategy: name, direction: .upload, bytes: 0, counter: counter) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let fileSize = (attributes[.size] as? NSNumber)?.int64Value else {
                throw FakeTransferError.unreadableFile(file.path)
            }
            size = fileSize
            if failUploads { throw FakeTransferError.injected }
            report(total: fileSize, counter: counter, progress: progress)
            handle = store(size: fileSize)
        }
        // `measure` was created before the size was known; rebuild with the true byte count.
        let final = Measurement(
            strategy: measurement.strategy,
            direction: .upload,
            bytes: measurement.succeeded ? size : counter.bytes,
            wallSeconds: measurement.wallSeconds,
            progressCallbackCount: measurement.progressCallbackCount,
            errorText: measurement.errorText
        )
        return UploadOutcome(handle: handle, measurement: final)
    }

    public func download(handle: TransferHandle, progress: @escaping TransferProgress) async -> Measurement {
        let counter = ProgressCounter()
        let size = lookup(handle.id)
        let measurement = await measure(strategy: name, direction: .download, bytes: 0, counter: counter) {
            guard let size else { throw FakeTransferError.unknownHandle(handle.id) }
            report(total: size, counter: counter, progress: progress)
        }
        return Measurement(
            strategy: measurement.strategy,
            direction: .download,
            bytes: measurement.succeeded ? (size ?? 0) : counter.bytes,
            wallSeconds: measurement.wallSeconds,
            progressCallbackCount: measurement.progressCallbackCount,
            errorText: measurement.errorText
        )
    }

    private func report(total: Int64, counter: ProgressCounter, progress: TransferProgress) {
        var done: Int64 = 0
        while done < total {
            done = min(total, done + stepBytes)
            counter.record(bytes: done)
            progress(done)
        }
    }

    private func store(size: Int64) -> TransferHandle {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        let id = "fake-\(nextID)"
        stored[id] = size
        return TransferHandle(id: id, byteCount: size)
    }

    private func lookup(_ id: String) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return stored[id]
    }
}
