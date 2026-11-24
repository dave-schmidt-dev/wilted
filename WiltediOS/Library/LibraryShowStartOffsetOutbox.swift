import Foundation
import OSLog
import WiltedLibrary

private let showOffsetOutboxLog = Logger(subsystem: "com.zerodelta.wilted", category: "ShowStartOffsetOutbox")

/// The phone's versioned, owner-bound queue for Mac-authoritative offset edits.
struct LibraryShowStartOffsetOutbox: Sendable {
    static let version = 1

    struct Command: Codable, Equatable, Sendable {
        let intent: LibraryIntent
        var sentAt: Date?
        /// Durable reservation written before awaiting transport; cleared on relaunch for retry.
        var reservedAt: Date? = nil
        var conflict = false

        var feedID: String {
            guard case let .setShowStartOffset(feedID, _, _) = intent.action else { return "" }
            return feedID.rawValue
        }
        var seconds: Double? {
            guard case let .setShowStartOffset(_, seconds, _) = intent.action else { return nil }
            return seconds
        }
    }

    struct Saved: Codable, Equatable, Sendable {
        var ownerToken: String?
        var offsets: [String: LibraryShowStartOffset] = [:]
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
            showOffsetOutboxLog.error("Saved show offsets are unreadable; keeping the file and disabling writes.")
            return .unreadable
        }
        guard let version = try? JSONDecoder().decode(VersionProbe.self, from: data).version else {
            return setAside(url, reason: "the file is damaged", fileManager: fileManager) ? .empty : .unreadable
        }
        guard version == Self.version,
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.saved.offsets.allSatisfy({ $0.key == $0.value.feedID.rawValue }),
              file.saved.commands.allSatisfy({ !$0.intent.id.isEmpty && $0.feedID != "" }) else {
            return setAside(url, reason: "the version or entries are unsupported", fileManager: fileManager) ? .empty : .unreadable
        }
        return .saved(file.saved)
    }

    func save(_ saved: Saved, fileManager: FileManager = .default) throws {
        guard let url else { return }
        guard saved.offsets.allSatisfy({ $0.key == $0.value.feedID.rawValue }),
              saved.commands.allSatisfy({ !$0.intent.id.isEmpty && $0.feedID != "" }) else {
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
            showOffsetOutboxLog.error("Set aside show offsets because \(reason, privacy: .public).")
            return true
        } catch {
            showOffsetOutboxLog.error("Could not set aside show offsets (\(reason, privacy: .public)).")
            return false
        }
    }
}

private struct VersionProbe: Decodable { let version: Int }
private struct File: Codable { let version: Int; let saved: LibraryShowStartOffsetOutbox.Saved }
