import Foundation
import Combine
import OSLog
import WiltedLibrary

private let storyOutboxLog = Logger(subsystem: "com.zerodelta.wilted", category: "HeadlineOutbox")

/// The phone's versioned, owner-bound cache and retry queue for headline actions.
struct LibraryStoryCommandOutboxV1: Sendable {
    static let version = 1
    static let maximumCommands = 256

    enum Action: Codable, Equatable, Sendable {
        case save(story: LibraryHeadlineStory, isSaved: Bool, basedOnRevision: Int64)
        case mute(publisherID: String, isMuted: Bool, basedOnRevision: Int64)
    }

    enum Delivery: String, Codable, Sendable {
        case pending
        case sent
        case conflict
        case failed
    }

    struct Command: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let ownerToken: String
        let createdAt: Date
        let action: Action
        var delivery: Delivery
        var detail: String?

        var storyID: String? {
            if case let .save(story, _, _) = action { return story.id }
            return nil
        }

        var publisherID: String? {
            if case let .mute(publisherID, _, _) = action { return publisherID }
            return nil
        }
    }

    struct Saved: Codable, Equatable, Sendable {
        private static let formatVersion = LibraryStoryCommandOutboxV1.version
        let version: Int
        var ownerToken: String?
        var projection: LibraryHeadlineProjection?
        var commands: [Command]

        init(ownerToken: String? = nil, projection: LibraryHeadlineProjection? = nil, commands: [Command] = []) {
            version = Self.formatVersion
            self.ownerToken = ownerToken
            self.projection = projection
            self.commands = commands
        }

        private enum CodingKeys: String, CodingKey { case version, ownerToken, projection, commands }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let version = try values.decode(Int.self, forKey: .version)
            guard version == Self.formatVersion else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "unsupported headline outbox version")
            }
            self.version = version
            ownerToken = try values.decodeIfPresent(String.self, forKey: .ownerToken)
            projection = try values.decodeIfPresent(LibraryHeadlineProjection.self, forKey: .projection)
            commands = try values.decodeIfPresent([Command].self, forKey: .commands) ?? []
            guard commands.count <= LibraryStoryCommandOutboxV1.maximumCommands,
                  Set(commands.map(\.id)).count == commands.count else {
                throw DecodingError.dataCorruptedError(forKey: .commands, in: values, debugDescription: "headline outbox exceeds its bounds")
            }
        }
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
            storyOutboxLog.error("The saved headline state could not be read; keeping it and disabling writes.")
            return .unreadable
        }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
              probe.version == Self.version,
              let saved = try? JSONDecoder().decode(Saved.self, from: data), Self.isValid(saved) else {
            guard setAside(url, fileManager: fileManager) else { return .unreadable }
            storyOutboxLog.error("Set aside unreadable headline state; it will not be replayed.")
            return .empty
        }
        return .saved(saved)
    }

    func save(_ saved: Saved, fileManager: FileManager = .default) throws {
        guard let url else { return }
        guard Self.isValid(saved) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let data = try JSONEncoder().encode(saved)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
    }

    private func setAside(_ url: URL, fileManager: FileManager) -> Bool {
        guard let aside = setAsideURL else { return false }
        do {
            if fileManager.fileExists(atPath: aside.path) { try fileManager.removeItem(at: aside) }
            try fileManager.moveItem(at: url, to: aside)
            return true
        } catch {
            storyOutboxLog.error("Could not set aside unreadable headline state.")
            return false
        }
    }

    private static func isValid(_ saved: Saved) -> Bool {
        guard saved.version == Self.version,
              saved.commands.count <= Self.maximumCommands,
              Set(saved.commands.map(\.id)).count == saved.commands.count,
              saved.projection.map({
                  $0.recent.count <= LibraryHeadlineProjectionPage.maximumStories * LibraryHeadlineProjectionIndex.maximumPagesPerSection
                      && $0.saved.count <= LibraryHeadlineProjectionPage.maximumStories * LibraryHeadlineProjectionIndex.maximumPagesPerSection
                      && $0.publishers.count <= LibraryHeadlineProjectionPage.maximumPublishers * LibraryHeadlineProjectionIndex.maximumPagesPerSection
                      && $0.expiredIdentities.count <= LibraryHeadlineProjectionPage.maximumExpiredIdentities * LibraryHeadlineProjectionIndex.maximumPagesPerSection
              }) ?? true else { return false }
        if let owner = saved.ownerToken {
            guard !owner.isEmpty, owner.count <= 1_024 else { return false }
        } else if saved.projection != nil || !saved.commands.isEmpty {
            return false
        }
        return saved.commands.allSatisfy {
            !$0.id.isEmpty && $0.id.count <= 256 && $0.ownerToken == saved.ownerToken
                && $0.createdAt.timeIntervalSinceReferenceDate.isFinite
                && ($0.detail?.count ?? 0) <= 4_096
        }
    }

    static func defaultURL(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        directory.appendingPathComponent("Wilted", isDirectory: true)
            .appendingPathComponent("headline-state.json", isDirectory: false)
    }
}

/// Keeps the last Mac projection available offline and writes commands before the phone sends them.
@MainActor
final class LibraryHeadlinePhoneState: ObservableObject {
    @Published private(set) var projection: LibraryHeadlineProjection?
    @Published private(set) var commands: [LibraryStoryCommandOutboxV1.Command]
    @Published private(set) var writeFailed = false
    @Published private(set) var refreshFailed = false
    @Published var actionNotice: String?

    private let outbox: LibraryStoryCommandOutboxV1
    private var ownerToken: String?
    private var operationGeneration: UInt64?
    @Published private(set) var isBoundToLocalOwner = false
    private var writable = true
    private var isSendingCommands = false

    init(url: URL?) {
        outbox = LibraryStoryCommandOutboxV1(url: url)
        switch outbox.load() {
        case .empty:
            projection = nil
            commands = []
        case let .saved(saved):
            projection = saved.projection
            commands = saved.commands
            ownerToken = saved.ownerToken
        case .unreadable:
            projection = nil
            commands = []
            writeFailed = true
            writable = false
        }
    }

    var ownerForActions: String? { isBoundToLocalOwner ? ownerToken : nil }

    /// Binds the disk projection to the library owner already held by the local library store.
    /// Network writes still require a current operation generation and account verification.
    func bindLocalOwner(_ verifiedOwner: String?, generation: UInt64, reviewHold: Bool) {
        operationGeneration = generation
        guard !reviewHold else {
            isBoundToLocalOwner = false
            return
        }
        guard let verifiedOwner else { isBoundToLocalOwner = false; return }
        if ownerToken != verifiedOwner {
            ownerToken = verifiedOwner
            projection = nil
            commands = []
            _ = commit(LibraryStoryCommandOutboxV1.Saved(ownerToken: verifiedOwner))
        } else {
            ownerToken = verifiedOwner
        }
        isBoundToLocalOwner = true
    }

    func isCurrent(owner: String, generation: UInt64) -> Bool {
        writable && ownerToken == owner && operationGeneration == generation
    }

    func replaceProjection(_ value: LibraryHeadlineProjection, owner: String, generation: UInt64) {
        guard isCurrent(owner: owner, generation: generation), projection != value else { return }
        var saved = currentSaved()
        saved.ownerToken = owner
        saved.projection = value
        commit(saved)
    }

    func noteRefreshFailure(_ failed: Bool) { refreshFailed = failed }

    func beginSendingCommands() -> Bool {
        guard !isSendingCommands else { return false }
        isSendingCommands = true
        return true
    }

    func finishSendingCommands() { isSendingCommands = false }

    @discardableResult
    func enqueue(_ command: LibraryStoryCommandOutboxV1.Command) -> Bool {
        guard writable, ownerToken == command.ownerToken, Self.validCommand(command, ownerToken: ownerToken),
              !commands.contains(where: { $0.id == command.id }),
              commands.count < LibraryStoryCommandOutboxV1.maximumCommands else { return false }
        var saved = currentSaved()
        saved.commands.append(command)
        return commit(saved)
    }

    func update(_ command: LibraryStoryCommandOutboxV1.Command) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
        var saved = currentSaved()
        saved.commands[index] = command
        _ = commit(saved)
    }

    func removeCommand(id: String) {
        guard commands.contains(where: { $0.id == id }) else { return }
        var saved = currentSaved()
        saved.commands.removeAll { $0.id == id }
        _ = commit(saved)
    }

    func reset(for owner: String?, generation: UInt64) {
        ownerToken = owner
        operationGeneration = generation
        isBoundToLocalOwner = owner != nil
        projection = nil
        commands = []
        guard writable else { return }
        _ = commit(LibraryStoryCommandOutboxV1.Saved(ownerToken: owner))
    }

    private func currentSaved() -> LibraryStoryCommandOutboxV1.Saved {
        LibraryStoryCommandOutboxV1.Saved(ownerToken: ownerToken, projection: projection, commands: commands)
    }

    private static func validCommand(_ command: LibraryStoryCommandOutboxV1.Command, ownerToken: String?) -> Bool {
        !command.id.isEmpty && command.id.count <= 256 && ownerToken != nil && command.ownerToken == ownerToken
            && command.createdAt.timeIntervalSinceReferenceDate.isFinite && (command.detail?.count ?? 0) <= 4_096
    }

    @discardableResult
    private func commit(_ saved: LibraryStoryCommandOutboxV1.Saved) -> Bool {
        guard writable else { writeFailed = true; return false }
        do {
            try outbox.save(saved)
            projection = saved.projection
            commands = saved.commands
            ownerToken = saved.ownerToken
            writeFailed = false
            return true
        } catch {
            writeFailed = true
            return false
        }
    }
}

private struct VersionProbe: Decodable { let version: Int }
