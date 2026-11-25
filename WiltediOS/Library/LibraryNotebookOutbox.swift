import Combine
import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let notebookOutboxLog = Logger(subsystem: "com.zerodelta.wilted", category: "NotebookOutbox")

/// Local, account-partitioned Notebook records and the commands that are not settled yet.
/// Old-owner rows stay on disk, but only the currently bound scope is exposed to the UI.
struct LibraryNotebookOutbox: Sendable {
    static let version = 1
    static let maximumScopes = 32
    static let maximumEntries = 10_000
    static let maximumCommands = 2_048
    static let maximumFileBytes = 32 * 1_024 * 1_024

    enum Delivery: String, Codable, Sendable { case pending, sent, conflict, failed }

    struct Record: Codable, Equatable, Sendable, Identifiable {
        var entry: LibraryNotebookEntry
        var serverVersion: UInt64
        var id: ItemID { entry.id }
    }

    struct Command: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let scope: NotebookLocalScope
        let createdAt: Date
        var entry: LibraryNotebookEntry
        var serverEntry: LibraryNotebookEntry? = nil
        var baseVersion: UInt64
        var delivery: Delivery
        var detail: String?

        var isTerminal: Bool { delivery == .conflict || delivery == .failed }
    }

    struct ScopeState: Codable, Equatable, Sendable {
        let scope: NotebookLocalScope
        var records: [Record]
        var commands: [Command]
    }

    struct Saved: Codable, Equatable, Sendable {
        let version: Int
        var scopes: [ScopeState]

        init(scopes: [ScopeState] = []) {
            version = Self.formatVersion
            self.scopes = scopes
        }

        private enum CodingKeys: String, CodingKey { case version, scopes }
        private static let formatVersion = LibraryNotebookOutbox.version

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let version = try values.decode(Int.self, forKey: .version)
            guard version == Self.formatVersion else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "unsupported Notebook outbox version")
            }
            self.version = version
            scopes = try values.decodeIfPresent([ScopeState].self, forKey: .scopes) ?? []
            guard LibraryNotebookOutbox.isValid(self) else {
                throw DecodingError.dataCorruptedError(forKey: .scopes, in: values, debugDescription: "invalid Notebook outbox contents")
            }
        }
    }

    enum Loaded: Equatable, Sendable { case empty, saved(Saved), unreadable }

    enum WriteError: Error, Equatable { case unavailable, full, invalid }

    let url: URL?

    private var unreadableURL: URL? { url.map { $0.deletingPathExtension().appendingPathExtension("unreadable.json") } }

    func load(fileManager: FileManager = .default) -> Loaded {
        guard let url, fileManager.fileExists(atPath: url.path) else { return .empty }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            notebookOutboxLog.error("Saved Notebook data could not be read; keeping the file and disabling writes.")
            return .unreadable
        }
        guard data.count <= Self.maximumFileBytes,
              let saved = try? JSONDecoder().decode(Saved.self, from: data), Self.isValid(saved) else {
            guard setAside(url, fileManager: fileManager) else { return .unreadable }
            notebookOutboxLog.error("Set aside unreadable Notebook data; it will not be replayed.")
            return .unreadable
        }
        return .saved(saved)
    }

    func save(_ saved: Saved, fileManager: FileManager = .default) throws {
        guard let url else { throw WriteError.unavailable }
        guard Self.isValid(saved) else { throw WriteError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(saved)
        guard data.count <= Self.maximumFileBytes else { throw WriteError.full }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
    }

    static func defaultURL(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        directory.appendingPathComponent("Wilted", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("notebook-state.json", isDirectory: false)
    }

    private func setAside(_ url: URL, fileManager: FileManager) -> Bool {
        guard let base = unreadableURL else { return false }
        let aside = fileManager.fileExists(atPath: base.path)
            ? base.deletingLastPathComponent().appendingPathComponent("notebook-state-unreadable-\(UUID().uuidString).json")
            : base
        do { try fileManager.moveItem(at: url, to: aside); return true }
        catch {
            notebookOutboxLog.error("Could not preserve the unreadable Notebook file.")
            return false
        }
    }

    private static func isValid(_ saved: Saved) -> Bool {
        guard saved.version == version, saved.scopes.count <= maximumScopes,
              Set(saved.scopes.map(\.scope)).count == saved.scopes.count,
              saved.scopes.allSatisfy({
                  (try? NotebookLocalScope(ownerToken: $0.scope.ownerToken, deviceID: $0.scope.deviceID)) == $0.scope
              }) else { return false }
        let entries = saved.scopes.reduce(0) { $0 + $1.records.count }
        let commands = saved.scopes.reduce(0) { $0 + $1.commands.count }
        guard entries <= maximumEntries, commands <= maximumCommands else { return false }
        for bucket in saved.scopes {
            guard Set(bucket.records.map(\.id)).count == bucket.records.count,
                  Set(bucket.commands.map(\.id)).count == bucket.commands.count,
                  Set(bucket.commands.map { $0.entry.id }).count == bucket.commands.count else { return false }
            for command in bucket.commands {
                guard command.scope == bucket.scope, !command.id.isEmpty, command.id.count <= 256,
                      command.createdAt.timeIntervalSince1970.isFinite,
                      (command.detail?.utf8.count ?? 0) <= 4_096,
                      bucket.records.contains(where: { $0.id == command.entry.id }) else { return false }
            }
        }
        return true
    }
}

/// Main-actor projection for the iPhone's durable Notebook catalog and command queue.
@MainActor
final class LibraryNotebookPhoneState: ObservableObject {
    @Published private(set) var entries: [LibraryNotebookEntry] = []
    @Published private(set) var commands: [LibraryNotebookOutbox.Command] = []
    @Published private(set) var writeFailed = false
    @Published private(set) var readFailed = false
    @Published private(set) var replayableIDs: Set<ItemID> = []
    @Published private(set) var excerptPendingIDs: Set<ItemID> = []
    @Published private(set) var lastCapturedEntryID: ItemID?
    @Published private(set) var lastDeletedEntryID: ItemID?
    @Published private(set) var isCaptureInProgress = false
    @Published var notice: String?
    @Published private(set) var isBoundToLocalScope = false

    private let outbox: LibraryNotebookOutbox
    private var saved: LibraryNotebookOutbox.Saved
    private(set) var activeScope: NotebookLocalScope?
    private var operationGeneration: UInt64?
    private var heldForAccountReview = false
    private var writable = true
    private var excerptPendingByScope: [NotebookLocalScope: Set<ItemID>] = [:]
    private var excerptAttempts: [NotebookLocalScope: [ItemID: (revision: RevisionID, at: Date)]] = [:]

    init(url: URL?) {
        outbox = LibraryNotebookOutbox(url: url)
        switch outbox.load() {
        case .empty:
            saved = .init()
        case let .saved(value):
            saved = value
        case .unreadable:
            saved = .init()
            writable = false
            readFailed = true
            writeFailed = true
            notice = "Saved Notebook data could not be read. Existing data was kept; Notebook changes are disabled."
        }
    }

    var isHeldForAccountReview: Bool { heldForAccountReview }
    var ownerForActions: String? { isBoundToLocalScope ? activeScope?.ownerToken : nil }

    func bind(ownerToken: String?, deviceID: String, generation: UInt64, reviewHold: Bool) {
        let previousScope = activeScope
        let previousGeneration = operationGeneration
        operationGeneration = generation
        heldForAccountReview = reviewHold
        guard !reviewHold, let scope = try? NotebookLocalScope(ownerToken: ownerToken, deviceID: deviceID) else {
            activeScope = nil
            isBoundToLocalScope = false
            entries = []
            commands = []
            replayableIDs = []
            excerptPendingIDs = []
            lastCapturedEntryID = nil
            lastDeletedEntryID = nil
            notice = nil
            return
        }
        activeScope = scope
        isBoundToLocalScope = true
        if previousScope != scope || previousGeneration != generation {
            replayableIDs = []
            lastCapturedEntryID = nil
            lastDeletedEntryID = nil
            notice = nil
            excerptPendingIDs = excerptPendingByScope[scope] ?? []
            recoverInterruptedCommands(in: scope)
        }
        refreshPublishedRows()
    }

    func isCurrent(owner: String, generation: UInt64) -> Bool {
        writable && isBoundToLocalScope && !heldForAccountReview
            && activeScope?.ownerToken == owner && operationGeneration == generation
    }

    func isCurrent(scope: NotebookLocalScope, generation: UInt64) -> Bool {
        writable && isBoundToLocalScope && !heldForAccountReview
            && activeScope == scope && operationGeneration == generation
    }

    func entry(id: ItemID, includeDeleted: Bool = false) -> LibraryNotebookEntry? {
        guard isBoundToLocalScope, let scope = activeScope,
              let value = bucket(for: scope)?.records.first(where: { $0.id == id })?.entry,
              includeDeleted || !value.isDeleted else { return nil }
        return value
    }

    func storedVersion(for id: ItemID) -> UInt64 {
        guard let scope = activeScope else { return 0 }
        return bucket(for: scope)?.records.first(where: { $0.id == id })?.serverVersion ?? 0
    }

    func hasCommand(for id: ItemID, excludingTerminal: Bool = false) -> Bool {
        commands.contains { $0.entry.id == id && (!excludingTerminal || !$0.isTerminal) }
    }

    func setReplayable(_ replayable: Bool, for id: ItemID) {
        if replayable { replayableIDs.insert(id) } else { replayableIDs.remove(id) }
    }

    func clearReplayableIDs() { replayableIDs = [] }
    func replaceReplayableIDs(_ ids: Set<ItemID>) { replayableIDs = ids }
    func markJustCaptured(_ id: ItemID?) { lastCapturedEntryID = id }
    func markJustDeleted(_ id: ItemID?) { lastDeletedEntryID = id }
    func beginCapture() -> Bool {
        guard !isCaptureInProgress else { return false }
        isCaptureInProgress = true
        return true
    }
    func finishCapture() { isCaptureInProgress = false }

    func setExcerptPending(_ pending: Bool, for id: ItemID, in scope: NotebookLocalScope) {
        var ids = excerptPendingByScope[scope] ?? []
        if pending { ids.insert(id) } else { ids.remove(id) }
        excerptPendingByScope[scope] = ids
        if activeScope == scope { excerptPendingIDs = ids }
    }

    func beginExcerptCheck(for entry: LibraryNotebookEntry, now: Date) -> Bool {
        guard let scope = activeScope, !entry.isDeleted,
              !(excerptPendingByScope[scope] ?? []).contains(entry.id) else { return false }
        if let previous = excerptAttempts[scope]?[entry.id], previous.revision == entry.sourceRevision,
           now.timeIntervalSince(previous.at) < 60 { return false }
        excerptAttempts[scope, default: [:]][entry.id] = (entry.sourceRevision, now)
        setExcerptPending(true, for: entry.id, in: scope)
        return true
    }

    @discardableResult
    func store(
        _ entry: LibraryNotebookEntry,
        serverVersion: UInt64? = nil,
        command: LibraryNotebookOutbox.Command? = nil
    ) -> Bool {
        guard writable, isBoundToLocalScope, let scope = activeScope else { return false }
        var next = saved
        var bucket = mutableBucket(for: scope, in: &next)
        if let old = bucket.records.first(where: { $0.id == entry.id }), old.entry.isDeleted && !entry.isDeleted { return false }
        let priorVersion = bucket.records.first(where: { $0.id == entry.id })?.serverVersion ?? 0
        let version = serverVersion ?? priorVersion
        if let index = bucket.records.firstIndex(where: { $0.id == entry.id }) {
            bucket.records[index] = .init(entry: entry, serverVersion: version)
        } else {
            guard bucket.records.count < LibraryNotebookOutbox.maximumEntries else { notice = "Notebook is full on this phone."; return false }
            bucket.records.append(.init(entry: entry, serverVersion: version))
        }
        if let command {
            guard command.scope == scope, command.entry == entry, LibraryNotebookOutbox.isValidCommand(command) else {
                notice = "This Notebook change could not be queued safely. Try again."
                return false
            }
            if let index = bucket.commands.firstIndex(where: { $0.entry.id == entry.id }) {
                let prior = bucket.commands[index]
                guard prior.id == command.id && prior.delivery == .pending || prior.isTerminal else {
                    notice = "This Notebook entry is already syncing. Try again after it finishes."
                    return false
                }
                bucket.commands[index] = command
            } else {
                guard bucket.commands.count < LibraryNotebookOutbox.maximumCommands else {
                    notice = "Too many Notebook changes are waiting to sync."
                    return false
                }
                bucket.commands.append(command)
            }
        }
        replace(bucket, in: &next)
        return commit(next)
    }

    @discardableResult
    func enqueue(_ command: LibraryNotebookOutbox.Command) -> Bool {
        guard writable, isBoundToLocalScope, activeScope == command.scope,
              LibraryNotebookOutbox.isValidCommand(command), !hasCommand(for: command.entry.id) else { return false }
        var next = saved
        var bucket = mutableBucket(for: command.scope, in: &next)
        guard bucket.records.contains(where: { $0.id == command.entry.id }) else { return false }
        guard bucket.commands.count < LibraryNotebookOutbox.maximumCommands else { notice = "Too many Notebook changes are waiting to sync."; return false }
        bucket.commands.append(command)
        replace(bucket, in: &next)
        return commit(next)
    }

    @discardableResult
    func update(_ command: LibraryNotebookOutbox.Command) -> Bool {
        guard writable else { return false }
        var next = saved
        guard var bucket = next.scopes.first(where: { $0.scope == command.scope }),
              let index = bucket.commands.firstIndex(where: { $0.id == command.id }) else { return false }
        bucket.commands[index] = command
        replace(bucket, in: &next)
        return commit(next)
    }

    @discardableResult
    func removeCommand(id: String, scope: NotebookLocalScope? = nil) -> Bool {
        guard writable else { return false }
        var next = saved
        guard let active = scope ?? activeScope,
              var bucket = next.scopes.first(where: { $0.scope == active }),
              bucket.commands.contains(where: { $0.id == id }) else { return false }
        bucket.commands.removeAll { $0.id == id }
        replace(bucket, in: &next)
        return commit(next)
    }

    @discardableResult
    func replaceTerminalCommand(
        oldID: String, with command: LibraryNotebookOutbox.Command,
        entry: LibraryNotebookEntry, serverVersion: UInt64
    ) -> Bool {
        guard writable, isBoundToLocalScope, let scope = activeScope, command.scope == scope,
              command.entry == entry, LibraryNotebookOutbox.isValidCommand(command) else { return false }
        var next = saved
        guard var bucket = next.scopes.first(where: { $0.scope == scope }),
              let oldIndex = bucket.commands.firstIndex(where: { $0.id == oldID && $0.isTerminal }),
              let oldRecordIndex = bucket.records.firstIndex(where: { $0.id == bucket.commands[oldIndex].entry.id }) else { return false }
        if bucket.commands[oldIndex].entry.id == entry.id {
            guard !bucket.records[oldRecordIndex].entry.isDeleted || entry.isDeleted else { return false }
            bucket.records[oldRecordIndex] = .init(entry: entry, serverVersion: serverVersion)
            bucket.commands[oldIndex] = command
        } else {
            guard !bucket.records.contains(where: { $0.id == entry.id }),
                  bucket.records.count < LibraryNotebookOutbox.maximumEntries else { return false }
            bucket.commands.remove(at: oldIndex)
            bucket.records.append(.init(entry: entry, serverVersion: serverVersion))
            bucket.commands.append(command)
        }
        replace(bucket, in: &next)
        return commit(next)
    }

    /// Merges the current account's server snapshot without replacing a pending local mutation.
    func mergeRemote(_ remote: [ItemID: LibraryNotebookEntry], versions: [LibraryRecordKey: UInt64], generation: UInt64) {
        guard let scope = activeScope, isCurrent(scope: scope, generation: generation) else { return }
        var next = saved
        var bucket = mutableBucket(for: scope, in: &next)
        let commandIDs = Set(bucket.commands.map { $0.entry.id })
        for (id, entry) in remote {
            let version = versions[LibraryRecordKey(kind: .notebookEntry, id: id)] ?? 0
            if commandIDs.contains(id), let commandIndex = bucket.commands.firstIndex(where: { $0.entry.id == id }) {
                let command = bucket.commands[commandIndex]
                let recordIndex = bucket.records.firstIndex(where: { $0.id == id })
                if entry == command.entry {
                    if let recordIndex, bucket.records[recordIndex].entry != command.entry,
                       bucket.records[recordIndex].entry.updatedAt > command.entry.updatedAt {
                        bucket.records[recordIndex].serverVersion = version
                    } else if let recordIndex {
                        bucket.records[recordIndex] = .init(entry: entry, serverVersion: version)
                    }
                    else { bucket.records.append(.init(entry: entry, serverVersion: version)) }
                } else if version != command.baseVersion {
                    bucket.commands[commandIndex].delivery = .conflict
                    bucket.commands[commandIndex].serverEntry = entry
                    bucket.commands[commandIndex].detail = "This entry changed on your Mac. Review the Mac version before reapplying your edit."
                    if let recordIndex { bucket.records[recordIndex] = .init(entry: entry, serverVersion: version) }
                    else { bucket.records.append(.init(entry: entry, serverVersion: version)) }
                } else if let recordIndex {
                    // The server has not changed; keep the local draft while its durable command settles.
                    bucket.records[recordIndex].serverVersion = version
                }
                continue
            }
            if let index = bucket.records.firstIndex(where: { $0.id == id }) {
                if bucket.records[index].entry.isDeleted && !entry.isDeleted { continue }
                bucket.records[index] = .init(entry: entry, serverVersion: version)
            } else {
                bucket.records.append(.init(entry: entry, serverVersion: version))
            }
        }
        replace(bucket, in: &next)
        _ = commit(next)
    }

    func refreshPublishedRows() {
        guard isBoundToLocalScope, let scope = activeScope,
              let bucket = bucket(for: scope) else { entries = []; commands = []; return }
        entries = bucket.records.map(\.entry).filter { !$0.isDeleted }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.rawValue < $1.id.rawValue
        }
        commands = bucket.commands.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    private func bucket(for scope: NotebookLocalScope) -> LibraryNotebookOutbox.ScopeState? {
        saved.scopes.first { $0.scope == scope }
    }

    private func mutableBucket(for scope: NotebookLocalScope, in value: inout LibraryNotebookOutbox.Saved) -> LibraryNotebookOutbox.ScopeState {
        if let existing = value.scopes.first(where: { $0.scope == scope }) { return existing }
        return .init(scope: scope, records: [], commands: [])
    }

    private func replace(_ bucket: LibraryNotebookOutbox.ScopeState, in value: inout LibraryNotebookOutbox.Saved) {
        if let index = value.scopes.firstIndex(where: { $0.scope == bucket.scope }) { value.scopes[index] = bucket }
        else { value.scopes.append(bucket) }
    }

    /// A `sent` row survives process termination. Reuse its stable intent ID after a new
    /// account/generation bind so an interrupted send can settle idempotently.
    private func recoverInterruptedCommands(in scope: NotebookLocalScope) {
        var next = saved
        guard var bucket = next.scopes.first(where: { $0.scope == scope }) else { return }
        var changed = false
        for index in bucket.commands.indices where bucket.commands[index].delivery == .sent {
            bucket.commands[index].delivery = .pending
            bucket.commands[index].detail = "Waiting to sync"
            changed = true
        }
        guard changed else { return }
        replace(bucket, in: &next)
        _ = commit(next)
    }

    @discardableResult
    private func commit(_ value: LibraryNotebookOutbox.Saved) -> Bool {
        guard writable else { writeFailed = true; return false }
        do {
            try outbox.save(value)
            saved = value
            writeFailed = false
            notice = nil
            refreshPublishedRows()
            return true
        } catch {
            writeFailed = true
            notice = error as? LibraryNotebookOutbox.WriteError == .full
                ? "Notebook storage is full on this phone. Remove old entries before saving more."
                : "Notebook could not save this change on the phone. Try again."
            return false
        }
    }
}

extension LibraryNotebookOutbox {
    fileprivate static func isValidCommand(_ command: Command) -> Bool {
        !command.id.isEmpty && command.id.count <= 256
            && command.createdAt.timeIntervalSince1970.isFinite
            && (command.detail?.utf8.count ?? 0) <= 4_096
    }
}
