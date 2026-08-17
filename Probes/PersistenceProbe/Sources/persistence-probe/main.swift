import Foundation
import PersistenceProbeCore
import Darwin

func status(_ value: String) { FileHandle.standardError.write(Data("stage=\(value)\n".utf8)) }

struct Result: Codable {
    let passed: Bool
    let schemaVersion: Int
    let inspection: PersistenceInspection?
    let error: String?
}

func emit(_ result: Result, exitCode: Int32 = 0) -> Never {
    let data = try! JSONEncoder().encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(exitCode)
}

@main struct Main {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--durable-child" {
                guard arguments.count == 2 else { throw PersistenceProbeError.unsupported("--durable-child requires a store URL") }
                let url = URL(fileURLWithPath: arguments[1])
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let store = try PersistenceStore(url: url)
                status("durable-write.start")
                try await PersistenceProbeScenarios.populateAll(store, prefix: "durable")
                status("durable-write.saved")
                _ = try await store.inspect()
                // Deliberately bypass normal process teardown: the following
                // invocation must prove that SwiftData saved before exit.
                Darwin._exit(0)
            }
            if arguments.first == "--inspect" {
                guard arguments.count == 2 else { throw PersistenceProbeError.unsupported("--inspect requires a store URL") }
                let store = try PersistenceStore(url: URL(fileURLWithPath: arguments[1]))
                emit(Result(passed: true, schemaVersion: 2, inspection: try await store.inspect(), error: nil))
            }
            let url = PersistenceStoreURL.deterministic(named: "run")
            try PersistenceStoreURL.reset(url)
            status("store.open.start")
            let store = try PersistenceStore(url: url)
            status("store.open.ready")
            try await PersistenceProbeScenarios.populateAll(store)
            status("concurrent-callbacks.start")
            try await PersistenceProbeScenarios.concurrentJournalWrites(store)
            status("concurrent-callbacks.complete")
            let inspection = try await store.inspect()
            guard inspection.articles == 1, inspection.revisions == 1, inspection.playback == 1,
                  inspection.journal == 25, inspection.syncState == 1, inspection.tombstones == 1 else {
                throw PersistenceProbeError.invariant("unexpected inspection \(inspection)")
            }
            status("probe.complete")
            emit(Result(passed: true, schemaVersion: inspection.schemaVersion, inspection: inspection, error: nil))
        } catch {
            status("probe.failed")
            emit(Result(passed: false, schemaVersion: 0, inspection: nil, error: String(describing: error)), exitCode: 1)
        }
    }
}
