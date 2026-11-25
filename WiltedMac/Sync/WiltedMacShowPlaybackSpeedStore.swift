import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

enum WiltedMacShowPlaybackSpeedApplyResult: Equatable {
    case applied(LibraryShowPlaybackSpeed)
    case conflict(LibraryShowPlaybackSpeed)
}

private struct WiltedMacShowPlaybackSpeedEnvelope: Codable {
    struct Receipt: Codable {
        let commandID: String
        let result: WiltedMacShowPlaybackSpeedApplyResult
        let appliedAt: Date
    }

    var schemaVersion = 1
    let ownerToken: String
    var speeds: [String: LibraryShowPlaybackSpeed]
    var receipts: [String: Receipt]

    func validate(owner: String) throws {
        guard schemaVersion == 1, ownerToken == owner, !owner.isEmpty,
              speeds.allSatisfy({ $0.key == $0.value.feedID.rawValue }),
              receipts.allSatisfy({ !$0.key.isEmpty && $0.value.commandID == $0.key }) else {
            throw LibraryTransportError.transport("show playback speed state is invalid")
        }
    }
}

extension WiltedMacShowPlaybackSpeedApplyResult: Codable {
    private enum CodingKeys: String, CodingKey { case kind, speed }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let speed = try values.decode(LibraryShowPlaybackSpeed.self, forKey: .speed)
        switch try values.decode(String.self, forKey: .kind) {
        case "applied": self = .applied(speed)
        case "conflict": self = .conflict(speed)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values, debugDescription: "Unknown show playback speed result")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .applied(speed):
            try values.encode("applied", forKey: .kind)
            try values.encode(speed, forKey: .speed)
        case let .conflict(speed):
            try values.encode("conflict", forKey: .kind)
            try values.encode(speed, forKey: .speed)
        }
    }
}

/// Mac-authoritative per-show rates and intent receipts, isolated from offset state.
actor WiltedMacShowPlaybackSpeedStore {
    static let maximumReceipts = 512
    private let loadBytes: @Sendable (String) async throws -> Data?
    private let saveBytes: @Sendable (String, Data) async throws -> Void
    private let now: @Sendable () -> Date

    init(
        loadBytes: @escaping @Sendable (String) async throws -> Data?,
        saveBytes: @escaping @Sendable (String, Data) async throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loadBytes = loadBytes
        self.saveBytes = saveBytes
        self.now = now
    }

    init(store: LocalLibraryStore) {
        loadBytes = { owner in try await store.syncState(for: owner)?.engineState }
        saveBytes = { key, data in try await store.save(syncState: LocalLibrarySyncState(key: key, engineState: data)) }
        now = { Date() }
    }

    static func key(for owner: String) -> String { "library-show-playback-speeds:\(owner)" }

    func speeds(owner: String) async throws -> [String: LibraryShowPlaybackSpeed] {
        try await load(owner: owner).speeds
    }

    func apply(
        commandID: String, owner: String, feedID: ItemID, speed: Double?, basedOnRevision: Int64
    ) async throws -> WiltedMacShowPlaybackSpeedApplyResult {
        guard !commandID.isEmpty, basedOnRevision >= 0,
              speed.map(PlaybackSpeeds.contains) ?? true else {
            throw LibraryTransportError.transport("show playback speed command is invalid")
        }
        var envelope = try await load(owner: owner)
        if let previous = envelope.receipts[commandID] { return previous.result }
        let current = try envelope.speeds[feedID.rawValue]
            ?? LibraryShowPlaybackSpeed(feedID: feedID, speed: nil, revision: 0)
        let result: WiltedMacShowPlaybackSpeedApplyResult
        if current.revision == basedOnRevision {
            guard current.revision < Int64.max else {
                throw LibraryTransportError.transport("show playback speed revision is exhausted")
            }
            let updated = try LibraryShowPlaybackSpeed(feedID: feedID, speed: speed, revision: current.revision + 1)
            envelope.speeds[feedID.rawValue] = updated
            result = .applied(updated)
        } else {
            result = .conflict(current)
        }
        envelope.receipts[commandID] = .init(commandID: commandID, result: result, appliedAt: now())
        if envelope.receipts.count > Self.maximumReceipts {
            let oldest = envelope.receipts.values.sorted { $0.appliedAt < $1.appliedAt }
                .prefix(envelope.receipts.count - Self.maximumReceipts).map(\.commandID)
            for id in oldest { envelope.receipts.removeValue(forKey: id) }
        }
        try await save(envelope)
        return result
    }

    private func load(owner: String) async throws -> WiltedMacShowPlaybackSpeedEnvelope {
        guard !owner.isEmpty else { throw WiltedMacLibraryAccountError.notApproved }
        guard let data = try await loadBytes(Self.key(for: owner)) else {
            return WiltedMacShowPlaybackSpeedEnvelope(ownerToken: owner, speeds: [:], receipts: [:])
        }
        let envelope = try JSONDecoder().decode(WiltedMacShowPlaybackSpeedEnvelope.self, from: data)
        try envelope.validate(owner: owner)
        return envelope
    }

    private func save(_ envelope: WiltedMacShowPlaybackSpeedEnvelope) async throws {
        try envelope.validate(owner: envelope.ownerToken)
        try await saveBytes(Self.key(for: envelope.ownerToken), JSONEncoder().encode(envelope))
    }
}
