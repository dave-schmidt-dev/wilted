import AVFoundation
import CryptoKit
import Foundation
import WiltedDomain

public struct BookConversionProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case reading, synthesizing, joining, saving }
    public let stage: Stage
    /// 1-based chapter being synthesized; 0 outside the synthesizing stage.
    public let chapter: Int
    public let chapterCount: Int
    /// 0...1 across the whole conversion.
    public let fraction: Double
    public let detail: String
}

public enum BookConversionError: Error, Equatable, LocalizedError, Sendable {
    case cancelled

    public var errorDescription: String? { "The book conversion was cancelled." }
}

/// Turns an EPUB or PDF into an audiobook: each chapter is synthesized to its own file in a
/// per-book work folder, then the files are joined and saved like an imported audiobook.
///
/// A chapter file appears in the work folder only when it is complete, and the folder's
/// manifest records each finished chapter's SHA-256. A rerun after a stop or a crash keeps a
/// chapter only when the manifest key (source digest, split size, voice and settings) still
/// matches and the file still hashes to the recorded value; anything else is synthesized again.
/// The work folder is removed once the book is saved.
public struct BookConversion: Sendable {
    /// Turns text into samples. `isCancelled` becomes true when the conversion is cancelled.
    public typealias Synthesizer = @Sendable (_ text: String, _ isCancelled: @escaping @Sendable () -> Bool) throws -> SpeechSynthesisResult

    /// The voice identity recorded when none is configured: the speech daemon's own default.
    public static let daemonDefaultVoice = "daemon-default"

    private let store: LocalLibraryStore
    private let extractor: BookTextExtractor
    private let synthesize: Synthesizer
    private let voice: String
    private let settings: String
    private let workRoot: URL
    private let volumeByteLimit: Int64

    /// - Parameters:
    ///   - voice: identity string recorded in the manifest key; the speech client has no voice parameter yet.
    ///   - settings: canonical JSON of the synthesis settings, also part of the manifest key.
    ///   - workRoot: where per-book work folders live; beside the library when nil.
    ///   - synthesize: replaceable so tests never reach the real speech daemon.
    public init(
        store: LocalLibraryStore,
        extractor: BookTextExtractor = BookTextExtractor(),
        voice: String = BookConversion.daemonDefaultVoice,
        settings: String = "{}",
        workRoot: URL? = nil,
        volumeByteLimit: Int64 = AudiobookJoiner.defaultVolumeByteLimit,
        synthesize: @escaping Synthesizer = BookConversion.daemonSynthesizer
    ) {
        self.store = store
        self.extractor = extractor
        self.voice = voice
        self.settings = settings
        self.workRoot = workRoot ?? store.mediaDirectory.deletingLastPathComponent().appendingPathComponent("book-work", isDirectory: true)
        self.volumeByteLimit = volumeByteLimit
        self.synthesize = synthesize
    }

    /// The speech daemon at its default socket.
    public static let daemonSynthesizer: Synthesizer = { text, isCancelled in
        try SpeechIPCClient(
            socketPath: PreparationCoordinator.defaultSocketURL.path, connectTimeout: 2,
            operationTimeout: PreparationCoordinator.defaultSpeechOperationTimeout
        ).synthesize(text: text, isCancelled: isCancelled)
    }

    // MARK: Manifest

    struct Manifest: Codable, Equatable {
        struct Chapter: Codable, Equatable {
            let index: Int
            let title: String
            let textSHA256: String
            let file: String
            let audioSHA256: String
            let durationSeconds: Double
        }

        var version = 1
        let sourceDigest: String
        let splitWords: Int
        let voice: String
        let settings: String
        var chapters: [Chapter] = []

        func sameKey(as other: Manifest) -> Bool {
            version == other.version && sourceDigest == other.sourceDigest && splitWords == other.splitWords
                && voice == other.voice && settings == other.settings
        }
    }

    static let manifestName = "manifest.json"

    // MARK: Convert

    public func convert(
        from url: URL,
        title overrideTitle: String? = nil,
        progress: @escaping @Sendable (BookConversionProgress) -> Void = { _ in }
    ) async throws -> AudiobookImportResult {
        do {
            return try await run(url, title: overrideTitle, progress: progress)
        } catch is CancellationError {
            throw BookConversionError.cancelled
        } catch BookExtractionError.cancelled {
            throw BookConversionError.cancelled
        } catch AudioAssemblerError.cancelled {
            throw BookConversionError.cancelled
        } catch AudiobookJoinerError.cancelled {
            throw BookConversionError.cancelled
        }
    }

    private func run(
        _ url: URL, title overrideTitle: String?, progress: @escaping @Sendable (BookConversionProgress) -> Void
    ) async throws -> AudiobookImportResult {
        @Sendable func report(_ stage: BookConversionProgress.Stage, _ fraction: Double, _ detail: String, chapter: Int = 0, of count: Int = 0) {
            progress(BookConversionProgress(stage: stage, chapter: chapter, chapterCount: count, fraction: fraction, detail: detail))
        }
        report(.reading, 0, "Reading the book")
        let digest = try Self.sourceDigest(of: url)
        let joiner = AudiobookJoiner(volumeByteLimit: volumeByteLimit, inFlightMedia: store.inFlightMedia)
        let voiceKey = SHA256.hash(data: Data("\(voice)\0\(settings)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let layout = "\(joiner.layoutKey)|book-1|split=\(extractor.splitWords)|voice=\(voiceKey)"
        if try await store.hasCompleteAudiobook(contentDigest: digest, layout: layout) {
            let first = try await store.audiobook(ItemID.audiobook(contentDigest: digest, layout: layout, volume: 0))
            report(.saving, 1, "Already in the library")
            return AudiobookImportResult(
                itemIDs: try (0..<(first?.volumeCount ?? 1)).map { try ItemID.audiobook(contentDigest: digest, layout: layout, volume: $0) },
                alreadyImported: true)
        }

        let extractor = self.extractor
        let book = try await Self.blocking {
            try extractor.extract(from: url, progress: { fraction, detail in report(.reading, 0.05 * fraction, detail) })
        }
        let count = book.chapters.count
        let totalWords = max(book.chapters.reduce(0) { $0 + BookTextExtractor.wordCount($1.text) }, 1)

        let work = workRoot.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var manifest = try loadManifest(in: work, digest: digest)

        var files: [URL] = []
        var marks: [AudiobookChapterMark] = []
        var elapsed = 0.0
        var wordsDone = 0
        for (index, chapter) in book.chapters.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            let words = BookTextExtractor.wordCount(chapter.text)
            let textHash = Self.sha256(Data(chapter.text.utf8))
            let fraction = { min(0.05 + 0.8 * Double(wordsDone + $0) / Double(totalWords), 0.85) }
            let file = work.appendingPathComponent(String(format: "chapter-%04d.m4a", number))
            let entry: Manifest.Chapter
            if let kept = manifest.chapters.first(where: { $0.index == index }), kept.textSHA256 == textHash,
               kept.file == file.lastPathComponent, (try? Self.sha256(of: file)) == kept.audioSHA256 {
                entry = kept
                report(.synthesizing, fraction(words), "Chapter \(number) of \(count) already converted", chapter: number, of: count)
            } else {
                report(.synthesizing, fraction(0), "Converting chapter \(number) of \(count): \(chapter.title)", chapter: number, of: count)
                try? FileManager.default.removeItem(at: file)
                manifest.chapters.removeAll { $0.index == index }
                let synthesize = self.synthesize
                let speech = try await Self.blocking { try synthesize(chapter.text, { Task.isCancelled }) }
                let duration = try await Self.blocking { try Self.writeChapterAudio(speech, to: file) }
                entry = Manifest.Chapter(
                    index: index, title: chapter.title, textSHA256: textHash, file: file.lastPathComponent,
                    audioSHA256: try Self.sha256(of: file), durationSeconds: duration)
                manifest.chapters.append(entry)
                try save(manifest, in: work)
                report(.synthesizing, fraction(words), "Converted chapter \(number) of \(count)", chapter: number, of: count)
            }
            files.append(file)
            marks.append(AudiobookChapterMark(title: chapter.title, startSeconds: elapsed))
            elapsed += entry.durationSeconds
            wordsDone += words
        }

        report(.joining, 0.85, "Joining chapters")
        let media = store.mediaDirectory
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let volumes = try await joiner.join(parts: files, marks: marks, workDirectory: media) {
            report(.joining, 0.85 + 0.1 * $0, "Joining chapters")
        }

        var placed: [URL] = []
        var saved = false
        defer {
            for volume in volumes { try? FileManager.default.removeItem(at: volume.url); store.inFlightMedia.end(volume.url) }
            for url in placed {
                if !saved { try? FileManager.default.removeItem(at: url) }
                store.inFlightMedia.end(url)
            }
        }
        try Task.checkCancellation()
        let bookTitle = overrideTitle ?? book.title ?? url.deletingPathExtension().lastPathComponent
        let createdAt = Date()
        var saves: [AudiobookVolumeSave] = []
        for (index, volume) in volumes.enumerated() {
            try Task.checkCancellation()
            let itemID = try ItemID.audiobook(contentDigest: digest, layout: layout, volume: index)
            let hash = try Self.sha256(of: volume.url)
            let destination = media.appendingPathComponent("audiobook-\(itemID.rawValue)-\(UUID().uuidString).m4a")
            store.inFlightMedia.begin(destination)
            placed.append(destination)
            try FileManager.default.moveItem(at: volume.url, to: destination)
            saves.append(AudiobookVolumeSave(
                itemID: itemID, revision: try Self.revision(itemID, volume, hash: hash, createdAt: createdAt),
                mediaURL: destination,
                title: volumes.count > 1 ? "\(bookTitle) (\(index + 1) of \(volumes.count))" : bookTitle,
                author: book.author, chapters: volume.chapters, sourceFormat: book.format,
                volumeIndex: index, volumeCount: volumes.count, createdAt: createdAt))
        }
        report(.saving, 0.97, "Saving to library")
        try await store.saveAudiobookVolumes(saves)
        saved = true
        try? FileManager.default.removeItem(at: work)
        report(.saving, 1, "Saved")
        return AudiobookImportResult(itemIDs: saves.map(\.itemID), alreadyImported: false)
    }

    // MARK: Work folder

    /// The folder's manifest when its key matches this run; otherwise a fresh one and an empty folder.
    private func loadManifest(in work: URL, digest: String) throws -> Manifest {
        let fresh = Manifest(sourceDigest: digest, splitWords: extractor.splitWords, voice: voice, settings: settings)
        let url = work.appendingPathComponent(Self.manifestName)
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Manifest.self, from: data), stored.sameKey(as: fresh) {
            return stored
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [] {
            try FileManager.default.removeItem(at: work.appendingPathComponent(name))
        }
        try save(fresh, in: work)
        return fresh
    }

    private func save(_ manifest: Manifest, in work: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: work.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    // MARK: Helpers

    /// Encodes one chapter as mono AAC at the speech rate (no resampling) into a temp file whose
    /// name ends in `.m4a`, then renames it to `destination` once it has been read back whole.
    /// The temp name matters: `AVAudioFile` picks the container from the extension, and a
    /// file written under another extension is not readable by `AVURLAsset` after a rename.
    /// Returns the duration of the finished file in seconds.
    private static func writeChapterAudio(_ speech: SpeechSynthesisResult, to destination: URL) throws -> Double {
        guard !speech.samples.isEmpty, speech.sampleRate > 0, speech.samples.allSatisfy(\.isFinite) else {
            throw AudioAssemblerError.invalidPCM("the speech result has no usable samples")
        }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).tmp.m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        let rate = Double(speech.sampleRate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw AudioAssemblerError.invalidPCM("could not create the PCM format")
        }
        do {
            let file = try AVAudioFile(forWriting: temp, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            var offset = 0
            while offset < speech.samples.count {
                if Task.isCancelled { throw AudioAssemblerError.cancelled }
                let count = min(1 << 14, speech.samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else {
                    throw AudioAssemblerError.invalidPCM("could not allocate a PCM chunk")
                }
                buffer.frameLength = AVAudioFrameCount(count)
                speech.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!.advanced(by: offset), count: count) }
                try file.write(from: buffer)
                offset += count
            }
        }
        let expected = Double(speech.samples.count) / rate
        let written = try AVAudioFile(forReading: temp)
        let duration = Double(written.length) / written.processingFormat.sampleRate
        guard duration.isFinite, abs(duration - expected) <= max(0.2, expected * 0.02) else {
            throw AudioAssemblerError.invalidAudio("the chapter file is \(duration) s, expected \(expected) s")
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        return duration
    }

    /// Runs blocking work off the cooperative pool and cancels it with the calling task.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached { try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func sourceDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = AudiobookContentHasher()
        hasher.beginFile(length: try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.append(chunk)
        }
        return hasher.finalize()
    }

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func revision(
        _ itemID: ItemID, _ volume: AudiobookJoinedVolume, hash: String, createdAt: Date
    ) throws -> AudioRevision {
        try AudioRevision(
            itemID: itemID,
            revisionID: RevisionID.derive(
                extractedTextSHA256: hash, voiceID: itemID.rawValue, synthesisSettingsCanonicalJSON: "{}",
                audioFormatCanonicalJSON: "{\"container\":\"m4a\",\"source\":\"book-conversion\"}"
            ),
            durationSeconds: volume.durationSeconds, byteCount: volume.byteCount,
            contentHash: "sha256:\(hash)", mediaType: AudioAssembler.mediaType,
            createdAt: Timestamp(createdAt), schemaVersion: 1
        )
    }
}
