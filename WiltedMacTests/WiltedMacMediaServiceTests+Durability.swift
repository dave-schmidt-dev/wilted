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
        ]
        for url in expected {
            XCTAssertTrue(written.contains(url.path), "no durable write for \(url.lastPathComponent)")
        }
    }
}
