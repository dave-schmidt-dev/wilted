import Darwin
import Foundation

extension WiltedMacModel {
    /// Fixture launches share the daily driver's bundle identifier, so they
    /// get their own defaults domain, emptied on first use: a UI test must
    /// neither inherit the owner's choices nor leave its own behind. The
    /// suite is named by process and model, so Mac test hosts running in
    /// sibling worktrees at the same time cannot wipe each other's state.
    static func fixturePreferences(suiteName: String = fixturePreferencesSuiteName()) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    nonisolated static let fixturePreferencesSuitePrefix = "com.zerodelta.wilted.mac.ui-fixture"

    static func fixturePreferencesSuiteName() -> String {
        "\(fixturePreferencesSuitePrefix).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
    }

    /// Whether the process holding `pid` could have created a suite whose plist was created at `created`.
    ///
    /// PIDs get reused across reboots and long sessions, so checking only `kill(pid, 0)` allowed 786
    /// leftover preference suites to survive because unrelated processes (such as powerd or Spotlight
    /// importers) now hold those PIDs. Requiring that the live process started before the plist was
    /// created prevents a reused PID from protecting an exited process's suite.
    nonisolated static func preferenceSuiteOwnerIsLive(_ pid: pid_t, created: Date?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 && errno == ESRCH {
            return false
        }
        guard let created else { return true }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &proc, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.stride else {
            return true
        }
        let startTime = proc.kp_proc.p_un.__p_starttime
        guard startTime.tv_sec > 0 || startTime.tv_usec > 0 else {
            return true
        }
        let start = Date(timeIntervalSince1970: Double(startTime.tv_sec) + Double(startTime.tv_usec) / 1_000_000.0)
        return start <= created + 2
    }

    /// Removes the suites (and their plists) of fixture processes that are gone. A suite whose owner
    /// is live, or whose owner cannot be told, is left alone.
    nonisolated static func sweepStaleFixturePreferenceSuites(
        in directory: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences", isDirectory: true)
    ) {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let prefix = fixturePreferencesSuitePrefix + "."
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(".plist") {
            let suite = String(entry.dropLast(".plist".count))
            let fileURL = directory.appendingPathComponent(entry)
            let created = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.creationDate] as? Date
            guard let owner = suite.dropFirst(prefix.count).split(separator: ".").first.flatMap({ Int32($0) }),
                  owner > 0, !preferenceSuiteOwnerIsLive(owner, created: created) else { continue }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
