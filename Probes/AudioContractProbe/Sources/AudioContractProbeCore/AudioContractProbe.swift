import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation

public struct AudioCandidate: Codable, Equatable, Sendable {
    public let name: String
    public let container: String
    public let codec: String
    public let sampleRateHz: Int
    public let channels: Int
    public let bitRate: Int

    public init(
        name: String = "m4a-aac-gapless-single-file",
        container: String = "M4A",
        codec: String = "AAC",
        sampleRateHz: Int = 44_100,
        channels: Int = 1,
        bitRate: Int = 96_000
    ) {
        self.name = name
        self.container = container
        self.codec = codec
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.bitRate = bitRate
    }
}

public struct SeekDecodeResult: Codable, Equatable, Sendable {
    public let beginning: Bool
    public let middle: Bool
    public let end: Bool

    public var allPassed: Bool { beginning && middle && end }
}

public struct AudioProbeReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let evidencePlatform: String
    public let iosDeviceValidation: String
    public let candidate: AudioCandidate
    public let gaplessSingleFile: Bool
    public let expectedDurationSeconds: Double
    public let durationSeconds: Double
    public let durationToleranceSeconds: Double
    public let durationWithinTolerance: Bool
    public let encodedByteSize: Int
    public let sha256: String
    public let firstByteToPlayLatencyMilliseconds: Double
    public let seekDecode: SeekDecodeResult
    public let interruptionReopenRecovery: Bool
    public let avFoundationValidation: Bool
    public let durableAtomicPublication: Bool
    public let failedPreparationTempCleanup: Bool

    public init(
        schemaVersion: Int = 1,
        evidencePlatform: String,
        iosDeviceValidation: String,
        candidate: AudioCandidate,
        gaplessSingleFile: Bool,
        expectedDurationSeconds: Double,
        durationSeconds: Double,
        durationToleranceSeconds: Double,
        durationWithinTolerance: Bool,
        encodedByteSize: Int,
        sha256: String,
        firstByteToPlayLatencyMilliseconds: Double,
        seekDecode: SeekDecodeResult,
        interruptionReopenRecovery: Bool,
        avFoundationValidation: Bool,
        durableAtomicPublication: Bool,
        failedPreparationTempCleanup: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.evidencePlatform = evidencePlatform
        self.iosDeviceValidation = iosDeviceValidation
        self.candidate = candidate
        self.gaplessSingleFile = gaplessSingleFile
        self.expectedDurationSeconds = expectedDurationSeconds
        self.durationSeconds = durationSeconds
        self.durationToleranceSeconds = durationToleranceSeconds
        self.durationWithinTolerance = durationWithinTolerance
        self.encodedByteSize = encodedByteSize
        self.sha256 = sha256
        self.firstByteToPlayLatencyMilliseconds = firstByteToPlayLatencyMilliseconds
        self.seekDecode = seekDecode
        self.interruptionReopenRecovery = interruptionReopenRecovery
        self.avFoundationValidation = avFoundationValidation
        self.durableAtomicPublication = durableAtomicPublication
        self.failedPreparationTempCleanup = failedPreparationTempCleanup
    }
}

public struct SizingMeasurement: Codable, Equatable, Sendable {
    public let requestedDurationMinutes: Double
    public let actualDurationSeconds: Double
    public let encodedByteSize: Int
    public let bytesPerMinute: Double
    public let sha256: String
    public let chunkFrameCount: Int
    public let peakWorkingPCMBytes: Int
    public let durationWithinTolerance: Bool

    public init(
        requestedDurationMinutes: Double,
        actualDurationSeconds: Double,
        encodedByteSize: Int,
        bytesPerMinute: Double,
        sha256: String,
        chunkFrameCount: Int,
        peakWorkingPCMBytes: Int,
        durationWithinTolerance: Bool
    ) {
        self.requestedDurationMinutes = requestedDurationMinutes
        self.actualDurationSeconds = actualDurationSeconds
        self.encodedByteSize = encodedByteSize
        self.bytesPerMinute = bytesPerMinute
        self.sha256 = sha256
        self.chunkFrameCount = chunkFrameCount
        self.peakWorkingPCMBytes = peakWorkingPCMBytes
        self.durationWithinTolerance = durationWithinTolerance
    }
}

public struct RepresentativeSizingReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let evidencePlatform: String
    public let iosDeviceValidation: String
    public let candidate: AudioCandidate
    public let measurements: [SizingMeasurement]
    public let budgetMultiplier: Double
    public let budgetRoundingBoundaryBytes: Int
    public let budgetSourceDurationMinutes: Double
    public let budgetSourceEncodedByteSize: Int
    public let measuredNinetyMinuteEncodedByteSize: Int?
    public let configuredBitrateReferenceDurationMinutes: Double
    public let configuredBitrateReferenceBytes: Int
    public let measuredMaximumEncodedByteSize: Int
    public let appOwnedPerRevisionBudgetBytes: Int
    public let budgetDerivation: String

    public init(
        schemaVersion: Int = 1,
        evidencePlatform: String,
        iosDeviceValidation: String,
        candidate: AudioCandidate,
        measurements: [SizingMeasurement],
        budgetMultiplier: Double,
        budgetRoundingBoundaryBytes: Int,
        budgetSourceDurationMinutes: Double,
        budgetSourceEncodedByteSize: Int,
        measuredNinetyMinuteEncodedByteSize: Int?,
        configuredBitrateReferenceDurationMinutes: Double,
        configuredBitrateReferenceBytes: Int,
        measuredMaximumEncodedByteSize: Int,
        appOwnedPerRevisionBudgetBytes: Int,
        budgetDerivation: String
    ) {
        self.schemaVersion = schemaVersion
        self.evidencePlatform = evidencePlatform
        self.iosDeviceValidation = iosDeviceValidation
        self.candidate = candidate
        self.measurements = measurements
        self.budgetMultiplier = budgetMultiplier
        self.budgetRoundingBoundaryBytes = budgetRoundingBoundaryBytes
        self.budgetSourceDurationMinutes = budgetSourceDurationMinutes
        self.budgetSourceEncodedByteSize = budgetSourceEncodedByteSize
        self.measuredNinetyMinuteEncodedByteSize = measuredNinetyMinuteEncodedByteSize
        self.configuredBitrateReferenceDurationMinutes = configuredBitrateReferenceDurationMinutes
        self.configuredBitrateReferenceBytes = configuredBitrateReferenceBytes
        self.measuredMaximumEncodedByteSize = measuredMaximumEncodedByteSize
        self.appOwnedPerRevisionBudgetBytes = appOwnedPerRevisionBudgetBytes
        self.budgetDerivation = budgetDerivation
    }
}

public enum AudioProbeError: LocalizedError, Equatable {
    case destinationExists(URL)
    case invalidOutput(URL)
    case cancelled
    case invalidAudio(String)

    public var errorDescription: String? {
        switch self {
        case let .destinationExists(url):
            return "destination already exists: \(url.path)"
        case let .invalidOutput(url):
            return "invalid output: \(url.path)"
        case .cancelled:
            return "audio preparation cancelled"
        case let .invalidAudio(detail):
            return "audio validation failed: \(detail)"
        }
    }
}

public struct AudioContractProbe {
    public static let candidate = AudioCandidate()
    public static let expectedDurationSeconds = 3.0
    public static let durationToleranceSeconds = 0.08
    public static let representativeDurationsMinutes = [5.0, 30.0, 90.0]
    public static let chunkFrameCount = 4_096
    public static let budgetMultiplier = 2.0
    public static let budgetRoundingBoundaryBytes = 10_000_000
    public static let configuredBitrateReferenceDurationMinutes = 90.0
    public static let configuredBitrateReferenceBytes = Int(
        (Double(candidate.bitRate) * configuredBitrateReferenceDurationMinutes * 60.0 / 8.0).rounded()
    )

    public init() {}

    /// Measures representative article lengths without allocating a full-duration PCM buffer.
    public func measureRepresentativeSizes(
        durationsMinutes: [Double] = Self.representativeDurationsMinutes,
        outputDirectory: URL,
        status: (String) -> Void = { _ in }
    ) throws -> RepresentativeSizingReport {
        guard !durationsMinutes.isEmpty,
              durationsMinutes.allSatisfy({ $0 > 0 && $0.isFinite }) else {
            throw AudioProbeError.invalidAudio("representative durations must be finite and positive")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var measurements: [SizingMeasurement] = []
        for durationMinutes in durationsMinutes {
            let label = durationMinutes == durationMinutes.rounded()
                ? String(Int(durationMinutes))
                : String(format: "%.3f", durationMinutes).replacingOccurrences(of: ".", with: "-")
            let destination = outputDirectory.appendingPathComponent("sizing-\(label)-minutes.m4a")
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw AudioProbeError.destinationExists(destination)
            }
            status("stage=sizing-start durationMinutes=\(durationMinutes)")
            let temp = outputDirectory.appendingPathComponent(
                ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
            )
            var published = false
            defer {
                if !published {
                    try? fileManager.removeItem(at: temp)
                }
            }
            let expectedSeconds = durationMinutes * 60.0
            status("stage=sizing-encode durationMinutes=\(durationMinutes)")
            try encodeChunked(durationSeconds: expectedSeconds, to: temp) { completedFrames, totalFrames in
                status("stage=sizing-encode-progress durationMinutes=\(durationMinutes) frames=\(completedFrames)/\(totalFrames)")
            }
            status("stage=sizing-flush-close durationMinutes=\(durationMinutes)")
            try flushAndClose(temp)
            status("stage=sizing-validate durationMinutes=\(durationMinutes)")
            let validation = try validateAVFoundation(
                temp,
                expectedDurationSeconds: expectedSeconds,
                toleranceSeconds: max(Self.durationToleranceSeconds, 1.0)
            )
            guard validation.durationWithinTolerance else {
                throw AudioProbeError.invalidAudio("sizing duration outside tolerance")
            }
            let hash = try sha256(url: temp)
            let byteSize = try fileSize(url: temp)
            try fileManager.moveItem(at: temp, to: destination)
            published = true
            let publishedValidation = try validateAVFoundation(
                destination,
                expectedDurationSeconds: expectedSeconds,
                toleranceSeconds: max(Self.durationToleranceSeconds, 1.0)
            )
            guard publishedValidation.isValid else {
                throw AudioProbeError.invalidAudio("published sizing file failed AVFoundation validation")
            }
            let measurement = SizingMeasurement(
                requestedDurationMinutes: durationMinutes,
                actualDurationSeconds: validation.durationSeconds,
                encodedByteSize: byteSize,
                bytesPerMinute: Double(byteSize) / (validation.durationSeconds / 60.0),
                sha256: hash,
                chunkFrameCount: Self.chunkFrameCount,
                peakWorkingPCMBytes: Self.chunkFrameCount * Self.candidate.channels * MemoryLayout<Float>.stride,
                durationWithinTolerance: validation.durationWithinTolerance
            )
            measurements.append(measurement)
            status("stage=sizing-complete durationMinutes=\(durationMinutes) bytes=\(byteSize)")
        }

        let measuredMaximum = measurements.map(\.encodedByteSize).max() ?? 0
        let budgetSource = measurements.max { lhs, rhs in
            lhs.requestedDurationMinutes < rhs.requestedDurationMinutes
        }!
        let measuredNinetyMinute = measurements.first {
            $0.requestedDurationMinutes == Self.configuredBitrateReferenceDurationMinutes
        }?.encodedByteSize
        let rawSafetyBytes = max(
            Int(ceil(Double(budgetSource.encodedByteSize) * Self.budgetMultiplier)),
            Self.configuredBitrateReferenceBytes
        )
        let budget = ((rawSafetyBytes + Self.budgetRoundingBoundaryBytes - 1)
            / Self.budgetRoundingBoundaryBytes) * Self.budgetRoundingBoundaryBytes
        return RepresentativeSizingReport(
            evidencePlatform: "macOS 14+ AVFoundation; iOS/device validation unresolved",
            iosDeviceValidation: "unresolved: requires iOS 17 physical-device playback",
            candidate: Self.candidate,
            measurements: measurements,
            budgetMultiplier: Self.budgetMultiplier,
            budgetRoundingBoundaryBytes: Self.budgetRoundingBoundaryBytes,
            budgetSourceDurationMinutes: budgetSource.requestedDurationMinutes,
            budgetSourceEncodedByteSize: budgetSource.encodedByteSize,
            measuredNinetyMinuteEncodedByteSize: measuredNinetyMinute,
            configuredBitrateReferenceDurationMinutes: Self.configuredBitrateReferenceDurationMinutes,
            configuredBitrateReferenceBytes: Self.configuredBitrateReferenceBytes,
            measuredMaximumEncodedByteSize: measuredMaximum,
            appOwnedPerRevisionBudgetBytes: budget,
            budgetDerivation: "ceil(max(budget-source encoded bytes * 2, configured 96 kbps 90-minute reference bytes) to next 10,000,000-byte boundary); app-owned budget only, not a CloudKit service limit"
        )
    }

    /// Runs the complete disposable macOS transfer probe and publishes one M4A atomically.
    public func run(
        outputURL: URL,
        status: (String) -> Void = { _ in }
    ) throws -> AudioProbeReport {
        let fileManager = FileManager.default
        guard outputURL.pathExtension.lowercased() == "m4a" else {
            throw AudioProbeError.invalidOutput(outputURL)
        }
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw AudioProbeError.destinationExists(outputURL)
        }
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        status("stage=generate-synthetic-pcm")
        let pcm = try makeSpeechLikePCM()
        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).tmp-\(UUID().uuidString)")
        var published = false
        defer {
            if !published {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        status("stage=encode-m4a-aac")
        try encode(pcm: pcm, to: tempURL)
        status("stage=flush-close-temp")
        try flushAndClose(tempURL)

        status("stage=validate-avfoundation")
        let validation = try validateAVFoundation(
            tempURL,
            expectedDurationSeconds: Self.expectedDurationSeconds,
            toleranceSeconds: Self.durationToleranceSeconds
        )
        guard validation.durationWithinTolerance else {
            throw AudioProbeError.invalidAudio("duration outside tolerance")
        }

        status("stage=seek-decode")
        let seekDecode = try seekAndDecode(url: tempURL, frameCount: validation.decodedFrameCount)
        guard seekDecode.allPassed else {
            throw AudioProbeError.invalidAudio("one or more seek points did not decode")
        }

        status("stage=interruption-reopen")
        let interruptionRecovered = try interruptionAndReopen(url: tempURL, frameCount: validation.decodedFrameCount)
        guard interruptionRecovered else {
            throw AudioProbeError.invalidAudio("reopen did not recover")
        }

        status("stage=measure-first-byte-to-play")
        let latency = try firstByteToPlayLatency(url: tempURL)
        status("stage=hash")
        let hash = try sha256(url: tempURL)
        let byteSize = try fileSize(url: tempURL)

        status("stage=atomic-rename")
        try fileManager.moveItem(at: tempURL, to: outputURL)
        published = true

        status("stage=verify-published-file")
        let publishedHash = try sha256(url: outputURL)
        guard publishedHash == hash else {
            throw AudioProbeError.invalidAudio("published hash changed")
        }
        let publishedValidation = try validateAVFoundation(
            outputURL,
            expectedDurationSeconds: Self.expectedDurationSeconds,
            toleranceSeconds: Self.durationToleranceSeconds
        )
        guard publishedValidation.isValid else {
            throw AudioProbeError.invalidAudio("published file failed AVFoundation validation")
        }

        // Exercise failure cleanup independently while preserving the published candidate.
        status("stage=verify-temp-failure-cleanup")
        let cleanupVerified = try verifyFailureCleanup(in: outputURL.deletingLastPathComponent())

        return AudioProbeReport(
            evidencePlatform: "macOS 14+ AVFoundation; iOS/device validation unresolved",
            iosDeviceValidation: "unresolved: requires iOS 17 physical-device playback",
            candidate: Self.candidate,
            gaplessSingleFile: true,
            expectedDurationSeconds: Self.expectedDurationSeconds,
            durationSeconds: validation.durationSeconds,
            durationToleranceSeconds: Self.durationToleranceSeconds,
            durationWithinTolerance: validation.durationWithinTolerance,
            encodedByteSize: byteSize,
            sha256: hash,
            firstByteToPlayLatencyMilliseconds: latency,
            seekDecode: seekDecode,
            interruptionReopenRecovery: interruptionRecovered,
            avFoundationValidation: validation.isValid,
            durableAtomicPublication: true,
            failedPreparationTempCleanup: cleanupVerified
        )
    }

    private struct Validation {
        let durationSeconds: Double
        let decodedFrameCount: AVAudioFramePosition
        let durationWithinTolerance: Bool
        let isValid: Bool
    }

    private func makeSpeechLikePCM(
        frameOffset: AVAudioFramePosition = 0,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.candidate.sampleRateHz),
            channels: AVAudioChannelCount(Self.candidate.channels),
            interleaved: false
        ) else {
            throw AudioProbeError.invalidAudio("could not create PCM format")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            throw AudioProbeError.invalidAudio("could not allocate PCM buffer")
        }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let time = Double(frameOffset + AVAudioFramePosition(frame)) / format.sampleRate
            let phrase = 0.35 + 0.65 * (0.5 + 0.5 * sin(2.0 * Double.pi * 3.2 * time))
            let syllable = 0.25 + 0.75 * abs(sin(Double.pi * 1.7 * time))
            let carrier = sin(2.0 * Double.pi * 170.0 * time)
                + 0.38 * sin(2.0 * Double.pi * 340.0 * time)
                + 0.16 * sin(2.0 * Double.pi * 510.0 * time)
            channel[frame] = Float(0.24 * phrase * syllable * carrier)
        }
        return buffer
    }

    private func makeSpeechLikePCM() throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(Self.expectedDurationSeconds * Double(Self.candidate.sampleRateHz))
        return try makeSpeechLikePCM(frameCount: frameCount)
    }

    private func encode(pcm: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.candidate.sampleRateHz,
            AVNumberOfChannelsKey: Self.candidate.channels,
            AVEncoderBitRateKey: Self.candidate.bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: pcm)
    }

    private func encodeChunked(
        durationSeconds: Double,
        to url: URL,
        progress: (AVAudioFramePosition, AVAudioFramePosition) -> Void = { _, _ in }
    ) throws {
        let totalFrames = AVAudioFramePosition(
            (durationSeconds * Double(Self.candidate.sampleRateHz)).rounded()
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.candidate.sampleRateHz,
            AVNumberOfChannelsKey: Self.candidate.channels,
            AVEncoderBitRateKey: Self.candidate.bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        var offset: AVAudioFramePosition = 0
        var chunkIndex = 0
        var lastProgressTime = DispatchTime.now().uptimeNanoseconds
        while offset < totalFrames {
            let count = AVAudioFrameCount(
                min(AVAudioFramePosition(Self.chunkFrameCount), totalFrames - offset)
            )
            let pcm = try makeSpeechLikePCM(frameOffset: offset, frameCount: count)
            try file.write(from: pcm)
            offset += AVAudioFramePosition(count)
            chunkIndex += 1
            let now = DispatchTime.now().uptimeNanoseconds
            if chunkIndex == 1 || offset == totalFrames || now - lastProgressTime >= 5_000_000_000 {
                progress(offset, totalFrames)
                lastProgressTime = now
            }
        }
    }

    private func flushAndClose(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private func validateAVFoundation(
        _ url: URL,
        expectedDurationSeconds: Double,
        toleranceSeconds: Double
    ) throws -> Validation {
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        let streamDescription = format.streamDescription.pointee
        let codec = streamDescription.mFormatID
        guard codec == kAudioFormatMPEG4AAC else {
            throw AudioProbeError.invalidAudio("codec FourCC was not AAC")
        }
        guard Int(format.sampleRate.rounded()) == Self.candidate.sampleRateHz,
              Int(format.channelCount) == Self.candidate.channels else {
            throw AudioProbeError.invalidAudio("sample rate or channel count changed")
        }
        let frameCount = file.length
        let duration = Double(frameCount) / format.sampleRate
        let withinTolerance = abs(duration - expectedDurationSeconds) <= toleranceSeconds
        guard frameCount > 0 else {
            throw AudioProbeError.invalidAudio("decoded file was empty")
        }
        return Validation(
            durationSeconds: duration,
            decodedFrameCount: frameCount,
            durationWithinTolerance: withinTolerance,
            isValid: withinTolerance
        )
    }

    private func seekAndDecode(url: URL, frameCount: AVAudioFramePosition) throws -> SeekDecodeResult {
        let targets: [AVAudioFramePosition] = [
            0,
            max(0, frameCount / 2),
            max(0, frameCount - 1_024),
        ]
        var results: [Bool] = []
        for target in targets {
            let file = try AVAudioFile(forReading: url)
            file.framePosition = target
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: min(1_024, AVAudioFrameCount(max(1, frameCount - target)))
            ) else {
                results.append(false)
                continue
            }
            try file.read(into: buffer)
            results.append(buffer.frameLength > 0)
        }
        return SeekDecodeResult(
            beginning: results[0],
            middle: results[1],
            end: results[2]
        )
    }

    private func interruptionAndReopen(url: URL, frameCount: AVAudioFramePosition) throws -> Bool {
        do {
            let firstReader = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: firstReader.processingFormat, frameCapacity: 512) else {
                return false
            }
            try firstReader.read(into: buffer)
            guard buffer.frameLength > 0 else { return false }
        }
        let reopened = try AVAudioFile(forReading: url)
        reopened.framePosition = max(0, frameCount / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: reopened.processingFormat, frameCapacity: 512) else {
            return false
        }
        try reopened.read(into: buffer)
        return buffer.frameLength > 0
    }

    private func firstByteToPlayLatency(url: URL) throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512) else {
            throw AudioProbeError.invalidAudio("could not allocate first playback buffer")
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else {
            throw AudioProbeError.invalidAudio("first playback buffer was empty")
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000.0
    }

    private func sha256(url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else {
            throw AudioProbeError.invalidAudio("encoded output has no bytes")
        }
        return size
    }

    private func verifyFailureCleanup(in directory: URL) throws -> Bool {
        let sentinel = directory.appendingPathComponent("audio-contract-probe-sentinel-\(UUID().uuidString).m4a")
        try Data("prior-valid-output".utf8).write(to: sentinel, options: .atomic)
        let temp = directory.appendingPathComponent(".\(sentinel.lastPathComponent).tmp-failure")
        defer {
            try? FileManager.default.removeItem(at: sentinel)
            try? FileManager.default.removeItem(at: temp)
        }
        do {
            try Data("partial".utf8).write(to: temp, options: .atomic)
            throw AudioProbeError.cancelled
        } catch AudioProbeError.cancelled {
            try FileManager.default.removeItem(at: temp)
        }
        return FileManager.default.fileExists(atPath: sentinel.path)
            && !FileManager.default.fileExists(atPath: temp.path)
    }
}
