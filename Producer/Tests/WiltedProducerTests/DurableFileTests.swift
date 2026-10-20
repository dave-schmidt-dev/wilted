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

        XCTAssertEqual(recorder.events, [.write(destination)])
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }
}

/// A locked event log shared by the durable-write tests.
final class DurableFileEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DurableFileEvent] = []
    private var snapshots: [(url: URL, exists: Bool)] = []

    var events: [DurableFileEvent] { lock.withLock { storage } }
    var fullSyncSnapshots: [(url: URL, exists: Bool)] { lock.withLock { snapshots } }
    var writtenURLs: [URL] { lock.withLock { storage.compactMap { if case .write(let url) = $0 { return url }; return nil } } }

    func append(_ event: DurableFileEvent) {
        lock.withLock {
            storage.append(event)
            if case .fullSync(let url) = event {
                snapshots.append((url, FileManager.default.fileExists(atPath: url.path)))
            }
        }
    }
}
