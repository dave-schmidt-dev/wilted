import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac
@testable import WiltedProducer

/// A ledger writer that reports its first `failing` saves as a failed folder sync. By default it
/// writes through the central replacement primitive with a real failed directory sync, so the
/// bytes land and the result is uncertain; with `beforeRename` it throws before anything reaches
/// the file.
private final class FlakyLedgerWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    private var saves = 0
    private let beforeRename: Bool

    init(failing count: Int, beforeRename: Bool = false) {
        failuresLeft = count
        self.beforeRename = beforeRename
    }

    var calls: Int { lock.withLock { saves } }

    var write: WiltedMacIntentLedger.Writer {
        { [self] data, url in
            let fails = lock.withLock { () -> Bool in
                saves += 1
                guard failuresLeft > 0 else { return false }
                failuresLeft -= 1
                return true
            }
            if fails && beforeRename { throw POSIXError(.ENOSPC) }
            guard fails else { return try DurableFile.replace(data, to: url) }
            return try DurableFile.$directorySyncInterceptor.withValue({ _ in throw POSIXError(.EIO) }) {
                try DurableFile.replace(data, to: url)
            }
        }
    }
}

@MainActor
final class WiltedMacIntentLedgerTests: XCTestCase {
    private let phone = "iphone"
    private let mac = "mac-test"
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Process {
        var host: FakeDecisionHost
        var ledger: WiltedMacIntentLedger
        var applier: WiltedMacIntentApplier
    }

    /// One Mac process over `directory`: its own ledger, outcome book and applier.
    private func process(
        _ directory: URL, server: InMemoryLibraryServer, entry: ItemID, write: WiltedMacIntentLedger.Writer? = nil
    ) -> Process {
        let at = clock
        let ledgerURL = directory.appendingPathComponent("ledger.json")
        let ledger = write.map { WiltedMacIntentLedger(fileURL: ledgerURL, now: { at }, write: $0) }
            ?? WiltedMacIntentLedger(fileURL: ledgerURL, now: { at })
        let host = FakeDecisionHost()
        host.states[entry] = .live(queued: false, started: false)
        let applier = WiltedMacIntentApplier(
            host: host, ledger: ledger,
            book: WiltedMacIntentOutcomeBook(fileURL: directory.appendingPathComponent("book.json"), now: { at }),
            transport: InMemoryLibraryTransport(deviceID: mac, server: server), now: { at }
        )
        return Process(host: host, ledger: ledger, applier: applier)
    }

    private func outcomes(_ server: InMemoryLibraryServer) async throws -> [IntentOutcome] {
        try await InMemoryLibraryTransport(deviceID: phone, server: server).intentOutcomes()
    }

    func testAFailedFolderSyncAfterTheRenameStillAppliesTheIntentOnceAcrossARestart() async throws {
        let directory = wiltedTemporaryDirectory("intent-ledger-folder-sync")
        let server = InMemoryLibraryServer(writerDeviceID: mac)
        let entry = try ItemID(rawValue: "item-a")
        let keep = try LibraryIntent(id: "k-sync", deviceID: phone, createdAt: clock, action: .keep(entryID: entry))
        // Every folder sync fails in the first process, including the primitive's single retry.
        let flaky = FlakyLedgerWriter(failing: .max)
        let first = process(directory, server: server, entry: entry, write: flaky.write)

        do {
            try await first.applier.apply(keep)
        } catch {
            return XCTFail("an id the save left on disk must count as recorded and be applied: \(error)")
        }
        // The phone's intent is read again in a later round; it must not be applied twice.
        try await first.applier.apply(keep)

        XCTAssertEqual(first.host.calls, ["keep item-a"], "the saved id is applied, once")
        XCTAssertEqual(flaky.calls, 1, "the replacement primitive retries the folder sync without rewriting the ledger")
        let answered = try await outcomes(server)
        XCTAssertEqual(answered.map(\.intentID), ["k-sync"])
        XCTAssertEqual(answered.first?.disposition, .applied)

        // A new process over the same folder: the id is still recorded and is not applied again.
        let restarted = process(directory, server: server, entry: entry)
        let known = await restarted.ledger.contains("k-sync")
        XCTAssertTrue(known, "the id survives the restart")
        try await restarted.applier.apply(keep)

        XCTAssertEqual(restarted.host.calls, [], "a restart does not apply the intent again")
        let after = try await outcomes(server)
        XCTAssertEqual(after.map(\.intentID), ["k-sync"])
        XCTAssertEqual(after.first?.disposition, .applied)
    }

    func testASaveThatFailsBeforeTheRenameLeavesTheIdUnrecordedSoARetryApplies() async throws {
        let url = wiltedTemporaryDirectory("intent-ledger-failed-save").appendingPathComponent("ledger.json")
        let at = clock
        let ledger = WiltedMacIntentLedger(fileURL: url, now: { at }, write: FlakyLedgerWriter(failing: 1, beforeRename: true).write)

        do {
            _ = try await ledger.recordIfNew("x")
            XCTFail("a save that never reached the file must throw so the caller does not apply")
        } catch {}

        let held = await ledger.contains("x")
        XCTAssertFalse(held)
        let reloaded = await WiltedMacIntentLedger(fileURL: url, now: { at }).contains("x")
        XCTAssertFalse(reloaded, "nothing reached the file")
        let retried = try await ledger.recordIfNew("x")
        XCTAssertTrue(retried, "the caller's retry records the id and applies it")
    }
}
