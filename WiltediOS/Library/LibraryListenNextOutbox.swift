import Foundation
import WiltedLibrary

/// One phone-local Listen next command. Kept outside LibraryIntentOutbox so an old phone can still
/// decode and preserve its existing keep, skip, and add decisions.
struct LibraryListenNextPhoneEntry: Codable, Equatable, Sendable, Identifiable {
    var snapshot: LibraryListenNextRequestSnapshot
    var requestIntent: LibraryIntent?
    var cancellationIntent: LibraryIntent?
    var requestAttempted: Bool = false
    var requestSent: Bool
    var audioCached: Bool
    var remoteStatusRevision: UInt64

    var id: String { snapshot.requestID }
}

extension LibraryListenNextPhoneEntry {
    private enum CodingKeys: String, CodingKey {
        case snapshot, requestIntent, cancellationIntent, requestAttempted, requestSent, audioCached, remoteStatusRevision
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let requestIntent = try values.decodeIfPresent(LibraryIntent.self, forKey: .requestIntent)
        let cancellationIntent = try values.decodeIfPresent(LibraryIntent.self, forKey: .cancellationIntent)
        let requestSent = try values.decode(Bool.self, forKey: .requestSent)
        self.init(
            snapshot: try values.decode(LibraryListenNextRequestSnapshot.self, forKey: .snapshot),
            requestIntent: requestIntent,
            cancellationIntent: cancellationIntent,
            requestAttempted: try values.decodeIfPresent(Bool.self, forKey: .requestAttempted)
                ?? (requestSent || requestIntent != nil || cancellationIntent != nil),
            requestSent: requestSent,
            audioCached: try values.decode(Bool.self, forKey: .audioCached),
            remoteStatusRevision: try values.decodeIfPresent(UInt64.self, forKey: .remoteStatusRevision) ?? 0
        )
    }
}

struct LibraryListenNextPhoneOutbox: Sendable {
    static let version = 1

    struct Saved: Codable, Equatable, Sendable {
        let version: Int
        var ownerToken: String?
        var entries: [LibraryListenNextPhoneEntry]
    }

    enum LoadResult {
        case empty
        case saved(Saved)
        case unreadable
    }

    let url: URL?

    init(url: URL?) { self.url = url }

    func load(fileManager: FileManager = .default) -> LoadResult {
        guard let url else { return .empty }
        guard fileManager.fileExists(atPath: url.path) else { return .empty }
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == Self.version,
              Self.isValid(saved) else {
            return .unreadable
        }
        return .saved(saved)
    }

    func save(_ saved: Saved, fileManager: FileManager = .default) throws {
        guard let url else { return }
        guard Self.isValid(saved) else { throw LibraryListenNextError.notDurable }
        let data = try JSONEncoder().encode(saved)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
    }

    private static func isValid(_ saved: Saved) -> Bool {
        guard Set(saved.entries.map(\.id)).count == saved.entries.count else { return false }
        for entry in saved.entries {
            guard let owner = saved.ownerToken, !owner.isEmpty,
                  entry.snapshot.ownerToken == owner, !entry.snapshot.requesterDeviceID.isEmpty,
                  !entry.requestSent || entry.requestAttempted,
                  !entry.requestSent || entry.requestIntent == nil,
                  entry.snapshot.status != .sent || entry.requestSent,
                  entry.cancellationIntent == nil || entry.requestAttempted || entry.requestSent else { return false }
            if let intent = entry.requestIntent {
                guard intent.id == entry.snapshot.requestID,
                      intent.deviceID == entry.snapshot.requesterDeviceID,
                      intent.createdAt == entry.snapshot.createdAt,
                      case let .listenNext(story, anchor) = intent.action,
                      story == entry.snapshot.story, anchor == entry.snapshot.anchorID else { return false }
            }
            if let intent = entry.cancellationIntent {
                guard intent.deviceID == entry.snapshot.requesterDeviceID,
                      case let .cancelListenNext(requestID) = intent.action,
                      requestID == entry.snapshot.requestID else { return false }
            }
        }
        return true
    }
}

@MainActor
final class LibraryListenNextPhoneState {
    let outbox: LibraryListenNextPhoneOutbox
    let audioCache: LibraryListenNextAudioCache
    var entries: [LibraryListenNextPhoneEntry] = []
    var ownerToken: String?
    var writable = true
    var heldForAccountReview = false
    var isRestored = false
    var requestingStoryIDs: Set<String> = []
    var inFlightRequests: Set<String> = []
    var downloadingRequests: Set<String> = []
    var downloadTasks: [String: Task<Void, Never>] = [:]
    var downloadRunIDs: [String: UUID] = [:]

    init(outbox: LibraryListenNextPhoneOutbox) {
        self.outbox = outbox
        self.audioCache = LibraryListenNextAudioCache(outboxURL: outbox.url)
    }

    func persist() throws {
        guard writable else { throw LibraryListenNextError.notDurable }
        guard outbox.url != nil else { throw LibraryListenNextError.notDurable }
        try outbox.save(.init(version: LibraryListenNextPhoneOutbox.version, ownerToken: ownerToken, entries: entries))
    }
}

enum LibraryListenNextError: Error, Equatable {
    case unavailable
    case notDurable
    case unsupportedMac
    case unsafeLink
    case missingRequest
}
