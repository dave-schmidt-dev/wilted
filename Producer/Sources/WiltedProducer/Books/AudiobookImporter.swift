import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import WiltedDomain

public struct AudiobookImportProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case checking, reading, joining, saving }
    public let stage: Stage
    /// 0...1 across the whole import.
    public let fraction: Double
    public let detail: String
}

public enum AudiobookImportError: Error, Equatable, LocalizedError, Sendable {
    case noAudio
    case unsupportedInput(String)
    case protectedContent(file: String)
    case unreadable(file: String, reason: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noAudio: "There is no audio to import."
        case let .unsupportedInput(reason): reason
        case let .protectedContent(file): "\(file) is copy-protected and cannot be imported."
        case let .unreadable(file, reason): "\(file) cannot be read: \(reason)"
        case .cancelled: "The audiobook import was cancelled."
        }
    }
}

public struct AudiobookImportResult: Sendable, Equatable {
    /// Volume item IDs in order.
    public let itemIDs: [ItemID]
    /// True when every volume of this content and layout was already in the library.
    public let alreadyImported: Bool
}

/// Imports audio files (or one folder of them) as one audiobook, in volumes when it is too
/// big to transfer. Each volume is its own Larder item.
///
/// Nothing is written until every file has passed the protected-content and readability
/// checks. Media is joined in the store's media folder, moved into its final place, and only
/// then are all volumes committed in one store save; any failure or cancellation removes
/// every file this import wrote.
public struct AudiobookImporter: Sendable {
    private let store: LocalLibraryStore
    private let joiner: AudiobookJoiner
    private let isProtected: @Sendable (URL) async throws -> Bool
    private let afterMediaPlaced: (@Sendable (Int) throws -> Void)?

    /// - Parameters:
    ///   - volumeByteLimit: size each volume stays under; the default is 240 MiB, below the 250 MiB transfer limit.
    ///   - protectedContentCheck: replaceable so tests can present protected content; the default asks AVFoundation.
    public init(
        store: LocalLibraryStore,
        volumeByteLimit: Int64 = AudiobookJoiner.defaultVolumeByteLimit,
        protectedContentCheck: @escaping @Sendable (URL) async throws -> Bool = { url in
            try await AVURLAsset(url: url).load(.hasProtectedContent)
        }
    ) {
        self.init(store: store, volumeByteLimit: volumeByteLimit, protectedContentCheck: protectedContentCheck,
                  afterMediaPlaced: nil)
    }

    /// Test seam: `afterMediaPlaced` runs after each volume's media is in its final place.
    init(
        store: LocalLibraryStore,
        volumeByteLimit: Int64,
        protectedContentCheck: @escaping @Sendable (URL) async throws -> Bool,
        afterMediaPlaced: (@Sendable (Int) throws -> Void)?
    ) {
        self.store = store
        self.joiner = AudiobookJoiner(volumeByteLimit: volumeByteLimit, inFlightMedia: store.inFlightMedia)
        self.isProtected = protectedContentCheck
        self.afterMediaPlaced = afterMediaPlaced
    }

    /// - Parameters:
    ///   - inputs: audio files, or exactly one folder; taken in natural filename order.
    ///   - title: overrides the title read from the files.
    public func importBook(
        from inputs: [URL],
        title overrideTitle: String? = nil,
        progress: @escaping @Sendable (AudiobookImportProgress) -> Void = { _ in }
    ) async throws -> AudiobookImportResult {
        do {
            return try await run(inputs, title: overrideTitle, progress: progress)
        } catch is CancellationError {
            throw AudiobookImportError.cancelled
        } catch AudiobookJoinerError.cancelled {
            throw AudiobookImportError.cancelled
        }
    }

    private func run(
        _ inputs: [URL], title overrideTitle: String?, progress: @escaping @Sendable (AudiobookImportProgress) -> Void
    ) async throws -> AudiobookImportResult {
        let report: @Sendable (AudiobookImportProgress.Stage, Double, String) -> Void = { stage, fraction, detail in
            progress(AudiobookImportProgress(stage: stage, fraction: fraction, detail: detail))
        }
        report(.checking, 0, "Checking files")
        let source = try Self.resolve(inputs)
        let book = try await inspect(source.files) { report(.checking, 0.05 * $0, "Checking files") }

        var hasher = AudiobookContentHasher()
        try Self.digest(source.files, into: &hasher) { report(.reading, 0.05 + 0.15 * $0, "Reading files") }
        let digest = hasher.finalize()
        let layout = joiner.layoutKey
        if try await store.hasCompleteAudiobook(contentDigest: digest, layout: layout) {
            let first = try await store.audiobook(ItemID.audiobook(contentDigest: digest, layout: layout, volume: 0))
            let ids = try (0..<(first?.volumeCount ?? 1)).map {
                try ItemID.audiobook(contentDigest: digest, layout: layout, volume: $0)
            }
            report(.saving, 1, "Already in the library")
            return AudiobookImportResult(itemIDs: ids, alreadyImported: true)
        }

        let media = store.mediaDirectory
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let volumes = try await joiner.join(
            parts: source.files, marks: book.marks, workDirectory: media
        ) { report(.joining, 0.2 + 0.7 * $0, "Joining audio") }

        var placed: [URL] = []
        var saved = false
        defer {
            // Unmoved temp files always go; placed files go unless the save made records name them.
            for volume in volumes { try? FileManager.default.removeItem(at: volume.url); store.inFlightMedia.end(volume.url) }
            for url in placed {
                if !saved { try? FileManager.default.removeItem(at: url) }
                store.inFlightMedia.end(url)
            }
        }
        do {
            try Task.checkCancellation()
            let bookTitle = overrideTitle ?? book.title ?? source.folderName ?? book.fallbackTitle
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
                try afterMediaPlaced?(index)
                saves.append(AudiobookVolumeSave(
                    itemID: itemID, revision: try Self.revision(itemID, volume, hash: hash, createdAt: createdAt),
                    mediaURL: destination,
                    title: volumes.count > 1 ? "\(bookTitle) (\(index + 1) of \(volumes.count))" : bookTitle,
                    author: book.author, chapters: volume.chapters, sourceFormat: "audio",
                    volumeIndex: index, volumeCount: volumes.count, createdAt: createdAt
                ))
            }
            try Task.checkCancellation()
            report(.saving, 0.95, "Saving to library")
            try await store.saveAudiobookVolumes(saves)
            saved = true
            report(.saving, 1, "Saved")
            return AudiobookImportResult(itemIDs: saves.map(\.itemID), alreadyImported: false)
        }
    }

    // MARK: Inputs

    private struct Source { let files: [URL]; let folderName: String? }

    /// Files in natural filename order. A folder is expanded (audio files only); mixing is refused.
    private static func resolve(_ inputs: [URL]) throws -> Source {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard !inputs.isEmpty else { throw AudiobookImportError.noAudio }
        if inputs.count == 1, manager.fileExists(atPath: inputs[0].path, isDirectory: &isDirectory), isDirectory.boolValue {
            let contents = try manager.contentsOfDirectory(
                at: inputs[0], includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            )
            let files = contents.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && isAudio($0)
            }
            guard !files.isEmpty else { throw AudiobookImportError.noAudio }
            return Source(files: naturallyOrdered(files), folderName: inputs[0].lastPathComponent)
        }
        for url in inputs {
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw AudiobookImportError.unreadable(file: url.lastPathComponent, reason: "it does not exist")
            }
            guard !isDirectory.boolValue else {
                throw AudiobookImportError.unsupportedInput("Import either audio files or one folder, not both.")
            }
            guard isAudio(url) else {
                throw AudiobookImportError.unreadable(file: url.lastPathComponent, reason: "it is not an audio file")
            }
        }
        return Source(files: naturallyOrdered(inputs), folderName: nil)
    }

    private static func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }

    private static func naturallyOrdered(_ files: [URL]) -> [URL] {
        files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Inspection

    private struct Book {
        let marks: [AudiobookChapterMark]
        let title: String?
        let author: String?
        let fallbackTitle: String
    }

    /// Protected-content and readability checks for every file, then chapters and descriptive metadata.
    private func inspect(_ files: [URL], progress: @Sendable (Double) -> Void) async throws -> Book {
        var infos: [AudiobookPartInfo] = []
        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            do {
                if try await isProtected(url) { throw AudiobookImportError.protectedContent(file: name) }
                infos.append(try await AudiobookJoiner.inspect(url))
            } catch let error as AudiobookImportError {
                throw error
            } catch is CancellationError {
                throw AudiobookImportError.cancelled
            } catch {
                throw AudiobookImportError.unreadable(file: name, reason: error.localizedDescription)
            }
            progress(Double(index + 1) / Double(files.count))
        }
        let metadata = try await Self.metadata(of: files[0])
        let stem = files[0].deletingPathExtension().lastPathComponent
        if files.count == 1 {
            let chapters = try await Self.chapters(of: files[0])
            let marks = chapters.isEmpty ? [AudiobookChapterMark(title: metadata.title ?? stem, startSeconds: 0)] : chapters
            return Book(marks: marks, title: metadata.album ?? metadata.title, author: metadata.artist, fallbackTitle: stem)
        }
        var marks: [AudiobookChapterMark] = []
        var start = 0.0
        for (info, url) in zip(infos, files) {
            let title = try await Self.metadata(of: url).title ?? url.deletingPathExtension().lastPathComponent
            marks.append(AudiobookChapterMark(title: title, startSeconds: start))
            start += info.durationSeconds
        }
        return Book(marks: marks, title: metadata.album, author: metadata.artist, fallbackTitle: stem)
    }

    private struct Metadata { var title: String?; var album: String?; var artist: String? }

    private static func metadata(of url: URL) async throws -> Metadata {
        let items = try await AVURLAsset(url: url).load(.commonMetadata)
        func value(_ identifier: AVMetadataIdentifier) async throws -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
                  let text = try await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
        return Metadata(
            title: try await value(.commonIdentifierTitle), album: try await value(.commonIdentifierAlbumName),
            artist: try await value(.commonIdentifierArtist)
        )
    }

    /// Chapter markers from the file's chapter metadata, empty when it has none.
    static func chapters(of url: URL) async throws -> [AudiobookChapterMark] {
        let asset = AVURLAsset(url: url)
        guard let locale = try await asset.load(.availableChapterLocales).first else { return [] }
        var marks: [AudiobookChapterMark] = []
        for (index, group) in try await asset.loadChapterMetadataGroups(withTitleLocale: locale).enumerated() {
            let titled = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle)
            let title = try await (titled.first ?? group.items.first)?.load(.stringValue)
            marks.append(AudiobookChapterMark(
                title: title?.isEmpty == false ? title! : "Chapter \(index + 1)",
                startSeconds: index == 0 ? 0 : group.timeRange.start.seconds
            ))
        }
        return marks
    }

    // MARK: Hashing and revisions

    private static func digest(
        _ files: [URL], into hasher: inout AudiobookContentHasher, progress: (Double) -> Void
    ) throws {
        for (index, url) in files.enumerated() {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            hasher.beginFile(length: try handle.seekToEnd())
            try handle.seek(toOffset: 0)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.append(chunk)
            }
            progress(Double(index + 1) / Double(files.count))
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The revision is keyed by the volume's item and its bytes, so identical audio under two
    /// layouts never shares a revision ID.
    private static func revision(
        _ itemID: ItemID, _ volume: AudiobookJoinedVolume, hash: String, createdAt: Date
    ) throws -> AudioRevision {
        try AudioRevision(
            itemID: itemID,
            revisionID: RevisionID.derive(
                extractedTextSHA256: hash, voiceID: itemID.rawValue, synthesisSettingsCanonicalJSON: "{}",
                audioFormatCanonicalJSON: "{\"container\":\"m4a\",\"source\":\"audiobook-import\"}"
            ),
            durationSeconds: volume.durationSeconds, byteCount: volume.byteCount,
            contentHash: "sha256:\(hash)", mediaType: AudioAssembler.mediaType,
            createdAt: Timestamp(createdAt), schemaVersion: 1
        )
    }
}
