import Darwin
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
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            fatalError("cannot read process start time")
        }
        var started = time_t(info.pbi_start_tvsec)
        var local = tm()
        localtime_r(&started, &local)
        var buffer = [CChar](repeating: 0, count: 64)
        strftime(&buffer, buffer.count, "%a %b %e %T %Y", &local)
        return String(cString: buffer)
    }
}
