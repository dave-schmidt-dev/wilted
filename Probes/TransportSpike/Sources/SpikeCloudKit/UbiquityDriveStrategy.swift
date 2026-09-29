import Foundation
import SpikeCore

/// Whether this build can reach an iCloud Drive ubiquity container.
public enum UbiquityAvailability: Equatable, Sendable {
    case available(containerURL: URL)
    case skipped(reason: String)
}

/// Optional iCloud Drive transport: copy the file into the app's ubiquity container and wait for
/// the system to report it uploaded. Skipped with a recorded reason when the capability is absent.
///
/// The system exposes upload and download state but no byte-level progress through
/// `URLResourceValues`, so progress fires once, on completion. That absence is itself a finding.
public struct UbiquityDriveStrategy: TransferStrategy {
    public static let strategyName = "icloud-drive-ubiquity"
    /// Every file this strategy writes lives under `Documents/SpikeZone`; teardown removes that directory.
    public static let directoryName = SpikeNames.zoneName

    public let name = UbiquityDriveStrategy.strategyName
    private let containerIdentifier: String?
    private let timeoutSeconds: Double
    private let pollIntervalSeconds: Double

    public init(containerIdentifier: String? = nil, timeoutSeconds: Double = 900, pollIntervalSeconds: Double = 0.5) {
        self.containerIdentifier = containerIdentifier
        self.timeoutSeconds = timeoutSeconds
        self.pollIntervalSeconds = max(0.05, pollIntervalSeconds)
    }

    /// Resolves the ubiquity container off the calling thread (the call can block on first use).
    public static func availability(containerIdentifier: String? = nil) async -> UbiquityAvailability {
        await Task.detached {
            guard FileManager.default.ubiquityIdentityToken != nil else {
                return UbiquityAvailability.skipped(reason: "not signed in to iCloud or iCloud Drive is off")
            }
            guard let url = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
                return UbiquityAvailability.skipped(reason: "no iCloud Drive ubiquity container (entitlement or container missing)")
            }
            return UbiquityAvailability.available(containerURL: url)
        }.value
    }

    /// The directory holding every file this strategy writes.
    public static func spikeDirectory(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public func upload(file: URL, progress: @escaping TransferProgress) async -> UploadOutcome {
        let counter = ProgressCounter()
        let byteCount = CloudKitOperations.fileSize(of: file)
        var handle: TransferHandle?
        let availability = await Self.availability(containerIdentifier: containerIdentifier)
        let measurement = await measure(strategy: name, direction: .upload, bytes: byteCount, counter: counter) {
            guard case .available(let container) = availability else {
                if case .skipped(let reason) = availability { throw SpikeCloudKitError.skipped(reason) }
                return
            }
            guard byteCount > 0 else { throw SpikeCloudKitError.emptyFile(file.path) }
            let directory = Self.spikeDirectory(in: container)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = "\(UUID().uuidString).bin"
            let destination = directory.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: file, to: destination)
            try await waitUntil(destination, description: "upload") { values in
                if let error = values.ubiquitousItemUploadingError { throw error }
                return values.ubiquitousItemIsUploaded == true
            }
            counter.record(bytes: byteCount)
            progress(byteCount)
            handle = TransferHandle(id: fileName, byteCount: byteCount)
        }
        return UploadOutcome(handle: measurement.succeeded ? handle : nil, measurement: measurement)
    }

    public func download(handle: TransferHandle, progress: @escaping TransferProgress) async -> SpikeCore.Measurement {
        let counter = ProgressCounter()
        var received: Int64 = 0
        let availability = await Self.availability(containerIdentifier: containerIdentifier)
        let measurement = await measure(strategy: name, direction: .download, bytes: handle.byteCount, counter: counter) {
            guard case .available(let container) = availability else {
                if case .skipped(let reason) = availability { throw SpikeCloudKitError.skipped(reason) }
                return
            }
            let url = Self.spikeDirectory(in: container).appendingPathComponent(handle.id)
            // No-op when the file is already local (same-device runs); needed on a second device.
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            try await waitUntil(url, description: "download") { values in
                if let error = values.ubiquitousItemDownloadingError { throw error }
                return values.ubiquitousItemDownloadingStatus == .current
            }
            received = CloudKitOperations.fileSize(of: url)
            counter.record(bytes: received)
            progress(received)
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

    private func waitUntil(
        _ url: URL,
        description: String,
        done: (URLResourceValues) throws -> Bool
    ) async throws {
        let keys: Set<URLResourceKey> = [
            .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey,
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey,
        ]
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while true {
            var probe = url
            probe.removeAllCachedResourceValues()
            if try done(try probe.resourceValues(forKeys: keys)) { return }
            if ContinuousClock.now >= deadline {
                throw SpikeCloudKitError.timedOut("iCloud Drive \(description) timed out after \(Int(timeoutSeconds)) s")
            }
            try await Task.sleep(for: .seconds(pollIntervalSeconds))
        }
    }
}
