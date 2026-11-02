import Foundation
import OSLog
import WiltedDomain

private let jobLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryMediaJob")

/// How far the Mac has got with a job, as the row says it.
enum LibraryMediaJobStage: String, Codable, Sendable, Equatable {
    case sent
    case queued
    case sending
    case downloading

    var requestStage: LibraryMediaRequestStage {
        switch self {
        case .sent: .sent
        case .queued: .queued
        case .sending, .downloading: .sending
        }
    }
}

/// One media request kept across relaunch: the entry, the revision once the Mac has offered one, the
/// single intent id every try of the request carries, how far it got, and when the next try is due.
struct LibraryMediaJob: Codable, Sendable, Equatable {
    /// Age after which an unserved intent is replaced with a fresh id, so the Mac (which ignores an
    /// intent older than its 7-day `maximumIntentAge`) never drops a request that is still wanted.
    static let intentReissueAge: TimeInterval = 6 * 24 * 60 * 60

    var entryID: ItemID
    var revisionID: RevisionID?
    var intentID: String
    var stage: LibraryMediaJobStage
    /// When the job tries again after a passing cause; nil while it is not waiting.
    var nextAttempt: Date?
    /// True when `nextAttempt` is a wait for the Mac rather than for iCloud, so a relaunch words it the same.
    var waitsOnMac: Bool
    /// When the current intent was created.
    var intentCreatedAt: Date
    /// When the person asked, for the row's elapsed time.
    var requestedSince: Date
    /// Whether the current intent reached iCloud, so a relaunch or a retry does not send it again.
    var requestSent: Bool
    /// Passing causes in a row, for the backoff step.
    var waits: Int
    /// The verification mismatch seen last and how many times in a row.
    var mismatchKey: String?
    var mismatchCount: Int
    /// True when `nextAttempt` waits for the saved account to be verified, which a direct download needs
    /// before it starts (D5). Optional so a file written before the direct path still decodes.
    var waitsOnOwner: Bool?
    /// The content hash the direct path has already given up on in this job, so a later pass goes
    /// straight to iCloud instead of looking for the Mac again. Optional for the same reason.
    var directFailedFor: String?

    init(entryID: ItemID, intentID: String, createdAt: Date) {
        self.entryID = entryID
        self.revisionID = nil
        self.intentID = intentID
        self.stage = .sent
        self.nextAttempt = nil
        self.waitsOnMac = false
        self.intentCreatedAt = createdAt
        self.requestedSince = createdAt
        self.requestSent = false
        self.waits = 0
        self.mismatchKey = nil
        self.mismatchCount = 0
    }
}

/// Persists active media jobs in a versioned JSON file in the app's support folder, so a request that is
/// waiting out a passing cause survives relaunch with its intent id and retry time.
///
/// A file that exists but cannot be read (a locked phone before first unlock) is left alone and nothing
/// is saved over it. A damaged or newer file is set aside, never deleted.
struct LibraryMediaJobStore: Sendable {
    static let version = 1

    struct Saved: Equatable, Sendable {
        var ownerToken: String?
        var jobs: [LibraryMediaJob] = []
    }

    enum Loaded: Equatable, Sendable {
        case empty
        case saved(Saved)
        case unreadable
    }

    let url: URL?

    var setAsideURL: URL? {
        url.map { $0.deletingPathExtension().appendingPathExtension("unreadable.json") }
    }

    func load(fileManager: FileManager = .default) -> Loaded {
        guard let url else { return .empty }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            if !fileManager.fileExists(atPath: url.path) { return .empty }
            jobLog.error("Saved media jobs could not be read; keeping the file and saving nothing over it.")
            return .unreadable
        }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            setAside(url, reason: "it is damaged", fileManager: fileManager)
            return .empty
        }
        guard probe.version == Self.version else {
            setAside(url, reason: "it has version \(probe.version), not \(Self.version)", fileManager: fileManager)
            return .empty
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            setAside(url, reason: "its entries are damaged or unknown", fileManager: fileManager)
            return .empty
        }
        return .saved(Saved(ownerToken: file.ownerToken, jobs: file.jobs))
    }

    func loadJobs() -> [LibraryMediaJob] {
        if case let .saved(saved) = load() { return saved.jobs }
        return []
    }

    func saveJob(_ job: LibraryMediaJob, ownerToken: String?) {
        update(ownerToken: ownerToken) { jobs in
            jobs.removeAll { $0.entryID == job.entryID }
            jobs.append(job)
        }
    }

    func removeJob(entryID: ItemID, ownerToken: String?) {
        update(ownerToken: ownerToken) { $0.removeAll { $0.entryID == entryID } }
    }

    func removeAll(ownerToken: String?) {
        update(ownerToken: ownerToken) { $0 = [] }
    }

    /// Reads, changes and writes the jobs. Does nothing over an unreadable file, and never creates a
    /// file just to say there are no jobs.
    private func update(ownerToken: String?, _ change: (inout [LibraryMediaJob]) -> Void) {
        guard let url else { return }
        var jobs: [LibraryMediaJob]
        switch load() {
        case .unreadable: return
        case .empty: jobs = []
        case let .saved(saved): jobs = saved.jobs
        }
        let before = jobs
        change(&jobs)
        guard jobs != before else { return }
        do {
            let data = try JSONEncoder().encode(File(ownerToken: ownerToken, jobs: jobs))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
        } catch {
            jobLog.error("Media jobs could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setAside(_ url: URL, reason: String, fileManager: FileManager) {
        guard let aside = setAsideURL else { return }
        do {
            if fileManager.fileExists(atPath: aside.path) { try fileManager.removeItem(at: aside) }
            try fileManager.moveItem(at: url, to: aside)
            jobLog.error("Set aside saved media jobs because \(reason, privacy: .public); none will be resumed.")
        } catch {
            jobLog.error("Could not set aside saved media jobs (\(reason, privacy: .public)); the next save replaces them.")
        }
    }
}

private struct VersionProbe: Decodable { let version: Int }

private struct File: Codable {
    var version = LibraryMediaJobStore.version
    let ownerToken: String?
    let jobs: [LibraryMediaJob]
}
