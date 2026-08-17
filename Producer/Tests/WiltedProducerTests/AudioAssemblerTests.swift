import AVFoundation
import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Audio assembly")
struct AudioAssemblerTests {
    @Test func publishesPlayableHashedReadyRevision() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("revision.m4a")
        let result = try AudioAssembler().assemble(
            pcm: samples,
            itemID: try ItemID(rawValue: "item-test"),
            destinationURL: destination,
            extractedTextSHA256: String(repeating: "a", count: 64),
            voiceID: "voice-test",
            synthesisSettingsCanonicalJSON: "{}"
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(result.mediaURL == destination)
        #expect(result.revision.readiness == .ready)
        #expect(result.revision.mediaType == "audio/mp4")
        #expect(result.revision.byteCount > 0)
        #expect(result.revision.contentHash.hasPrefix("sha256:"))
        #expect(result.revision.contentHash.count == 71)

        let file = try AVAudioFile(forReading: destination)
        #expect(file.fileFormat.channelCount == 1)
        #expect(Int(file.fileFormat.sampleRate.rounded()) == 44_100)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(Double(file.length) / file.processingFormat.sampleRate > 0)
        let digest = SHA256.hash(data: try Data(contentsOf: destination))
            .map { String(format: "%02x", $0) }.joined()
        #expect(result.revision.contentHash == "sha256:\(digest)")
    }

    @Test func cancellationAndFailureRemoveTempOnly() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cancelled.m4a")
        #expect(throws: AudioAssemblerError.cancelled) {
            try AudioAssembler().assemble(
                pcm: samples,
                itemID: try ItemID(rawValue: "item-test"),
                destinationURL: destination,
                isCancelled: { true }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(leftovers.filter { $0.lastPathComponent.contains(".tmp-") }.isEmpty)
    }

    @Test func existingDestinationAndPriorMediaArePreserved() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("prior.m4a")
        let prior = Data("prior-ready-media".utf8)
        try prior.write(to: destination)
        #expect(throws: AudioAssemblerError.destinationExists(destination)) {
            try AudioAssembler().assemble(
                pcm: samples,
                itemID: try ItemID(rawValue: "item-test"),
                destinationURL: destination
            )
        }
        #expect(try Data(contentsOf: destination) == prior)
    }

    @Test func sizeGuardDoesNotPublishCandidate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("oversized.m4a")
        do {
            _ = try AudioAssembler(maxRevisionAssetBytes: 1).assemble(
                pcm: samples,
                itemID: try ItemID(rawValue: "item-test"),
                destinationURL: destination
            )
            Issue.record("Expected output-size guard")
        } catch AudioAssemblerError.outputTooLarge(let bytes) {
            #expect(bytes > 1)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(leftovers.filter { $0.lastPathComponent.contains(".tmp-") }.isEmpty)
    }

    private var samples: [Float] {
        (0..<44_100).map { index in
            Float(0.2 * sin(2 * Double.pi * 220 * Double(index) / 44_100))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wilted-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
