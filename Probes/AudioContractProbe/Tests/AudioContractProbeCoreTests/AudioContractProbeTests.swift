import AVFoundation
import AudioToolbox
import XCTest
@testable import AudioContractProbeCore

final class AudioContractProbeTests: XCTestCase {
    func testCandidateIsExplicitAndDeterministic() {
        let candidate = AudioContractProbe.candidate
        XCTAssertEqual(candidate.container, "M4A")
        XCTAssertEqual(candidate.codec, "AAC")
        XCTAssertEqual(candidate.sampleRateHz, 44_100)
        XCTAssertEqual(candidate.channels, 1)
        XCTAssertEqual(candidate.bitRate, 96_000)
        XCTAssertEqual(AudioContractProbe.expectedDurationSeconds, 3.0)
    }

    func testProbePublishesValidatedSingleFileAndReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-contract-probe-tests-\(UUID().uuidString)")
        let output = directory.appendingPathComponent("candidate.m4a")
        defer { try? FileManager.default.removeItem(at: directory) }

        var stages: [String] = []
        let report = try AudioContractProbe().run(outputURL: output) { stages.append($0) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(report.candidate, AudioContractProbe.candidate)
        XCTAssertTrue(report.gaplessSingleFile)
        XCTAssertTrue(report.durationWithinTolerance)
        XCTAssertGreaterThan(report.encodedByteSize, 0)
        XCTAssertEqual(report.sha256.count, 64)
        XCTAssertTrue(report.sha256.allSatisfy { $0.isHexDigit })
        XCTAssertGreaterThanOrEqual(report.firstByteToPlayLatencyMilliseconds, 0)
        XCTAssertTrue(report.seekDecode.allPassed)
        XCTAssertTrue(report.interruptionReopenRecovery)
        XCTAssertTrue(report.avFoundationValidation)
        XCTAssertTrue(report.durableAtomicPublication)
        XCTAssertTrue(report.failedPreparationTempCleanup)
        XCTAssertEqual(report.iosDeviceValidation, "unresolved: requires iOS 17 physical-device playback")
        XCTAssertTrue(stages.contains("stage=atomic-rename"))
        XCTAssertTrue(stages.contains("stage=verify-temp-failure-cleanup"))

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(Int(file.fileFormat.channelCount), 1)
    }

    func testExistingDestinationIsNeverReplaced() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-contract-probe-existing-\(UUID().uuidString)")
        let output = directory.appendingPathComponent("candidate.m4a")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prior = Data("prior-valid-output".utf8)
        try prior.write(to: output)

        XCTAssertThrowsError(try AudioContractProbe().run(outputURL: output)) { error in
            XCTAssertEqual(error as? AudioProbeError, .destinationExists(output))
        }
        XCTAssertEqual(try Data(contentsOf: output), prior)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".tmp-") }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    func testChunkedSizingIsBoundedAndMonotonic() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-contract-probe-sizing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = try AudioContractProbe().measureRepresentativeSizes(
            durationsMinutes: [0.05, 0.10, 0.20],
            outputDirectory: directory
        )

        XCTAssertEqual(report.measurements.count, 3)
        XCTAssertEqual(report.budgetMultiplier, 2.0)
        XCTAssertEqual(report.budgetRoundingBoundaryBytes, 10_000_000)
        XCTAssertEqual(report.budgetSourceDurationMinutes, 0.20)
        XCTAssertNil(report.measuredNinetyMinuteEncodedByteSize)
        XCTAssertEqual(report.configuredBitrateReferenceDurationMinutes, 90.0)
        XCTAssertEqual(report.configuredBitrateReferenceBytes, 64_800_000)
        XCTAssertEqual(
            report.budgetDerivation,
            "ceil(max(budget-source encoded bytes * 2, configured 96 kbps 90-minute reference bytes) to next 10,000,000-byte boundary); app-owned budget only, not a CloudKit service limit"
        )
        let measurements = report.measurements
        XCTAssertTrue(measurements.allSatisfy { $0.durationWithinTolerance })
        XCTAssertTrue(measurements.allSatisfy { $0.chunkFrameCount == AudioContractProbe.chunkFrameCount })
        XCTAssertTrue(measurements.allSatisfy {
            $0.peakWorkingPCMBytes == AudioContractProbe.chunkFrameCount
                * AudioContractProbe.candidate.channels
                * MemoryLayout<Float>.stride
        })
        XCTAssertLessThan(measurements[0].encodedByteSize, measurements[1].encodedByteSize)
        XCTAssertLessThan(measurements[1].encodedByteSize, measurements[2].encodedByteSize)
        XCTAssertEqual(
            report.measuredMaximumEncodedByteSize,
            measurements.map(\.encodedByteSize).max()
        )
        let rawSafetyBytes = max(
            report.budgetSourceEncodedByteSize * 2,
            report.configuredBitrateReferenceBytes
        )
        let expectedBudget = ((rawSafetyBytes + report.budgetRoundingBoundaryBytes - 1)
            / report.budgetRoundingBoundaryBytes) * report.budgetRoundingBoundaryBytes
        XCTAssertEqual(report.appOwnedPerRevisionBudgetBytes, expectedBudget)
        XCTAssertGreaterThanOrEqual(report.appOwnedPerRevisionBudgetBytes, report.measuredMaximumEncodedByteSize)
        XCTAssertGreaterThanOrEqual(report.appOwnedPerRevisionBudgetBytes, report.configuredBitrateReferenceBytes)
    }
}
