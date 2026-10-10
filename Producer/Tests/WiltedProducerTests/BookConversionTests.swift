import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// A synthesizer that never reaches the speech daemon: every call returns a short tone and is recorded.
private final class StubSynthesizer: @unchecked Sendable {
    struct Stopped: Error {}

    private let lock = NSLock()
    private var texts: [String] = []
    /// The 1-based call number that throws instead of returning audio.
    private let stopAtCall: Int?

    init(stopAtCall: Int? = nil) { self.stopAtCall = stopAtCall }

    var calls: [String] { lock.withLock { texts } }

    var synthesizer: BookConversion.Synthesizer {
        { [self] text, _ in
            let call = lock.withLock { () -> Int in
                texts.append(text)
                return texts.count
            }
            if call == stopAtCall { throw Stopped() }
            let rate = 24_000
            return SpeechSynthesisResult(
                requestID: "stub", samples: (0..<rate / 2).map { Float(0.3 * sin(2 * .pi * 300 * Double($0) / Double(rate))) },
                sampleRate: rate)
        }
    }
}

private final class BookProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BookConversionProgress] = []
    func add(_ item: BookConversionProgress) { lock.withLock { items.append(item) } }
    var all: [BookConversionProgress] { lock.withLock { items } }
}

@Suite("Book conversion")
struct BookConversionTests {
    struct Fixture {
        let root: URL
        let store: LocalLibraryStore
        let book: URL
        let workRoot: URL

        func conversion(
            _ synthesizer: @escaping BookConversion.Synthesizer, voice: String = BookConversion.daemonDefaultVoice
        ) -> BookConversion {
            BookConversion(store: store, voice: voice, workRoot: workRoot, synthesize: synthesizer)
        }

        /// The one per-book work folder a stopped conversion leaves behind.
        var workFolder: URL? {
            ((try? FileManager.default.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil)) ?? []).first
        }
    }

    private func fixture() async throws -> Fixture {
        let root = try AudiobookTestAudio.ownedDirectory("book-convert")
        let chapters = (1...4).map { (title: "Title \($0)", body: "<h1>Title \($0)</h1><p>Body of chapter \($0).</p>") }
        let book = root.appendingPathComponent("book.epub")
        try BookTestArchive.zip(BookTestArchive.epubEntries(chapters: chapters), to: book)
        return Fixture(
            root: root, store: try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite")), book: book,
            workRoot: root.appendingPathComponent("work", isDirectory: true))
    }

    private func cleanup(_ fixture: Fixture) { try? FileManager.default.removeItem(at: fixture.root) }

    @Test func aBookIsConvertedJoinedAndSavedWithItsChapters() async throws {
        let fixture = try await fixture()
        defer { cleanup(fixture) }
        let stub = StubSynthesizer()
        let log = BookProgressLog()
        let result = try await fixture.conversion(stub.synthesizer).convert(from: fixture.book) { log.add($0) }
        #expect(result.alreadyImported == false)
        #expect(stub.calls.count == 4)
        let saved = try #require(try await fixture.store.audiobook(result.itemIDs[0]))
        #expect(saved.sourceFormat == "epub")
        #expect(saved.title == "The Test Book")
        #expect(saved.author == "Ada Author")
        #expect(saved.chapters.map(\.title) == ["Title 1", "Title 2", "Title 3", "Title 4"])
        #expect(abs(saved.durationSeconds - 2) < 0.2)
        #expect(zip(saved.chapters, saved.chapters.dropFirst()).allSatisfy { $0.startSeconds < $1.startSeconds })
        #expect(fixture.workFolder == nil)
        // Progress names every chapter (INV-1).
        let synthesizing = log.all.filter { $0.stage == .synthesizing }
        #expect(Set(synthesizing.map(\.chapter)) == [1, 2, 3, 4])
        #expect(synthesizing.allSatisfy { $0.chapterCount == 4 })
        #expect(log.all.map(\.fraction) == log.all.map(\.fraction).sorted())

        let again = try await fixture.conversion(stub.synthesizer).convert(from: fixture.book)
        #expect(again.alreadyImported)
        #expect(stub.calls.count == 4)
    }

    @Test func aConversionStoppedAfterChapterTwoSynthesizesOnlyChaptersThreeAndFourOnRerun() async throws {
        let fixture = try await fixture()
        defer { cleanup(fixture) }
        let first = StubSynthesizer(stopAtCall: 3)
        await #expect(throws: StubSynthesizer.Stopped.self) {
            try await fixture.conversion(first.synthesizer).convert(from: fixture.book)
        }
        #expect(first.calls.count == 3)
        #expect(try await fixture.store.audiobooks().isEmpty)

        let second = StubSynthesizer()
        let result = try await fixture.conversion(second.synthesizer).convert(from: fixture.book)
        #expect(second.calls.count == 2)
        #expect(second.calls[0].contains("chapter 3"))
        #expect(second.calls[1].contains("chapter 4"))
        let saved = try #require(try await fixture.store.audiobook(result.itemIDs[0]))
        #expect(saved.chapters.count == 4)
    }

    @Test func aChangedVoiceReconvertsEveryChapter() async throws {
        let fixture = try await fixture()
        defer { cleanup(fixture) }
        let first = StubSynthesizer(stopAtCall: 3)
        await #expect(throws: StubSynthesizer.Stopped.self) {
            try await fixture.conversion(first.synthesizer, voice: "voice-a").convert(from: fixture.book)
        }
        let second = StubSynthesizer()
        _ = try await fixture.conversion(second.synthesizer, voice: "voice-b").convert(from: fixture.book)
        #expect(second.calls.count == 4)
        #expect(second.calls[0].contains("chapter 1"))
    }

    @Test func aCorruptedChapterFileIsReconvertedAndTheRestAreKept() async throws {
        let fixture = try await fixture()
        defer { cleanup(fixture) }
        let first = StubSynthesizer(stopAtCall: 3)
        await #expect(throws: StubSynthesizer.Stopped.self) {
            try await fixture.conversion(first.synthesizer).convert(from: fixture.book)
        }
        let folder = try #require(fixture.workFolder)
        let chapterTwo = folder.appendingPathComponent("chapter-0002.m4a")
        let handle = try FileHandle(forWritingTo: chapterTwo)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("corruption".utf8))
        try handle.close()

        let second = StubSynthesizer()
        let result = try await fixture.conversion(second.synthesizer).convert(from: fixture.book)
        #expect(second.calls.count == 3)
        #expect(second.calls.map { $0.contains("chapter 2") } == [true, false, false])
        #expect(try await fixture.store.audiobook(result.itemIDs[0])?.chapters.count == 4)
    }

    @Test func aBookLargerThanTheSplitSizeBecomesMoreChapters() async throws {
        let fixture = try await fixture()
        defer { cleanup(fixture) }
        let stub = StubSynthesizer()
        let conversion = BookConversion(
            store: fixture.store, extractor: BookTextExtractor(splitWords: 4), workRoot: fixture.workRoot,
            synthesize: stub.synthesizer)
        let result = try await conversion.convert(from: fixture.book)
        // "Title N" plus "Body of chapter N." is six words, so each chapter is cut at its paragraph end.
        #expect(stub.calls.count == 8)
        #expect(try await fixture.store.audiobook(result.itemIDs[0])?.chapters.count == 8)
    }
}
