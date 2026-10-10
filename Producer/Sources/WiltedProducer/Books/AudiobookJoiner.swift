import AVFoundation
import CoreMedia
import Foundation

/// One chapter marker of an audiobook volume. The JSON keys match
/// `WiltedLibrary.AudiobookChapter`, which this target cannot import, so the
/// `AudiobookRecord.chapters` blob decodes as the shared type.
public struct AudiobookChapterMark: Codable, Sendable, Equatable {
    public let title: String
    public let startSeconds: Double

    public init(title: String, startSeconds: Double) {
        self.title = title
        self.startSeconds = startSeconds
    }
}

public enum AudiobookJoinerError: Error, Equatable, LocalizedError, Sendable {
    case cancelled
    case noAudio(String)
    case writerFailed(String)
    case outputTooLarge(bytes: Int64, limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "The audiobook join was cancelled."
        case let .noAudio(name): "\(name) has no readable audio."
        case let .writerFailed(reason): "The audiobook could not be written: \(reason)"
        case let .outputTooLarge(bytes, limit): "A joined volume is \(bytes) bytes, over the \(limit) byte limit."
        }
    }
}

/// One finished, complete volume file. The caller owns `url` and must move or delete it.
public struct AudiobookJoinedVolume: Sendable, Equatable {
    public let url: URL
    /// Where this volume starts in the whole book.
    public let startSeconds: Double
    /// Measured from the written file.
    public let durationSeconds: Double
    public let byteCount: Int64
    /// Chapters relative to this volume's own start.
    public let chapters: [AudiobookChapterMark]
}

/// What the joiner knows about one source file before it plans.
struct AudiobookPartInfo: Sendable, Equatable {
    let url: URL
    let durationSeconds: Double
    let byteCount: Int64
    let isAAC: Bool
    let sampleRate: Double
    let channels: Int
}

/// Joins ordered audio files into one m4a with chapter markers, or into volumes when
/// the result would not fit the transfer limit.
///
/// A passthrough copy is used only when every part is AAC with one format and the
/// result fits. Otherwise it re-encodes: normal quality when that fits, mono at the
/// highest bitrate that fits when not, and below `minimumBitRate` it cuts volumes.
public struct AudiobookJoiner: Sendable {
    /// The Mac transfer limit is 250 MiB per item; volumes stay under this.
    public static let defaultVolumeByteLimit: Int64 = 240 * 1024 * 1024
    public static let minimumBitRate = 32_000
    /// Container and priming overhead that the bitrate arithmetic leaves room for.
    static let budgetFraction = 0.85

    public let volumeByteLimit: Int64
    private let inFlightMedia: MediaInFlightRegistry?

    public init(
        volumeByteLimit: Int64 = AudiobookJoiner.defaultVolumeByteLimit,
        inFlightMedia: MediaInFlightRegistry? = nil
    ) {
        self.volumeByteLimit = volumeByteLimit
        self.inFlightMedia = inFlightMedia
    }

    /// Part of every volume ID's layout key: changes whenever volume boundaries or encoding change.
    public var layoutKey: String {
        "audiobook-layout-1|m4a-aac|limit=\(volumeByteLimit)|min-bitrate=\(Self.minimumBitRate)"
    }

    /// Joins `parts` in order into one or more m4a files written under `workDirectory`.
    ///
    /// - Parameters:
    ///   - marks: chapters in whole-book seconds; the first should start at 0.
    ///   - progress: overall fraction 0...1, called from a background thread.
    /// - Returns: complete volume files, in order. On any throw, none remain.
    public func join(
        parts: [URL],
        marks: [AudiobookChapterMark],
        workDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [AudiobookJoinedVolume] {
        var infos: [AudiobookPartInfo] = []
        for url in parts { infos.append(try await Self.inspect(url)) }
        guard !infos.isEmpty else { throw AudiobookJoinerError.noAudio("The book") }
        let total = infos.reduce(0) { $0 + $1.durationSeconds }
        let plan = Self.makePlan(
            totalDuration: total, sourceBytes: infos.reduce(0) { $0 + $1.byteCount },
            passthroughEligible: Self.passthroughEligible(infos),
            sourceChannels: infos.map(\.channels).max() ?? 1,
            marks: marks, byteLimit: volumeByteLimit
        )
        let composition = try await Self.composition(of: infos)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let batch = UUID().uuidString
        var written: [AudiobookJoinedVolume] = []
        do {
            for (index, span) in plan.spans.enumerated() {
                try Task.checkCancellation()
                let url = workDirectory.appendingPathComponent(".audiobook-\(batch)-v\(index).tmp.m4a")
                inFlightMedia?.begin(url)
                let volumeMarks = Self.chapters(in: span, from: marks)
                let count = Double(plan.spans.count)
                let base = Double(index) / count
                try await AudiobookVolumeWriter.write(
                    composition: composition, span: span, encoding: plan.encoding, marks: volumeMarks,
                    to: url, progress: { progress(base + $0 / count) }
                )
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard size <= volumeByteLimit else {
                    try? FileManager.default.removeItem(at: url)
                    inFlightMedia?.end(url)
                    throw AudiobookJoinerError.outputTooLarge(bytes: size, limit: volumeByteLimit)
                }
                let measured = try await AVURLAsset(url: url).load(.duration).seconds
                guard measured.isFinite, measured > 0 else {
                    throw AudiobookJoinerError.writerFailed("the written volume has no duration")
                }
                written.append(AudiobookJoinedVolume(
                    url: url, startSeconds: span.start, durationSeconds: measured,
                    byteCount: size, chapters: volumeMarks
                ))
            }
        } catch {
            for volume in written {
                try? FileManager.default.removeItem(at: volume.url)
                inFlightMedia?.end(volume.url)
            }
            // The failing volume's own temp file: the writer removes it, this ends its registration.
            for index in written.count..<max(plan.spans.count, written.count) {
                let url = workDirectory.appendingPathComponent(".audiobook-\(batch)-v\(index).tmp.m4a")
                try? FileManager.default.removeItem(at: url)
                inFlightMedia?.end(url)
            }
            if error is CancellationError { throw AudiobookJoinerError.cancelled }
            throw error
        }
        return written
    }

    static func inspect(_ url: URL) async throws -> AudiobookPartInfo {
        do { return try await readInfo(url) } catch let error as AudiobookJoinerError { throw error } catch is CancellationError {
            throw AudiobookJoinerError.cancelled
        } catch { throw AudiobookJoinerError.noAudio(url.lastPathComponent) }
    }

    private static func readInfo(_ url: URL) async throws -> AudiobookPartInfo {
        let asset = AVURLAsset(url: url)
        let name = url.lastPathComponent
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudiobookJoinerError.noAudio(name)
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AudiobookJoinerError.noAudio(name) }
        let descriptions = try await track.load(.formatDescriptions)
        let format = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return AudiobookPartInfo(
            url: url, durationSeconds: duration, byteCount: Int64(size),
            isAAC: format?.mFormatID == kAudioFormatMPEG4AAC,
            sampleRate: format?.mSampleRate ?? 0, channels: Int(format?.mChannelsPerFrame ?? 1)
        )
    }

    static func passthroughEligible(_ infos: [AudiobookPartInfo]) -> Bool {
        guard let first = infos.first else { return false }
        return infos.allSatisfy {
            $0.isAAC && $0.sampleRate == first.sampleRate && $0.channels == first.channels
        }
    }

    private static func composition(of infos: [AudiobookPartInfo]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw AudiobookJoinerError.writerFailed("no composition track") }
        var cursor = CMTime.zero
        for info in infos {
            let asset = AVURLAsset(url: info.url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw AudiobookJoinerError.noAudio(info.url.lastPathComponent)
            }
            let duration = try await asset.load(.duration)
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }
        return composition
    }
}

// MARK: - Planning

/// A contiguous slice of the whole book that becomes one volume.
struct AudiobookSpan: Equatable {
    let start: Double
    let end: Double
}

enum AudiobookEncoding: Equatable {
    case passthrough
    case aac(bitRate: Int, channels: Int, sampleRate: Double)
}

struct AudiobookJoinPlan: Equatable {
    let encoding: AudiobookEncoding
    let spans: [AudiobookSpan]
}

extension AudiobookJoiner {
    /// Decides encoding and volume boundaries. Pure, so the policy is testable without audio.
    static func makePlan(
        totalDuration: Double,
        sourceBytes: Int64,
        passthroughEligible: Bool,
        sourceChannels: Int,
        marks: [AudiobookChapterMark],
        byteLimit: Int64
    ) -> AudiobookJoinPlan {
        let budget = Double(byteLimit) * budgetFraction
        let whole = [AudiobookSpan(start: 0, end: totalDuration)]
        if passthroughEligible, Double(sourceBytes) <= budget {
            return AudiobookJoinPlan(encoding: .passthrough, spans: whole)
        }
        let channels = max(1, min(sourceChannels, 2))
        let normal = 64_000 * channels
        if Double(normal) / 8 * totalDuration <= budget {
            return AudiobookJoinPlan(
                encoding: .aac(bitRate: normal, channels: channels, sampleRate: sampleRate(for: normal)), spans: whole
            )
        }
        let fitting = Int(budget * 8 / totalDuration / 8_000) * 8_000
        if fitting >= minimumBitRate {
            let bitRate = min(fitting, 128_000)
            return AudiobookJoinPlan(
                encoding: .aac(bitRate: bitRate, channels: 1, sampleRate: sampleRate(for: bitRate)), spans: whole
            )
        }
        let maxVolume = budget * 8 / Double(minimumBitRate)
        return AudiobookJoinPlan(
            encoding: .aac(bitRate: minimumBitRate, channels: 1, sampleRate: sampleRate(for: minimumBitRate)),
            spans: volumeSpans(totalDuration: totalDuration, maxVolume: maxVolume, marks: marks)
        )
    }

    /// Low bitrates use a lower sample rate: speech loses nothing and the encoder has more bits per frame.
    static func sampleRate(for bitRate: Int) -> Double { bitRate < 48_000 ? 22_050 : 44_100 }

    /// Cuts at the last chapter start that fits each volume, and inside a chapter only when none does.
    static func volumeSpans(totalDuration: Double, maxVolume: Double, marks: [AudiobookChapterMark]) -> [AudiobookSpan] {
        let starts = marks.map(\.startSeconds).filter { $0 > 0 && $0 < totalDuration }.sorted()
        var spans: [AudiobookSpan] = []
        var start = 0.0
        while totalDuration - start > maxVolume {
            let limit = start + maxVolume
            let cut = starts.last(where: { $0 > start && $0 <= limit }) ?? limit
            spans.append(AudiobookSpan(start: start, end: cut))
            start = cut
        }
        spans.append(AudiobookSpan(start: start, end: totalDuration))
        return spans
    }

    /// The chapters of one volume, relative to its start. A chapter that began in an
    /// earlier volume continues here at 0 under the same title.
    static func chapters(in span: AudiobookSpan, from marks: [AudiobookChapterMark]) -> [AudiobookChapterMark] {
        let sorted = marks.sorted { $0.startSeconds < $1.startSeconds }
        let epsilon = 0.0005
        var result: [AudiobookChapterMark] = []
        let startsHere = sorted.contains { abs($0.startSeconds - span.start) <= epsilon }
        if !startsHere, let active = sorted.last(where: { $0.startSeconds < span.start }) {
            result.append(AudiobookChapterMark(title: active.title, startSeconds: 0))
        }
        for mark in sorted where mark.startSeconds >= span.start - epsilon && mark.startSeconds < span.end - epsilon {
            result.append(AudiobookChapterMark(title: mark.title, startSeconds: max(0, mark.startSeconds - span.start)))
        }
        return result
    }
}

// MARK: - Writing

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func raise() { lock.withLock { set = true } }
    var isRaised: Bool { lock.withLock { set } }
}

private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

/// Reads one span of the composition and writes it as a complete m4a with a chapter track.
enum AudiobookVolumeWriter {
    static func write(
        composition: AVMutableComposition,
        span: AudiobookSpan,
        encoding: AudiobookEncoding,
        marks: [AudiobookChapterMark],
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let track = try await composition.loadTracks(withMediaType: .audio).first else {
            throw AudiobookJoinerError.noAudio("composition")
        }
        let hint = try await track.load(.formatDescriptions).first
        let job = Unchecked(value: (composition, track, hint))
        let flag = CancelFlag()
        try await withTaskCancellationHandler {
            try await Task.detached {
                try Self.run(
                    asset: job.value.0, track: job.value.1, hint: job.value.2, span: span, encoding: encoding,
                    marks: marks, url: url, flag: flag, progress: progress
                )
            }.value
        } onCancel: { flag.raise() }
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    private static func run(
        asset: AVAsset, track: AVAssetTrack, hint: CMFormatDescription?, span: AudiobookSpan,
        encoding: AudiobookEncoding, marks: [AudiobookChapterMark], url: URL,
        flag: CancelFlag, progress: @Sendable (Double) -> Void
    ) throws {
        let fail = { (reason: String) -> AudiobookJoinerError in .writerFailed(reason) }
        let reader = try AVAssetReader(asset: asset)
        let range = CMTimeRange(start: time(span.start), end: time(span.end))
        reader.timeRange = range
        let readerSettings: [String: Any]?
        let writerSettings: [String: Any]?
        switch encoding {
        case .passthrough:
            readerSettings = nil; writerSettings = nil
        case let .aac(bitRate, channels, sampleRate):
            readerSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            ]
            writerSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: bitRate,
            ]
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw fail("the source cannot be read") }
        reader.add(output)

        // AVAssetWriter's m4a passthrough rejects the second part's packets (-17545), and so does
        // AVAssetExportSession; the mp4 container takes the same AAC packets. Both are MPEG-4 audio.
        let writer = try AVAssetWriter(outputURL: url, fileType: encoding == .passthrough ? .mp4 : .m4a)
        if let writerSettings, !writer.canApply(outputSettings: writerSettings, forMediaType: .audio) {
            throw fail("the encoder rejects \(writerSettings)")
        }
        let input = AVAssetWriterInput(
            mediaType: .audio, outputSettings: writerSettings, sourceFormatHint: writerSettings == nil ? hint : nil
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw fail("the output cannot take audio") }
        writer.add(input)

        guard reader.startReading() else { throw fail(reader.error?.localizedDescription ?? "reading failed") }
        guard writer.startWriting() else { throw fail(writer.error?.localizedDescription ?? "writing failed") }
        writer.startSession(atSourceTime: range.start)
        var published = false
        defer {
            if writer.status == .writing { writer.cancelWriting() }
            if !published { try? FileManager.default.removeItem(at: url) }
        }

        let length = max(span.end - span.start, 0.001)
        var finishedReading = false
        while !finishedReading {
            if flag.isRaised || Task.isCancelled {
                reader.cancelReading()
                throw AudiobookJoinerError.cancelled
            }
            guard input.isReadyForMoreMediaData else {
                if writer.status == .failed { throw fail(writer.error?.localizedDescription ?? "writing failed") }
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            if let buffer = output.copyNextSampleBuffer() {
                guard input.append(buffer) else { throw fail(writer.error?.localizedDescription ?? "audio write failed") }
                progress(min(1, max(0, (CMSampleBufferGetPresentationTimeStamp(buffer).seconds - span.start) / length)))
            } else {
                finishedReading = true
            }
        }
        if reader.status == .failed { throw fail(reader.error?.localizedDescription ?? "reading failed") }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else { throw fail(writer.error?.localizedDescription ?? "the file did not finish") }
        try AudiobookChapterTrack.embed(marks, in: url)
        published = true
        progress(1)
    }
}
