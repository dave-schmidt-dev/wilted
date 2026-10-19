import Darwin
import Foundation

/// What one abandoned-preparation-scratch sweep did: files removed, bytes
/// reclaimed, removals that were attempted but failed, and whether a live
/// worker's rendering file stopped preparation scratch from being removed.
public struct PreparationScratchSweep: Sendable, Equatable {
    public let removed: Int
    public let bytes: Int64
    public let failed: Int
    public let skippedLiveWorker: Bool

    public init(removed: Int, bytes: Int64, failed: Int, skippedLiveWorker: Bool) {
        self.removed = removed
        self.bytes = bytes
        self.failed = failed
        self.skippedLiveWorker = skippedLiveWorker
    }
}

extension LocalLibraryStore {
    /// Removes scratch audio left by a crash, force quit, or failed run.
    ///
    /// Only direct children of `<media>/preparation` and `<media>` are
    /// considered: prepared episode outputs and worker rendering files in the
    /// former, article-encoding and audiobook-joining temporaries in the
    /// latter. Committed `candidate-<request>.m4a` audio does not match and is
    /// never touched. A file any record names, a writer has registered in
    /// flight, or a path outside the library directory is kept. A missing,
    /// non-directory, or symlinked directory is skipped rather than followed.
    ///
    /// A rendering file carries its worker's pid. While that pid is alive the
    /// whole preparation directory is left alone, because the render has not
    /// published its output yet; `<media>` temporaries are still swept. If a
    /// record names a stored path outside the library directory nothing is
    /// removed, matching `sweepUnreferencedMedia`: the store and this disk
    /// describe different locations. A failed removal is counted and the sweep
    /// continues; only the store read can throw.
    public func removeAbandonedPreparationScratch(
        in mediaDirectory: URL
    ) throws -> PreparationScratchSweep {
        let stored = try storedMediaPaths()
        guard stored.outsideLibrary == 0 else {
            return PreparationScratchSweep(removed: 0, bytes: 0, failed: 0, skippedLiveWorker: false)
        }

        let manager = FileManager.default
        let preparedPattern = try? NSRegularExpression(pattern: "^prepared-.+")
        let renderingPattern = try? NSRegularExpression(
            pattern: #"^\.prepared-.+\.rendering-([0-9]+)(\.[A-Za-z0-9]+)?$"#
        )
        let candidatePattern = try? NSRegularExpression(
            pattern: #"^\.candidate-.+\.m4a\.tmp-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.m4a$"#
        )
        let audiobookPattern = try? NSRegularExpression(
            pattern: #"^\.audiobook-.+-v[0-9]+\.tmp\.m4a$"#
        )

        func firstMatch(_ expression: NSRegularExpression?, _ name: String) -> NSTextCheckingResult? {
            guard let expression else { return nil }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return expression.firstMatch(in: name, options: [], range: range)
        }

        var removed = 0
        var bytes: Int64 = 0
        var failed = 0
        var skippedLiveWorker = false

        func removeIfAbandoned(_ url: URL, size: Int64) {
            let path = url.standardizedFileURL.path
            guard isInsideLibraryDirectory(url),
                  !stored.reachable.contains(path),
                  !inFlightMedia.isInFlight(url) else { return }
            do {
                try manager.removeItem(at: url)
                removed += 1
                bytes += size
            } catch {
                failed += 1
            }
        }

        guard let mediaNames = Self.directChildNames(of: mediaDirectory, manager: manager) else {
            return PreparationScratchSweep(removed: 0, bytes: 0, failed: 0, skippedLiveWorker: false)
        }

        let preparation = mediaDirectory.appendingPathComponent("preparation", isDirectory: true)
        if let names = Self.directChildNames(of: preparation, manager: manager) {
            var candidates: [(url: URL, size: Int64)] = []
            var hasLiveWorker = false
            for name in names {
                let url = preparation.appendingPathComponent(name)
                guard let size = Self.regularScratchFile(at: url) else { continue }
                if firstMatch(preparedPattern, name) != nil {
                    candidates.append((url, size))
                } else if let rendering = firstMatch(renderingPattern, name),
                          let pidRange = Range(rendering.range(at: 1), in: name) {
                    candidates.append((url, size))
                    if Self.isProcessAlive(String(name[pidRange])) {
                        hasLiveWorker = true
                    }
                }
            }
            if hasLiveWorker {
                skippedLiveWorker = true
            } else {
                for candidate in candidates {
                    removeIfAbandoned(candidate.url, size: candidate.size)
                }
            }
        }

        for name in mediaNames {
            guard firstMatch(candidatePattern, name) != nil
                || firstMatch(audiobookPattern, name) != nil else { continue }
            let url = mediaDirectory.appendingPathComponent(name)
            guard let size = Self.regularScratchFile(at: url) else { continue }
            removeIfAbandoned(url, size: size)
        }

        return PreparationScratchSweep(
            removed: removed, bytes: bytes, failed: failed, skippedLiveWorker: skippedLiveWorker
        )
    }

    /// The names of `directory`'s direct children, or nil when it is missing,
    /// not a directory, or a symbolic link.
    private static func directChildNames(of directory: URL, manager: FileManager) -> [String]? {
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let attributes = try? manager.attributesOfItem(atPath: directory.path),
              (attributes[.type] as? FileAttributeType) == FileAttributeType.typeDirectory else { return nil }
        return try? manager.contentsOfDirectory(atPath: directory.path)
    }

    /// The size of `url` when it is a regular file, or nil when it is missing,
    /// a directory, a symbolic link, or otherwise not removable scratch.
    private static func regularScratchFile(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return Int64(values.fileSize ?? 0)
    }

    /// Whether `raw` is a pid the kernel still recognizes. A pid that does not
    /// fit in `pid_t`, or is zero, is never alive.
    private static func isProcessAlive(_ raw: String) -> Bool {
        guard let pid = pid_t(raw), pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
