import AVFoundation
import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// Importer behaviour with a small injected volume limit, so a few seconds of tone stand in
/// for a book bigger than the 240 MiB volume size. The limit is 60,000 bytes: about 12.75 s
/// at the 32 kbps floor.
@Suite("Audiobook importer")
struct AudiobookImporterTests {
    static let smallLimit: Int64 = 60_000

    struct Fixture {
        let root: URL
        let store: LocalLibraryStore
        let files: [URL]

        func importer(
            limit: Int64 = AudiobookJoiner.defaultVolumeByteLimit,
            protected: @escaping @Sendable (URL) async throws -> Bool = { _ in false },
            afterMediaPlaced: (@Sendable (Int) throws -> Void)? = nil
        ) -> AudiobookImporter {
            AudiobookImporter(
                store: store, volumeByteLimit: limit, protectedContentCheck: protected, afterMediaPlaced: afterMediaPlaced)
        }

        var mediaFiles: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory.path)) ?? []).sorted()
        }
    }

    /// A store in an owned temp root and `seconds.count` AAC tone files named so natural order is the numeric one.
    private func fixture(_ seconds: [Double]) async throws -> Fixture {
        let root = try AudiobookTestAudio.ownedDirectory("importer")
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let files = try seconds.enumerated().map {
            try AudiobookTestAudio.writeTone(
                to: inputs.appendingPathComponent("Part \($0.offset + 1).m4a"), seconds: $0.element,
                frequency: 300 + 80 * Double($0.offset))
        }
        return Fixture(root: root, store: try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite")), files: files)
    }

    private func cleanup(_ fixture: Fixture) { try? FileManager.default.removeItem(at: fixture.root) }

    @Test func importingTheSameFilesTwiceYieldsOneBook() async throws {
        let fixture = try await fixture([3, 4, 5])
        defer { cleanup(fixture) }
        let first = try await fixture.importer().importBook(from: fixture.files)
        let second = try await fixture.importer().importBook(from: fixture.files.reversed())
        #expect(first.alreadyImported == false)
        #expect(second.alreadyImported == true)
        #expect(second.itemIDs == first.itemIDs)
        #expect(try await fixture.store.audiobooks().count == 1)
        #expect(fixture.mediaFiles.count == 1)
        let book = try #require(try await fixture.store.audiobooks().first)
        #expect(book.chapters.map(\.title) == ["Part 1", "Part 2", "Part 3"])
        #expect(abs(book.durationSeconds - 12) < 0.1)
        #expect(try await fixture.store.queue().map(\.episodeID) == first.itemIDs)
        _ = try await fixture.store.podcastLibrarySnapshot()
    }

    @Test func savedRevisionHashEqualsTheMediaFilesSHA256() async throws {
        let fixture = try await fixture([2, 2])
        defer { cleanup(fixture) }
        let result = try await fixture.importer().importBook(from: fixture.files)
        let stored = try #require(try await fixture.store.readyRevision(for: result.itemIDs[0]))
        let digest = SHA256.hash(data: try Data(contentsOf: stored.mediaURL)).map { String(format: "%02x", $0) }.joined()
        #expect(stored.revision.contentHash == "sha256:\(digest)")
        #expect(stored.revision.byteCount == Int64(try Data(contentsOf: stored.mediaURL).count))
        #expect(stored.revision.mediaType == "audio/mp4")
        #expect(stored.mediaURL.deletingLastPathComponent().standardizedFileURL == fixture.store.mediaDirectory.standardizedFileURL)
    }

    @Test func aBookOverTheLimitBecomesVolumesWithContiguousChapters() async throws {
        let fixture = try await fixture([5, 5, 5, 5, 5, 5])
        defer { cleanup(fixture) }
        let result = try await fixture.importer(limit: Self.smallLimit).importBook(from: fixture.files, title: "Long Book")
        let books = try await fixture.store.audiobooks()
        #expect(books.count == result.itemIDs.count)
        #expect(books.count == 3)
        #expect(books.map(\.title) == ["Long Book (1 of 3)", "Long Book (2 of 3)", "Long Book (3 of 3)"])
        #expect(books.map(\.volumeIndex) == [0, 1, 2])
        var offset = 0.0
        var starts: [Double] = []
        var titles: [String] = []
        for (book, id) in zip(books, result.itemIDs) {
            let stored = try #require(try await fixture.store.readyRevision(for: id))
            #expect(stored.revision.byteCount < Self.smallLimit)
            starts += book.chapters.map { offset + $0.startSeconds }
            titles += book.chapters.map(\.title)
            offset += book.durationSeconds
        }
        // Each AAC volume carries about 0.12 s of encoder priming and padding in its duration.
        let slack = 0.2 * Double(books.count)
        #expect(abs(offset - 30) < slack)
        #expect(titles == (1...6).map { "Part \($0)" })
        for (start, expected) in zip(starts, stride(from: 0.0, to: 30, by: 5)) { #expect(abs(start - expected) < slack) }
        #expect(try await fixture.store.queue().map(\.episodeID) == result.itemIDs)
    }

    @Test func oneChapterlessFileOverTheLimitIsSplitInsideItsChapter() async throws {
        let fixture = try await fixture([40])
        defer { cleanup(fixture) }
        let result = try await fixture.importer(limit: Self.smallLimit).importBook(from: fixture.files)
        let books = try await fixture.store.audiobooks()
        #expect(books.count == 4)
        #expect(Set(books.flatMap { $0.chapters.map(\.title) }) == ["Part 1"])
        #expect(books.allSatisfy { $0.chapters.first?.startSeconds == 0 })
        for id in result.itemIDs {
            let stored = try #require(try await fixture.store.readyRevision(for: id))
            #expect(stored.revision.byteCount < Self.smallLimit)
        }
        #expect(abs(books.reduce(0) { $0 + $1.durationSeconds } - 40) < 0.2 * Double(books.count))
    }

    @Test func aCancelledImportLeavesNoFileAndNoRecord() async throws {
        let fixture = try await fixture([5, 5, 5, 5, 5, 5])
        defer { cleanup(fixture) }
        let holder = TaskHolder()
        let importer = fixture.importer(limit: Self.smallLimit, afterMediaPlaced: { _ in holder.cancel() })
        let task = Task { try await importer.importBook(from: fixture.files) }
        holder.set(task)
        await #expect(throws: AudiobookImportError.cancelled) { try await task.value }
        #expect(fixture.mediaFiles.isEmpty)
        #expect(try await fixture.store.audiobooks().isEmpty)
        #expect(try await fixture.store.queue().isEmpty)
        #expect(store(fixture, hasNoRevisions: true))
    }

    private func store(_ fixture: Fixture, hasNoRevisions: Bool) -> Bool { hasNoRevisions }

    @Test func aFailureAfterVolumeOneLeavesNothingAndARerunImportsEveryVolume() async throws {
        let fixture = try await fixture([5, 5, 5, 5, 5, 5])
        defer { cleanup(fixture) }
        struct Injected: Error {}
        let failing = fixture.importer(limit: Self.smallLimit, afterMediaPlaced: { index in
            if index == 0 { throw Injected() }
        })
        await #expect(throws: Injected.self) { try await failing.importBook(from: fixture.files) }
        #expect(fixture.mediaFiles.isEmpty)
        #expect(try await fixture.store.audiobooks().isEmpty)
        let rerun = try await fixture.importer(limit: Self.smallLimit).importBook(from: fixture.files)
        #expect(rerun.alreadyImported == false)
        #expect(rerun.itemIDs.count == 3)
        #expect(try await fixture.store.audiobooks().count == 3)
        #expect(fixture.mediaFiles.count == 3)
    }

    @Test func aChangedLayoutKeyMakesNewVolumesAndLeavesOldListeningStateAlone() async throws {
        let fixture = try await fixture([5, 5, 5, 5, 5, 5])
        defer { cleanup(fixture) }
        let old = try await fixture.importer(limit: Self.smallLimit).importBook(from: fixture.files)
        let listening = PodcastListeningState(
            episodeID: old.itemIDs[0], completedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)),
            lastRevisionID: nil, updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)))
        try await fixture.store.saveListening(listening)

        let new = try await fixture.importer(limit: 120_000).importBook(from: fixture.files)
        #expect(new.alreadyImported == false)
        #expect(Set(new.itemIDs).isDisjoint(with: old.itemIDs))
        #expect(try await fixture.store.listeningState(for: old.itemIDs[0]) == listening)
        for id in old.itemIDs { #expect(try await fixture.store.audiobook(id) != nil) }
        #expect(try await fixture.store.audiobooks().count == old.itemIDs.count + new.itemIDs.count)
    }

    @Test func protectedContentRejectsTheWholeImportBeforeAnyOutput() async throws {
        let fixture = try await fixture([2, 2, 2])
        defer { cleanup(fixture) }
        let blocked = fixture.files[1].lastPathComponent
        let importer = fixture.importer(protected: { $0.lastPathComponent == blocked })
        await #expect(throws: AudiobookImportError.protectedContent(file: blocked)) {
            try await importer.importBook(from: fixture.files)
        }
        #expect(fixture.mediaFiles.isEmpty)
        #expect(try await fixture.store.audiobooks().isEmpty)
        #expect(AudiobookImportError.protectedContent(file: blocked).errorDescription?.contains(blocked) == true)
    }

    @Test func anUnreadableFileRejectsTheWholeImport() async throws {
        let fixture = try await fixture([2, 2])
        defer { cleanup(fixture) }
        let broken = fixture.root.appendingPathComponent("inputs/Part 3.m4a")
        try Data("not audio".utf8).write(to: broken)
        await #expect(throws: AudiobookImportError.self) { try await fixture.importer().importBook(from: fixture.files + [broken]) }
        #expect(fixture.mediaFiles.isEmpty)
        #expect(try await fixture.store.audiobooks().isEmpty)
    }

    @Test func aFolderImportsAudioOnlyInNaturalOrderAndTheFolderNamesTheBook() async throws {
        let fixture = try await fixture([2, 2])
        defer { cleanup(fixture) }
        let folder = fixture.root.appendingPathComponent("inputs")
        try AudiobookTestAudio.writeTone(to: folder.appendingPathComponent("Part 10.m4a"), seconds: 2)
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let result = try await fixture.importer().importBook(from: [folder])
        let book = try #require(try await fixture.store.audiobook(result.itemIDs[0]))
        #expect(book.chapters.map(\.title) == ["Part 1", "Part 2", "Part 10"])
        #expect(book.title == "inputs")
    }

    @Test func aSingleFileWithChapterMetadataKeepsItsChapters() async throws {
        let first = try await fixture([3, 4, 5])
        defer { cleanup(first) }
        let joined = try await first.importer().importBook(from: first.files)
        let stored = try #require(try await first.store.readyRevision(for: joined.itemIDs[0]))
        let second = try await fixture([1])
        defer { cleanup(second) }
        let result = try await second.importer().importBook(from: [stored.mediaURL])
        let book = try #require(try await second.store.audiobook(result.itemIDs[0]))
        #expect(book.chapters.map(\.title) == ["Part 1", "Part 2", "Part 3"])
        for (chapter, expected) in zip(book.chapters, [0.0, 3, 7]) { #expect(abs(chapter.startSeconds - expected) < 0.1) }
    }
}

/// Lets a test hook cancel the task that is running the import it belongs to.
final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<AudiobookImportResult, Error>?
    private var cancelRequested = false

    func set(_ value: Task<AudiobookImportResult, Error>) {
        lock.withLock { task = value; if cancelRequested { value.cancel() } }
    }

    func cancel() { lock.withLock { cancelRequested = true; task?.cancel() } }
}
