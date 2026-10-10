import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import WiltedProducer

/// Short generated audio, so no test needs a binary fixture.
enum AudiobookTestAudio {
    enum Container { case aac, wav }

    @discardableResult
    static func writeTone(
        to url: URL, seconds: Double, frequency: Double = 440, container: Container = .aac, channels: Int = 1
    ) throws -> URL {
        let rate = 44_100.0
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        switch container {
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 64_000 * channels
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let total = Int(seconds * rate)
        var written = 0
        while written < total {
            let count = min(44_100, total - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channels {
                let samples = buffer.floatChannelData![channel]
                for index in 0..<count {
                    samples[index] = Float(0.3 * sin(2 * .pi * frequency * Double(written + index) / rate))
                }
            }
            try file.write(from: buffer)
            written += count
        }
        return url
    }

    static func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    static func ownedDirectory(_ name: String) throws -> URL {
        let directory = OwnedTestTemp.root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Suite("Audiobook joiner")
struct AudiobookJoinerTests {
    private func parts(_ seconds: [Double], in directory: URL, container: AudiobookTestAudio.Container = .aac) throws -> [URL] {
        try seconds.enumerated().map {
            try AudiobookTestAudio.writeTone(
                to: directory.appendingPathComponent("part\($0.offset).\(container == .aac ? "m4a" : "wav")"),
                seconds: $0.element, frequency: 330 + 110 * Double($0.offset), container: container
            )
        }
    }

    @Test func threeAacPartsJoinIntoOneFileWithMatchingDurationAndChapters() async throws {
        let directory = try AudiobookTestAudio.ownedDirectory("joiner-three")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = try parts([3, 4, 5], in: directory)
        let marks = [
            AudiobookChapterMark(title: "One", startSeconds: 0),
            AudiobookChapterMark(title: "Two", startSeconds: 3),
            AudiobookChapterMark(title: "Three", startSeconds: 7),
        ]
        let volumes = try await AudiobookJoiner().join(
            parts: sources, marks: marks, workDirectory: directory.appendingPathComponent("work"))
        let volume = try #require(volumes.first)
        #expect(volumes.count == 1)
        #expect(abs(volume.durationSeconds - 12) < 0.1)
        #expect(abs(try await AudiobookTestAudio.duration(of: volume.url) - 12) < 0.1)
        let chapters = try await AudiobookImporter.chapters(of: volume.url)
        #expect(chapters.map(\.title) == ["One", "Two", "Three"])
        for (read, expected) in zip(chapters, marks) { #expect(abs(read.startSeconds - expected.startSeconds) < 0.1) }
        #expect(volume.byteCount > 0)
    }

    @Test func nonAacPartsAreReencodedIntoOneFile() async throws {
        let directory = try AudiobookTestAudio.ownedDirectory("joiner-wav")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = try parts([2, 3], in: directory, container: .wav)
        let volumes = try await AudiobookJoiner().join(
            parts: sources, marks: [AudiobookChapterMark(title: "All", startSeconds: 0)],
            workDirectory: directory.appendingPathComponent("work"))
        #expect(volumes.count == 1)
        #expect(abs(volumes[0].durationSeconds - 5) < 0.1)
        let track = try #require(try await AVURLAsset(url: volumes[0].url).loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mFormatID == kAudioFormatMPEG4AAC)
    }

    @Test func failureAndCancellationLeaveNoOutputFiles() async throws {
        let directory = try AudiobookTestAudio.ownedDirectory("joiner-fail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = directory.appendingPathComponent("work")
        let bogus = directory.appendingPathComponent("bogus.m4a")
        try Data("not audio".utf8).write(to: bogus)
        await #expect(throws: AudiobookJoinerError.self) {
            try await AudiobookJoiner().join(parts: [bogus], marks: [], workDirectory: work)
        }
        let sources = try parts([20], in: directory)
        let task = Task {
            try await AudiobookJoiner().join(
                parts: sources, marks: [AudiobookChapterMark(title: "A", startSeconds: 0)], workDirectory: work)
        }
        task.cancel()
        _ = try? await task.value
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    // MARK: Size policy

    private let marks = (0..<6).map { AudiobookChapterMark(title: "Chapter \($0 + 1)", startSeconds: Double($0) * 5) }

    @Test func planPicksPassthroughThenQualityThenMonoThenVolumes() {
        let limit: Int64 = 1_000_000
        func plan(_ duration: Double, bytes: Int64, aac: Bool = true) -> AudiobookJoinPlan {
            AudiobookJoiner.makePlan(
                totalDuration: duration, sourceBytes: bytes, passthroughEligible: aac, sourceChannels: 2,
                marks: [], byteLimit: limit)
        }
        #expect(plan(40, bytes: 400_000).encoding == .passthrough)
        // AAC that does not fit, and non-AAC that does: re-encode at normal quality.
        #expect(plan(40, bytes: 900_000).encoding == .aac(bitRate: 128_000, channels: 2, sampleRate: 44_100))
        #expect(plan(40, bytes: 400_000, aac: false).encoding != .passthrough)
        // Too long for stereo 128k but fitting mono: the highest bitrate that fits, mono.
        let mono = plan(120, bytes: 5_000_000)
        guard case let .aac(bitRate, channels, _) = mono.encoding else {
            Issue.record("expected AAC")
            return
        }
        #expect(channels == 1 && bitRate >= 32_000 && bitRate % 8_000 == 0 && mono.spans.count == 1)
        #expect(Double(bitRate) / 8 * 120 <= Double(limit) * 0.85)
        // Beyond 32 kbps: volumes.
        let split = plan(3_000, bytes: 50_000_000)
        #expect(split.encoding == .aac(bitRate: 32_000, channels: 1, sampleRate: 22_050))
        #expect(split.spans.count > 1)
    }

    @Test func volumesCutAtChapterStartsAndInsideAChapterOnlyWhenNeeded() {
        let atChapters = AudiobookJoiner.volumeSpans(totalDuration: 30, maxVolume: 12.75, marks: marks)
        #expect(atChapters.map(\.start) == [0, 10, 20])
        #expect(atChapters.last?.end == 30)
        let chapterless = AudiobookJoiner.volumeSpans(
            totalDuration: 40, maxVolume: 12.75, marks: [AudiobookChapterMark(title: "Only", startSeconds: 0)])
        #expect(chapterless.count == 4)
        let second = AudiobookJoiner.chapters(in: chapterless[1], from: [AudiobookChapterMark(title: "Only", startSeconds: 0)])
        #expect(second == [AudiobookChapterMark(title: "Only", startSeconds: 0)])
        let boundary = AudiobookJoiner.chapters(in: atChapters[1], from: marks)
        #expect(boundary.map(\.startSeconds) == [0, 5])
        #expect(boundary.map(\.title) == ["Chapter 3", "Chapter 4"])
    }
}
