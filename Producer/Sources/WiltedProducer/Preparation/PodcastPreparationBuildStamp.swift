import Darwin
import Foundation
import WiltedDomain

/// Identifies the host application build and preparation engine version that
/// processed an episode.
public struct PodcastPreparationBuildStamp: Equatable, Sendable {
    public let appVersion: String?
    public let engineVersion: String
    public let codeRevision: String?

    public init(appVersion: String?, engineVersion: String, codeRevision: String? = nil) {
        self.appVersion = appVersion
        self.engineVersion = engineVersion
        self.codeRevision = codeRevision
    }

    /// Derives the host application version string from an info dictionary.
    ///
    /// Returns `nil` unless `WiltedSourceCommit` is present as a `String` (which
    /// distinguishes the host application from test runners and other hosts).
    /// Missing version keys fall back to `"?"`, and an empty commit produces
    /// `"<short> (<build>)"`. The result is bounded to 256 characters so it fits
    /// inside a `PreparationEvidence` field.
    public static func hostAppVersion(info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let info, let commit = info["WiltedSourceCommit"] as? String else {
            return nil
        }
        let shortVersion = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        let buildVersion = (info["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        let raw: String
        if commit.isEmpty {
            raw = "\(shortVersion) (\(buildVersion))"
        } else {
            raw = "\(shortVersion) (\(buildVersion), \(commit))"
        }
        return String(raw.prefix(256))
    }

    /// Returns the 10-hex short HEAD of the git checkout containing
    /// `directories[0]`, suffixed `-dirty` when a tracked file under any of
    /// `directories` differs from HEAD (untracked files never count). Nil when
    /// the directory is not in a checkout, or git is missing, fails or hangs.
    public static func checkoutRevision(of directories: [URL]) async -> String? {
        guard let target = directories.first else { return nil }
        return await Task.detached {
            let checkout = ["-C", target.path]
            guard let head = runGit(checkout + ["rev-parse", "--short=10", "HEAD"]), head.status == 0 else {
                return nil
            }
            let short = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !short.isEmpty, short.allSatisfy(\.isHexDigit) else { return nil }
            // `diff --quiet` prints nothing and exits 1 when a tracked file differs.
            guard let diff = runGit(checkout + ["diff", "--quiet", "HEAD", "--"] + directories.map(\.path)),
                  diff.status <= 1 else {
                return nil
            }
            return String((diff.status == 1 ? "\(short)-dirty" : short).prefix(64))
        }.value
    }

    /// Runs `/usr/bin/git` without optional locks, so it never takes the
    /// owner's index lock, and stops it after `timeout` seconds.
    private static func runGit(_ arguments: [String], timeout: TimeInterval = 5) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                let killAt = Date().addingTimeInterval(1)
                while process.isRunning, Date() < killAt { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Reading after exit is safe: rev-parse prints one short line and
        // diff --quiet prints nothing, so neither can fill the pipe.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }
}

extension PreparationRunSummary {
    /// The build and engine version stamp recorded for this run.
    ///
    /// The start row is read first because it exists for every run that reached
    /// the source, success or failure.
    public var buildStamp: PodcastPreparationBuildStamp? {
        for entry in entries {
            guard let evidence = entry.status.evidence,
                  evidence.kind == LocalLibraryStore.pipelineProvenanceEvidenceKind,
                  let engineVersion = evidence.fields["engineVersion"] else {
                continue
            }
            return PodcastPreparationBuildStamp(
                appVersion: evidence.fields["appVersion"],
                engineVersion: engineVersion,
                codeRevision: evidence.fields["codeRevision"]
            )
        }
        return nil
    }
}
