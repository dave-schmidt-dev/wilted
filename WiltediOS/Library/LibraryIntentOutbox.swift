import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let outboxLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryOutbox")

/// The phone's intents that the Mac does not have yet, on disk, so a kill or a crash before the send
/// cannot lose a decision, an Add, a media acknowledgement or ad feedback. The model writes the whole unsent set
/// before it sends and rewrites it without an intent once the transport accepted that intent; at the
/// next launch the saved intents are tracked again and the next sync round sends them with their own
/// ids, which the Mac applies at most once.
///
/// One versioned JSON file, replaced atomically on every write and stamped with the library owner it
/// belongs to, so it never replays into another iCloud account. A file this build cannot read (damaged,
/// or written by a newer build) is set aside next to it, never replayed and never silently deleted.
/// Written with `LibraryFileProtection` so Siri and CarPlay can save while the phone is locked.
struct LibraryIntentOutbox: Sendable {
    /// The file's shape. Any other version is set aside unread.
    static let version = 1

    /// A row decision as saved: what `PendingDecision` needs to be tracked again after a relaunch.
    struct Decision: Equatable, Sendable {
        let intent: LibraryIntent
        let baseline: EntryPlacement
        let isSilent: Bool
        let retiresEpisode: Bool
        let supersededByRestore: Bool
    }

    struct Add: Equatable, Sendable {
        let intent: LibraryIntent
        let title: String
    }

    struct Saved: Equatable, Sendable {
        /// The library owner the intents were made under; nil before the mirror knew one.
        var ownerToken: String?
        var decisions: [Decision] = []
        var adds: [Add] = []
        /// `mediaCached` intents, one per entry, ordered by intent id.
        var acknowledgements: [LibraryIntent] = []
        /// `adFeedback` intents in the order they were made.
        var adFeedback: [LibraryIntent] = []

        var intents: [LibraryIntent] { decisions.map(\.intent) + adds.map(\.intent) + acknowledgements + adFeedback }

        var intentIDs: Set<String> { Set(intents.map(\.id)) }
    }

    /// What a launch found on disk.
    enum Loaded: Equatable, Sendable {
        /// No file, or one that was set aside: start empty and write freely.
        case empty
        case saved(Saved)
        /// The file is there but could not be read (for example before the first unlock): keep it as it
        /// is and write nothing this run, so it is never replaced by a smaller set.
        case unreadable
    }

    /// nil keeps the outbox in memory only (tests, previews), so nothing in it counts as saved.
    let url: URL?

    /// Where an unreadable file is moved; one place, so a repeat replaces the older copy.
    var setAsideURL: URL? {
        url.map { $0.deletingPathExtension().appendingPathExtension("unreadable.json") }
    }

    func load(fileManager: FileManager = .default) -> Loaded {
        guard let url else { return .empty }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            if !fileManager.fileExists(atPath: url.path) { return .empty }
            outboxLog.error("The saved intents could not be read; keeping the file and saving nothing new this run.")
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
        // An `.unsupported` placeholder never encodes, so keeping one would make every later save fail.
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              !file.saved.intents.contains(where: { $0.action == .unsupported }) else {
            setAside(url, reason: "its entries are damaged or unknown", fileManager: fileManager)
            return .empty
        }
        return .saved(file.saved)
    }

    /// Replaces the file with `saved` in one atomic write. Throws when it could not be written, so the
    /// caller never counts an intent as saved that is not on disk.
    func save(_ saved: Saved, fileManager: FileManager = .default) throws {
        guard let url else { return }
        let data = try JSONEncoder().encode(File(saved))
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
    }

    private func setAside(_ url: URL, reason: String, fileManager: FileManager) {
        guard let aside = setAsideURL else { return }
        do {
            if fileManager.fileExists(atPath: aside.path) { try fileManager.removeItem(at: aside) }
            try fileManager.moveItem(at: url, to: aside)
            outboxLog.error("Set aside the saved intents because \(reason, privacy: .public); none of them will be sent.")
        } catch {
            outboxLog.error("Could not set aside the saved intents (\(reason, privacy: .public)); the next save replaces them.")
        }
    }
}

// MARK: - File format, version 1

private struct VersionProbe: Decodable { let version: Int }

private struct File: Codable {
    struct Decision: Codable {
        let intent: LibraryIntent
        let removal: LibraryRemoval
        let isQueued: Bool
        let predecessor: ItemID?
        let isSilent: Bool
        let retiresEpisode: Bool
        let supersededByRestore: Bool
    }

    struct Add: Codable {
        let intent: LibraryIntent
        let title: String
    }

    let version: Int
    let ownerToken: String?
    let decisions: [Decision]
    let adds: [Add]
    let acknowledgements: [LibraryIntent]
    /// Added after version 1 shipped, so optional: a file without it still loads, and the version stays 1.
    let adFeedback: [LibraryIntent]?

    init(_ saved: LibraryIntentOutbox.Saved) {
        version = LibraryIntentOutbox.version
        ownerToken = saved.ownerToken
        decisions = saved.decisions.map {
            Decision(intent: $0.intent, removal: $0.baseline.removal, isQueued: $0.baseline.isQueued,
                     predecessor: $0.baseline.predecessor, isSilent: $0.isSilent, retiresEpisode: $0.retiresEpisode,
                     supersededByRestore: $0.supersededByRestore)
        }
        adds = saved.adds.map { Add(intent: $0.intent, title: $0.title) }
        acknowledgements = saved.acknowledgements
        adFeedback = saved.adFeedback.isEmpty ? nil : saved.adFeedback
    }

    var saved: LibraryIntentOutbox.Saved {
        LibraryIntentOutbox.Saved(
            ownerToken: ownerToken,
            decisions: decisions.map {
                LibraryIntentOutbox.Decision(
                    intent: $0.intent,
                    baseline: EntryPlacement(removal: $0.removal, isQueued: $0.isQueued, predecessor: $0.predecessor),
                    isSilent: $0.isSilent, retiresEpisode: $0.retiresEpisode, supersededByRestore: $0.supersededByRestore)
            },
            adds: adds.map { LibraryIntentOutbox.Add(intent: $0.intent, title: $0.title) },
            acknowledgements: acknowledgements, adFeedback: adFeedback ?? [])
    }
}
