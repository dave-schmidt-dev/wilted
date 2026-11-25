import Foundation
import OSLog
import WiltedLibrary

private let showSpeedOutboxLog = Logger(subsystem: "com.zerodelta.wilted", category: "ShowPlaybackSpeedOutbox")

/// The phone's durable, account-bound queue for Mac-authoritative show-rate edits.
struct LibraryShowPlaybackSpeedOutbox: Sendable {
    static let version = 1

    struct Command: Codable, Equatable, Sendable {
        let intent: LibraryIntent
        var sentAt: Date?
        var reservedAt: Date? = nil
        var conflict = false
        /// Keeps an applied picker value effective until the stats projection catches up.
        var appliedRevision: Int64? = nil

        var feedID: String {
            guard case let .setShowPlaybackSpeed(feedID, _, _) = intent.action else { return "" }
            return feedID.rawValue
        }
        var speed: Double? {
            guard case let .setShowPlaybackSpeed(_, speed, _) = intent.action else { return nil }
            return speed
        }
        var basedOnRevision: Int64? {
            guard case let .setShowPlaybackSpeed(_, _, revision) = intent.action else { return nil }
            return revision
        }
    }

    struct Saved: Codable, Equatable, Sendable {
        var ownerToken: String?
        var speeds: [String: LibraryShowPlaybackSpeed] = [:]
        var commands: [Command] = []
    }

    enum Loaded: Equatable, Sendable { case empty, saved(Saved), unreadable }

    let url: URL?
    private var setAsideURL: URL? { url.map { $0.deletingPathExtension().appendingPathExtension("unreadable.json") } }

    func load(fileManager: FileManager = .default) -> Loaded {
        guard let url else { return .empty }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            if !fileManager.fileExists(atPath: url.path) { return .empty }
            showSpeedOutboxLog.error("Saved show speeds are unreadable; keeping the file and disabling writes.")
            return .unreadable
        }
        guard let version = try? JSONDecoder().decode(VersionProbe.self, from: data).version else {
            return setAside(url, reason: "the file is damaged", fileManager: fileManager) ? .empty : .unreadable
        }
        guard version == Self.version,
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.saved.speeds.allSatisfy({ $0.key == $0.value.feedID.rawValue }),
              file.saved.commands.allSatisfy({ !$0.intent.id.isEmpty && !$0.feedID.isEmpty }) else {
            return setAside(url, reason: "the version or entries are unsupported", fileManager: fileManager) ? .empty : .unreadable
        }
        return .saved(file.saved)
    }

    func save(_ saved: Saved, fileManager: FileManager = .default) throws {
        guard let url else { return }
        guard saved.speeds.allSatisfy({ $0.key == $0.value.feedID.rawValue }),
              saved.commands.allSatisfy({ !$0.intent.id.isEmpty && !$0.feedID.isEmpty }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let data = try JSONEncoder().encode(File(version: Self.version, saved: saved))
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
    }

    private func setAside(_ url: URL, reason: String, fileManager: FileManager) -> Bool {
        guard let aside = setAsideURL else { return false }
        do {
            try fileManager.moveItem(at: url, to: aside)
            showSpeedOutboxLog.error("Set aside show speeds because \(reason, privacy: .public).")
            return true
        } catch {
            showSpeedOutboxLog.error("Could not set aside show speeds (\(reason, privacy: .public)).")
            return false
        }
    }
}

private struct VersionProbe: Decodable { let version: Int }
private struct File: Codable { let version: Int; let saved: LibraryShowPlaybackSpeedOutbox.Saved }
