import Foundation
import XCTest
@testable import WiltedProducer

final class DurableFileTests: XCTestCase {
    private lazy var directory = OwnedTestTemp.root
        .appendingPathComponent("wilted-durable-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWriteCreatesTheFileWithExactContentsAndLeavesNoTemporary() throws {
        let destination = directory.appendingPathComponent("library.sqlite")
        let expected = Data("durable bytes".utf8)

        try DurableFile.write(expected, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), expected)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       [destination.lastPathComponent])
    }

    func testWriteReplacesAnExistingFileByRename() throws {
        let destination = directory.appendingPathComponent("library.sqlite")
        try Data("old bytes".utf8).write(to: destination)
        let oldInode = try inode(of: destination)

        try DurableFile.write(Data("new bytes".utf8), to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new bytes".utf8))
        XCTAssertNotEqual(try inode(of: destination), oldInode)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       [destination.lastPathComponent])
    }

    func testWriteIntoAMissingDirectoryThrowsAndCreatesNothing() {
        let missingDirectory = directory.appendingPathComponent("missing", isDirectory: true)
        let destination = missingDirectory.appendingPathComponent("library.sqlite")

        XCTAssertThrowsError(try DurableFile.write(Data("bytes".utf8), to: destination))

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFailedRenameKeepsTheOriginalAndRemovesTheTemporary() throws {
        let destination = directory.appendingPathComponent("library.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let child = destination.appendingPathComponent("child")
        try Data("child bytes".utf8).write(to: child)

        XCTAssertThrowsError(try DurableFile.write(Data("new bytes".utf8), to: destination))

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: child), Data("child bytes".utf8))
        let temporaries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(temporaries.isEmpty, "left temporary files: \(temporaries)")
    }

    func testFullSyncFlushesAnOpenFile() throws {
        let url = directory.appendingPathComponent("open-file")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("bytes".utf8))
        let recorder = DurableFileEventRecorder()

        try DurableFile.$observer.withValue({ recorder.append($0) }) {
            try DurableFile.fullSync(handle, at: url)
        }

        XCTAssertEqual(recorder.events, [.fullSync(url)])
    }

    func testObserverSeesTheDestinationOfEachWrite() throws {
        let destination = directory.appendingPathComponent("library.sqlite")
        let recorder = DurableFileEventRecorder()

        try DurableFile.$observer.withValue({ recorder.append($0) }) {
            try DurableFile.write(Data("bytes".utf8), to: destination)
        }

        XCTAssertEqual(recorder.events, [.write(destination), .rename(destination)])
    }

    // MARK: Replacement uncertainty

    func testReplaceReportsUncertainDirectoryDurabilityAfterOneRenameAndTwoSyncAttempts() throws {
        let destination = directory.appendingPathComponent("library.sqlite")
        try Data("old bytes".utf8).write(to: destination)
        let oldInode = try inode(of: destination)
        let recorder = DurableFileEventRecorder()
        let sync = DirectorySyncScript(failing: 2)

        let result = try DurableFile.$observer.withValue({ recorder.append($0) }) {
            try DurableFile.$directorySyncInterceptor.withValue({ try sync.sync($0) }) {
                try DurableFile.replace(Data("new bytes".utf8), to: destination)
            }
        }

        guard case let .replacedDirectorySyncUncertain(failure) = result else {
            return XCTFail("expected uncertain directory durability, got \(result)")
        }
        XCTAssertEqual(failure.code, POSIXErrorCode.EIO.rawValue)
        XCTAssertEqual(sync.attemptCount, 2, "one directory sync, then exactly one retry")
        XCTAssertEqual(recorder.renamedURLs, [destination], "the bytes are renamed into place exactly once")
        XCTAssertEqual(try Data(contentsOf: destination), Data("new bytes".utf8))
        XCTAssertNotEqual(try inode(of: destination), oldInode)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       [destination.lastPathComponent], "an uncertain landed replace leaves no temporary")
    }

    func testReplaceSucceedsWhenTheRetriedDirectorySyncRecovers() throws {
        let destination = directory.appendingPathComponent("library.sqlite")
        try Data("old bytes".utf8).write(to: destination)
        let oldInode = try inode(of: destination)
        let recorder = DurableFileEventRecorder()
        let sync = DirectorySyncScript(failing: 1)

        let result = try DurableFile.$observer.withValue({ recorder.append($0) }) {
            try DurableFile.$directorySyncInterceptor.withValue({ try sync.sync($0) }) {
                try DurableFile.replace(Data("new bytes".utf8), to: destination)
            }
        }

        XCTAssertEqual(result, .durable)
        XCTAssertEqual(sync.attemptCount, 2, "the failed first sync is retried once")
        XCTAssertEqual(recorder.renamedURLs, [destination])
        XCTAssertEqual(try Data(contentsOf: destination), Data("new bytes".utf8))
        XCTAssertNotEqual(try inode(of: destination), oldInode)
    }

    func testStrictWriteThrowsTheFinalDirectorySyncUncertaintyAfterTheRename() throws {
        let destination = directory.appendingPathComponent("library.sqlite")
        try Data("old bytes".utf8).write(to: destination)
        let oldInode = try inode(of: destination)
        let recorder = DurableFileEventRecorder()
        let sync = DirectorySyncScript(failing: 2)

        XCTAssertThrowsError(
            try DurableFile.$observer.withValue({ recorder.append($0) }) {
                try DurableFile.$directorySyncInterceptor.withValue({ try sync.sync($0) }) {
                    try DurableFile.write(Data("new bytes".utf8), to: destination)
                }
            }
        ) { error in
            guard let failure = error as? DurableFile.ReplacementFailure else {
                return XCTFail("expected the primitive's final uncertainty, got \(error)")
            }
            XCTAssertEqual(failure.code, POSIXErrorCode.EIO.rawValue)
        }

        XCTAssertEqual(sync.attemptCount, 2)
        XCTAssertEqual(recorder.renamedURLs, [destination])
        XCTAssertEqual(try Data(contentsOf: destination), Data("new bytes".utf8))
        XCTAssertNotEqual(try inode(of: destination), oldInode)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       [destination.lastPathComponent])
    }

    func testAPreRenameFlushFailureWithEqualBytesStillThrowsAndPreservesTheOriginal() throws {
        let destination = directory.appendingPathComponent("library.sqlite")
        let bytes = Data("same bytes".utf8)
        try bytes.write(to: destination)
        let oldInode = try inode(of: destination)
        let recorder = DurableFileEventRecorder()
        let flush = FileFlushScript()

        XCTAssertThrowsError(
            try DurableFile.$observer.withValue({ recorder.append($0) }) {
                try DurableFile.$fileFlushInterceptor.withValue({ try flush.flush($0) }) {
                    try DurableFile.replace(bytes, to: destination)
                }
            }
        )

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try inode(of: destination), oldInode, "equal bytes do not make a failed durability operation a success")
        XCTAssertTrue(recorder.renamedURLs.isEmpty, "the failure happened before the rename")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       [destination.lastPathComponent])
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }
}

/// Counts directory-sync attempts and fails a scripted window of them.
final class DirectorySyncScript: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var failuresLeft: Int
    private let succeedsFirst: Int

    /// Fails the first `count` attempts; use `.max` to fail every attempt.
    init(failing count: Int) {
        failuresLeft = count
        succeedsFirst = 0
    }

    /// Lets `successes` attempts through, then fails every later attempt.
    init(failingAfter successes: Int) {
        failuresLeft = Int.max
        succeedsFirst = successes
    }

    var attemptCount: Int { lock.withLock { attempts } }

    func sync(_ url: URL) throws {
        let fails = lock.withLock { () -> Bool in
            attempts += 1
            if attempts <= succeedsFirst { return false }
            guard failuresLeft > 0 else { return false }
            if failuresLeft != Int.max { failuresLeft -= 1 }
            return true
        }
        if fails { throw POSIXError(.EIO) }
    }
}

/// Fails a file-data flush before the temporary file can be renamed.
private final class FileFlushScript: @unchecked Sendable {
    func flush(_ fd: Int32) throws { throw POSIXError(.EIO) }
}

/// A locked event log shared by the durable-write tests.
final class DurableFileEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DurableFileEvent] = []
    private var snapshots: [(url: URL, exists: Bool)] = []

    var events: [DurableFileEvent] { lock.withLock { storage } }
    var fullSyncSnapshots: [(url: URL, exists: Bool)] { lock.withLock { snapshots } }
    var writtenURLs: [URL] { lock.withLock { storage.compactMap { if case .write(let url) = $0 { return url }; return nil } } }
    var renamedURLs: [URL] { lock.withLock { storage.compactMap { if case .rename(let url) = $0 { return url }; return nil } } }

    func append(_ event: DurableFileEvent) {
        lock.withLock {
            storage.append(event)
            if case .fullSync(let url) = event {
                snapshots.append((url, FileManager.default.fileExists(atPath: url.path)))
            }
        }
    }
}
