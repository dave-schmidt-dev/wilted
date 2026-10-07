import Foundation
@testable import WiltedProducer

/// One per-process scratch root for every Producer test fixture.
///
/// The root is marked `.wilted-temp-owned` (pid and start time, the format of
/// `wilted_temp_mark_owned` in `scripts/lib/test-temp-state.sh`) so a concurrent
/// gate's temp audit exempts it while this process lives. `FileManager`'s
/// temporary directory ignores `TMPDIR` on macOS, so fixtures must come through
/// here instead of `FileManager.default.temporaryDirectory`. The root is removed
/// at process exit; `scripts/lib/temp-sweep.sh` reclaims it if the process dies.
enum OwnedTestTemp {
    static let markerName = ".wilted-temp-owned"

    static let root: URL = {
        let pid = ProcessInfo.processInfo.processIdentifier
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-producer-tests-\(pid)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let canonical = directory.resolvingSymlinksInPath().path
            let marker = "pid=\(pid)\nstarted=\(processStart(pid))\npath=\(canonical)\n"
            try marker.write(to: directory.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
        } catch {
            fatalError("cannot create the owned test temp root: \(error)")
        }
        atexit { try? FileManager.default.removeItem(at: OwnedTestTemp.root) }
        // Production scratch (migration validation clones, import copies) lands here too.
        ScratchParent.overrideForTesting = directory
        return directory
    }()

    /// `ps -o lstart= -p <pid>`, the value `scripts/check-temp-leaks.py` compares.
    static func processStart(_ pid: Int32) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "lstart=", "-p", String(pid)]
        process.standardOutput = output
        do { try process.run() } catch { fatalError("cannot run ps: \(error)") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
