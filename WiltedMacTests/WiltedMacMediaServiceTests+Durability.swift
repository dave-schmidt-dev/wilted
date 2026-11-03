import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac
@testable import WiltedProducer

/// Collects the destinations `DurableFile` reports while a test's observer is installed.
///
/// Paths are kept as given: `standardizedFileURL` drops a `/private` prefix only once the file
/// exists, and the event fires before the rename creates it.
private final class DurableWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []

    var paths: [String] { lock.withLock { written } }

    func append(_ event: DurableFile.DurableFileEvent) {
        guard case .write(let url) = event else { return }
        lock.withLock { written.append(url.path) }
    }
}

extension WiltedMacMediaServiceTests {
    func testAnUnreadableAccountingFileIsSetAsideNotOverwritten() async throws {
        let rig = rig("media-corrupt-accounting")
        let accounting = rig.directory.appendingPathComponent("media-accounting.json")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: accounting)
        let entry = try id("episode-corrupt")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        let runtime = runtime(rig)

        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "c-1"))

        XCTAssertEqual(try Data(contentsOf: accounting.appendingPathExtension("corrupt")), garbage)
        let live = try Data(contentsOf: accounting)
        XCTAssertNotEqual(live, garbage)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: live))
        let holding = await runtime.service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holding)
    }

    func testAReadableAccountingFileIsNotSetAside() async throws {
        let rig = rig("media-readable-accounting")
        let accounting = rig.directory.appendingPathComponent("media-accounting.json")
        let entry = try id("episode-readable")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        await runtime(rig).consume(try request(rig, entry, from: phoneID, intentID: "k-1"))

        let restarted = runtime(rig)

        XCTAssertTrue(FileManager.default.fileExists(atPath: accounting.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: accounting.appendingPathExtension("corrupt").path))
        let holding = await restarted.service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holding)
    }

    func testLedgerAccountingAndOutcomeBookWritesAreDurable() async throws {
        let rig = rig("media-durable-writes")
        let ledgerURL = rig.directory.appendingPathComponent("standalone-ledger.json")
        let bookURL = rig.directory.appendingPathComponent("outcome-book.json")
        let entry = try id("episode-durable-writes")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let outcome = try IntentOutcome(intentID: "o-1", deviceID: phoneID, disposition: .applied, decidedAt: Date())
        let recorder = DurableWriteRecorder()

        try await DurableFile.$observer.withValue({ recorder.append($0) }) {
            _ = try await WiltedMacIntentLedger(fileURL: ledgerURL).recordIfNew("x")
            try await WiltedMacIntentOutcomeBook(fileURL: bookURL).save(outcome, published: false)
            await runtime(rig).consume(try request(rig, entry, from: phoneID, intentID: "w-1"))
        }

        let written = recorder.paths
        let expected = [
            ledgerURL, bookURL,
            rig.directory.appendingPathComponent("intent-ledger.json"),
            rig.directory.appendingPathComponent("media-accounting.json"),
            rig.directory.appendingPathComponent("media-upload-queue.json"),
        ]
        for url in expected {
            XCTAssertTrue(written.contains(url.path), "no durable write for \(url.lastPathComponent)")
        }
        let queueFirst = written.firstIndex(of: rig.directory.appendingPathComponent("media-upload-queue.json").path)
        let ledgerFirst = written.firstIndex(of: rig.directory.appendingPathComponent("intent-ledger.json").path)
        XCTAssertLessThan(try XCTUnwrap(queueFirst), try XCTUnwrap(ledgerFirst), "the request is queued before the ledger records it")
    }

    func testAnUnreadableUploadQueueFileIsSetAsideNotOverwritten() async throws {
        let rig = rig("media-corrupt-upload-queue")
        let queueURL = rig.directory.appendingPathComponent("media-upload-queue.json")
        let garbage = Data("{not json at all".utf8)
        try garbage.write(to: queueURL)
        let entry = try id("episode-corrupt-queue")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        let runtime = runtime(rig)

        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "cq-1"))

        XCTAssertEqual(try Data(contentsOf: queueURL.appendingPathExtension("corrupt")), garbage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))
        let holding = await runtime.service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holding)
    }

    func testAReadableUploadQueueFileIsNotSetAside() async throws {
        let rig = rig("media-readable-upload-queue")
        let queueURL = rig.directory.appendingPathComponent("media-upload-queue.json")
        let entry = try id("episode-readable-queue")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        await runtime(rig).consume(try request(rig, entry, from: phoneID, intentID: "rq-1"))

        let restarted = runtime(rig)

        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.appendingPathExtension("corrupt").path))
        let holding = await restarted.service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holding)
    }

    func testNoOpCleanupAndReconcilePerformZeroRepeatedAccountingReplacements() async throws {
        let rig = rig("media-noop-durability")
        let accountingURL = rig.directory.appendingPathComponent("media-accounting.json")
        let entry = try id("episode-noop")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        rig.source.setQueued(entry, true)

        let writeCounter = AccountingWriteCounter()
        let service = WiltedMacMediaService(
            source: rig.source, transport: rig.mac, accountingURL: accountingURL,
            accountingWrite: { data, url in
                writeCounter.increment()
                return try DurableFile.replace(data, to: url)
            }
        )

        // Baseline: reconcileAvailable publishes the available offer and writes durable accounting.
        let initialSuccess = await service.reconcileAvailable()
        XCTAssertTrue(initialSuccess)
        let baselineWrites = writeCounter.value
        XCTAssertEqual(baselineWrites, 1, "the initial reconcile creates the baseline accounting file")

        // Repeated no-op reconciles on unchanged state perform 0 repeated writes.
        for _ in 0..<5 {
            let ok = await service.reconcileAvailable()
            XCTAssertTrue(ok)
        }
        XCTAssertEqual(writeCounter.value, baselineWrites, "no repeated writes on no-op reconcileAvailable")

        // Repeated sweeps on unchanged state perform 0 repeated writes.
        for _ in 0..<5 {
            await service.sweepExpired()
        }
        XCTAssertEqual(writeCounter.value, baselineWrites, "no repeated writes on no-op sweepExpired")
    }

    func testAccountingPersistenceRetriesAfterUncertainDirectorySync() async throws {
        let rig = rig("media-uncertain-sync")
        let accountingURL = rig.directory.appendingPathComponent("media-accounting.json")
        let entry = try id("episode-uncertain")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        rig.source.setQueued(entry, true)

        let attemptCounter = AccountingWriteCounter()
        let service = WiltedMacMediaService(
            source: rig.source, transport: rig.mac, accountingURL: accountingURL,
            accountingWrite: { data, url in
                let attempt = attemptCounter.increment()
                if attempt == 1 {
                    // Land the file but report directory sync uncertain
                    _ = try DurableFile.replace(data, to: url)
                    return .replacedDirectorySyncUncertain(DurableFile.ReplacementFailure(code: EIO))
                }
                return try DurableFile.replace(data, to: url)
            }
        )

        // First reconcile lands the file, but directory sync is uncertain.
        _ = await service.reconcileAvailable()
        XCTAssertEqual(attemptCounter.value, 1)

        // Next reconcile has identical state, but uncertain durability MUST retry!
        _ = await service.reconcileAvailable()
        XCTAssertEqual(attemptCounter.value, 2, "uncertain directory sync must retry even if state is byte-identical")

        // Now that attempt 2 was durable, subsequent no-op reconciles must skip.
        _ = await service.reconcileAvailable()
        XCTAssertEqual(attemptCounter.value, 2, "subsequent call skips once durable success is confirmed")
    }

    func testAccountingPersistenceRetriesAfterFailedWrite() async throws {
        let rig = rig("media-failed-write-retry")
        let accountingURL = rig.directory.appendingPathComponent("media-accounting.json")
        let entry = try id("episode-failed-retry")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        rig.source.setQueued(entry, true)

        let attemptCounter = AccountingWriteCounter()
        let failFirst = LockedFlag(true)
        let service = WiltedMacMediaService(
            source: rig.source, transport: rig.mac, accountingURL: accountingURL,
            accountingWrite: { data, url in
                _ = attemptCounter.increment()
                if failFirst.take() {
                    throw POSIXError(.EIO)
                }
                return try DurableFile.replace(data, to: url)
            }
        )

        // First reconcile attempt fails during accounting write.
        _ = await service.reconcileAvailable()
        XCTAssertEqual(attemptCounter.value, 1)

        // Second reconcile attempt retries the write.
        _ = await service.reconcileAvailable()
        XCTAssertEqual(attemptCounter.value, 2, "failed write is retried on subsequent call")

        // Once durable, subsequent calls skip.
        _ = await service.reconcileAvailable()
        XCTAssertEqual(attemptCounter.value, 2, "skips after successful durable write")
    }

    func testAccountingPersistenceWritesWhenAccountingDataChanges() async throws {
        let rig = rig("media-state-change-persists")
        let accountingURL = rig.directory.appendingPathComponent("media-accounting.json")
        let entry1 = try id("episode-change-1")
        let audio1 = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry1, audio1)
        rig.source.setQueued(entry1, true)

        let writeCounter = AccountingWriteCounter()
        let service = WiltedMacMediaService(
            source: rig.source, transport: rig.mac, accountingURL: accountingURL,
            accountingWrite: { data, url in
                writeCounter.increment()
                return try DurableFile.replace(data, to: url)
            }
        )

        // Baseline: 1 write
        _ = await service.reconcileAvailable()
        XCTAssertEqual(writeCounter.value, 1)
        let baselineWrites = writeCounter.value

        // Available offers are transport state, not part of the accounting file. A real media
        // request creates a durable asset record; a second requester changes that stored record.
        await service.handle(try request(rig, entry1, from: phoneID, intentID: "accounting-first-request"))
        let uploadedWrites = writeCounter.value
        XCTAssertGreaterThan(uploadedWrites, baselineWrites, "a served request writes its asset accounting")

        await service.handle(try request(rig, entry1, from: tabletID, intentID: "accounting-second-request"))
        XCTAssertEqual(writeCounter.value, uploadedWrites + 1, "a new requester changes durable accounting")

        // No-op reconcile after the change does not write
        _ = await service.reconcileAvailable()
        XCTAssertEqual(writeCounter.value, uploadedWrites + 1, "subsequent no-op does not rewrite")
    }
}

private final class AccountingWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int { lock.withLock { count } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    init(_ flag: Bool = false) { self.flag = flag }

    func set() { lock.withLock { flag = true } }

    func take() -> Bool {
        lock.withLock {
            defer { flag = false }
            return flag
        }
    }
}
