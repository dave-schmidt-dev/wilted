import AVFoundation
import CryptoKit
import Foundation
import WiltedDomain

/// Cursor for the resampler's pull block. `AVAudioConverter` invokes that block
/// synchronously on the calling thread for the duration of one `convert` call, so the
/// state is single-threaded in practice despite the block's `@Sendable` requirement.
private final class ResampleCursor: @unchecked Sendable {
    var offset = 0
    var consumedInput = false
}

/// The immutable result exposed only after the transfer file is durable.
public struct AudioAssemblyResult: Equatable, Sendable {
    public let revision: AudioRevision
    public let mediaURL: URL

    public init(revision: AudioRevision, mediaURL: URL) {
        self.revision = revision
        self.mediaURL = mediaURL
    }
}

public enum AudioAssemblerError: Error, Equatable, LocalizedError, Sendable {
    case cancelled
    case destinationExists(URL)
    case invalidOutput(URL)
    case invalidPCM(String)
    case invalidAudio(String)
    case outputTooLarge(Int64)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Audio assembly was cancelled."
        case let .destinationExists(url): "The destination already exists: \(url.path)"
        case let .invalidOutput(url): "The output must be an M4A file: \(url.path)"
        case let .invalidPCM(reason): "Invalid PCM input: \(reason)"
        case let .invalidAudio(reason): "Invalid encoded audio: \(reason)"
        case let .outputTooLarge(bytes): "Encoded audio exceeds the per-revision budget (\(bytes) bytes)."
        }
    }
}

/// Encodes one mono 44.1 kHz Float32 PCM stream as a validated AAC transfer file.
public struct AudioAssembler: Sendable {
    public static let sampleRate = 44_100
    public static let channels = 1
    public static let bitRate = 96_000
    public static let maxRevisionAssetBytes: Int64 = 80_000_000
    public static let mediaType = "audio/mp4"
    private static let chunkFrameCount = 4_096

    private let maxBytes: Int64

    public init(maxRevisionAssetBytes: Int64 = Self.maxRevisionAssetBytes) {
        self.maxBytes = maxRevisionAssetBytes
    }

    /// Encodes an array of mono Float32 samples and atomically publishes its ready revision.
    public func assemble(
        pcm samples: [Float],
        itemID: ItemID,
        destinationURL: URL,
        sourceSampleRate: Int = Self.sampleRate,
        extractedTextSHA256: String = "",
        voiceID: String = "default",
        synthesisSettingsCanonicalJSON: String = "{}",
        revisionID: RevisionID? = nil,
        schemaVersion: Int = 1,
        createdAt: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> AudioAssemblyResult {
        try assemble(
            samples: samples,
            itemID: itemID,
            destinationURL: destinationURL,
            sourceSampleRate: sourceSampleRate,
            extractedTextSHA256: extractedTextSHA256,
            voiceID: voiceID,
            synthesisSettingsCanonicalJSON: synthesisSettingsCanonicalJSON,
            revisionID: revisionID,
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            isCancelled: isCancelled,
            onStatus: onStatus
        )
    }

    /// Convenience spelling for callers that use `samples` as the PCM label.
    public func assemble(
        samples: [Float],
        itemID: ItemID,
        destinationURL: URL,
        sourceSampleRate: Int = Self.sampleRate,
        extractedTextSHA256: String = "",
        voiceID: String = "default",
        synthesisSettingsCanonicalJSON: String = "{}",
        revisionID: RevisionID? = nil,
        schemaVersion: Int = 1,
        createdAt: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> AudioAssemblyResult {
        guard !samples.isEmpty else { throw AudioAssemblerError.invalidPCM("samples must not be empty") }
        guard sourceSampleRate > 0 else {
            throw AudioAssemblerError.invalidPCM("source sample rate must be positive")
        }
        guard samples.allSatisfy(\.isFinite) else {
            throw AudioAssemblerError.invalidPCM("samples must be finite")
        }
        try checkpoint(isCancelled)
        try validateDestination(destinationURL)

        let fileManager = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        var published = false
        defer {
            if !published { try? fileManager.removeItem(at: temporaryURL) }
        }

        onStatus("stage=encode-m4a-aac")
        try encode(
            samples: samples, sourceSampleRate: sourceSampleRate, to: temporaryURL,
            isCancelled: isCancelled, onStatus: onStatus
        )
        try checkpoint(isCancelled)
        onStatus("stage=flush-close")
        try flushAndClose(temporaryURL)

        onStatus("stage=validate-avasset")
        // Measured against the PCM's own rate, not the container's. This is what makes a
        // rate mismatch fail loudly instead of publishing correct-looking, fast-playing audio.
        let duration = try validate(
            temporaryURL, expectedDuration: Double(samples.count) / Double(sourceSampleRate)
        )
        onStatus("stage=hash")
        let hash = try sha256(temporaryURL)
        let byteCount = try fileSize(temporaryURL)
        guard byteCount <= maxBytes else { throw AudioAssemblerError.outputTooLarge(byteCount) }
        try checkpoint(isCancelled)

        onStatus("stage=atomic-rename")
        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            // moveItem does not replace an existing path. Preserve the prior revision
            // even when another writer wins the destination race after our initial check.
            if fileManager.fileExists(atPath: destinationURL.path) {
                throw AudioAssemblerError.destinationExists(destinationURL)
            }
            throw error
        }
        published = true

        onStatus("stage=verify-published")
        guard try sha256(destinationURL) == hash else {
            throw AudioAssemblerError.invalidAudio("published hash changed")
        }
        _ = try validate(destinationURL, expectedDuration: duration)
        let derivedRevision = try revisionID ?? RevisionID.derive(
            extractedTextSHA256: extractedTextSHA256.isEmpty ? hash : extractedTextSHA256,
            voiceID: voiceID,
            synthesisSettingsCanonicalJSON: synthesisSettingsCanonicalJSON,
            audioFormatCanonicalJSON: "{\"bitRate\":96000,\"channels\":1,\"codec\":\"AAC\",\"container\":\"M4A\",\"sampleRateHz\":44100}"
        )
        let revision = try AudioRevision(
            itemID: itemID,
            revisionID: derivedRevision,
            durationSeconds: duration,
            byteCount: byteCount,
            contentHash: "sha256:\(hash)",
            mediaType: Self.mediaType,
            createdAt: Timestamp(createdAt),
            schemaVersion: schemaVersion
        )
        return AudioAssemblyResult(revision: revision, mediaURL: destinationURL)
    }

    /// Encodes an AVAudioPCMBuffer after enforcing the producer's PCM contract.
    public func assemble(
        pcm buffer: AVAudioPCMBuffer,
        itemID: ItemID,
        destinationURL: URL,
        extractedTextSHA256: String = "",
        voiceID: String = "default",
        synthesisSettingsCanonicalJSON: String = "{}",
        revisionID: RevisionID? = nil,
        schemaVersion: Int = 1,
        createdAt: Date = Date(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> AudioAssemblyResult {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32,
              Int(format.sampleRate.rounded()) == Self.sampleRate,
              format.channelCount == Self.channels,
              buffer.frameLength > 0,
              let channel = buffer.floatChannelData?[0]
        else {
            throw AudioAssemblerError.invalidPCM("expected non-empty mono 44.1 kHz Float32 PCM")
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return try assemble(
            samples: samples,
            itemID: itemID,
            destinationURL: destinationURL,
            extractedTextSHA256: extractedTextSHA256,
            voiceID: voiceID,
            synthesisSettingsCanonicalJSON: synthesisSettingsCanonicalJSON,
            revisionID: revisionID,
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            isCancelled: isCancelled,
            onStatus: onStatus
        )
    }

    private func validateDestination(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "m4a" else { throw AudioAssemblerError.invalidOutput(url) }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AudioAssemblerError.destinationExists(url)
        }
    }

    private func checkpoint(_ isCancelled: @Sendable () -> Bool) throws {
        if Task.isCancelled || isCancelled() { throw AudioAssemblerError.cancelled }
    }

    private func encode(
        samples: [Float],
        sourceSampleRate: Int,
        to url: URL,
        isCancelled: @Sendable () -> Bool,
        onStatus: @Sendable (String) -> Void
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channels,
            AVEncoderBitRateKey: Self.bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate), channels: 1, interleaved: false) else {
            throw AudioAssemblerError.invalidPCM("could not create PCM format")
        }
        guard sourceSampleRate == Self.sampleRate else {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try resample(
                samples: samples, from: sourceSampleRate, to: format, writingTo: file,
                isCancelled: isCancelled, onStatus: onStatus
            )
            return
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            var offset = 0
            while offset < samples.count {
                try checkpoint(isCancelled)
                let count = min(Self.chunkFrameCount, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else {
                    throw AudioAssemblerError.invalidPCM("could not allocate PCM chunk")
                }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { source in
                    channel.update(from: source.baseAddress!.advanced(by: offset), count: count)
                }
                try file.write(from: buffer)
                offset += count
                onStatus("stage=encode-progress frames=\(offset)/\(samples.count)")
            }
        }
    }

    private func flushAndClose(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private func validate(_ url: URL, expectedDuration: Double) throws -> Double {
        let audioFile = try AVAudioFile(forReading: url)
        let description = audioFile.fileFormat.streamDescription.pointee
        guard description.mFormatID == kAudioFormatMPEG4AAC,
              Int(audioFile.fileFormat.sampleRate.rounded()) == Self.sampleRate,
              audioFile.fileFormat.channelCount == Self.channels,
              audioFile.length > 0 else {
            throw AudioAssemblerError.invalidAudio("output is not mono AAC at 44.1 kHz")
        }
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw AudioAssemblerError.invalidAudio("duration is unavailable") }
        let tolerance = max(0.2, expectedDuration * 0.02)
        guard abs(duration - expectedDuration) <= tolerance else {
            throw AudioAssemblerError.invalidAudio("duration outside tolerance")
        }
        return duration
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else { throw AudioAssemblerError.invalidAudio("output is empty") }
        return Int64(size)
    }

    /// Converts PCM produced at `sourceRate` into the frozen 44.1 kHz transfer format.
    ///
    /// The speech daemon streams Kokoro audio at 24 kHz while the Phase 0 audio contract
    /// fixes the container at 44.1 kHz mono AAC. Resampling keeps that contract and its
    /// checked-in budget evidence intact instead of redeclaring the container's rate.
    private func resample(
        samples: [Float],
        from sourceRate: Int,
        to outputFormat: AVAudioFormat,
        writingTo file: AVAudioFile,
        isCancelled: @Sendable () -> Bool,
        onStatus: @Sendable (String) -> Void
    ) throws {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sourceRate), channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw AudioAssemblerError.invalidPCM("could not resample \(sourceRate) Hz to \(Self.sampleRate) Hz")
        }
        onStatus("stage=resample from=\(sourceRate) to=\(Self.sampleRate)")
        let ratio = outputFormat.sampleRate / Double(sourceRate)
        let outputCapacity = AVAudioFrameCount((Double(Self.chunkFrameCount) * ratio).rounded(.up)) + 1_024
        let cursor = ResampleCursor()
        while true {
            try checkpoint(isCancelled)
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw AudioAssemblerError.invalidPCM("could not allocate resample chunk")
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard cursor.offset < samples.count else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let count = min(Self.chunkFrameCount, samples.count - cursor.offset)
                guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)),
                      let channel = input.floatChannelData?[0] else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                input.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { source in
                    channel.update(from: source.baseAddress!.advanced(by: cursor.offset), count: count)
                }
                cursor.offset += count
                cursor.consumedInput = true
                inputStatus.pointee = .haveData
                return input
            }
            if let conversionError {
                throw AudioAssemblerError.invalidPCM("resample failed: \(conversionError.localizedDescription)")
            }
            if output.frameLength > 0 { try file.write(from: output) }
            onStatus("stage=resample-progress frames=\(cursor.offset)/\(samples.count)")
            switch status {
            case .haveData:
                continue
            case .endOfStream:
                return
            case .inputRanDry:
                // The converter drained its input without a terminal frame. Only a
                // stalled input block can do that here, so fail rather than truncate.
                guard cursor.offset < samples.count else { return }
                guard cursor.consumedInput else {
                    throw AudioAssemblerError.invalidPCM("resample stalled at frame \(cursor.offset)")
                }
                cursor.consumedInput = false
            case .error:
                throw AudioAssemblerError.invalidPCM("resample reported an error at frame \(cursor.offset)")
            @unknown default:
                throw AudioAssemblerError.invalidPCM("unknown resample status")
            }
        }
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
