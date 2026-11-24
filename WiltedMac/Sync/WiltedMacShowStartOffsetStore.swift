import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

enum WiltedMacShowStartOffsetApplyResult: Equatable {
    case applied(LibraryShowStartOffset)
    case conflict(LibraryShowStartOffset)
}

private struct WiltedMacShowStartOffsetEnvelope: Codable {
    struct Receipt: Codable {
        let commandID: String
        let result: WiltedMacShowStartOffsetApplyResult
        let appliedAt: Date
    }

    var schemaVersion = 1
    let ownerToken: String
    var offsets: [String: LibraryShowStartOffset]
    var receipts: [String: Receipt]

    func validate(owner: String) throws {
        guard schemaVersion == 1, ownerToken == owner, !owner.isEmpty,
              offsets.allSatisfy({ $0.key == $0.value.feedID.rawValue }),
              receipts.allSatisfy({ !$0.key.isEmpty && $0.value.commandID == $0.key }) else {
            throw LibraryTransportError.transport("show start offset state is invalid")
        }
    }
}

extension WiltedMacShowStartOffsetApplyResult: Codable {
    private enum CodingKeys: String, CodingKey { case kind, offset }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let offset = try values.decode(LibraryShowStartOffset.self, forKey: .offset)
        switch try values.decode(String.self, forKey: .kind) {
        case "applied": self = .applied(offset)
        case "conflict": self = .conflict(offset)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: values, debugDescription: "Unknown show start offset result")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .applied(offset):
            try values.encode("applied", forKey: .kind)
            try values.encode(offset, forKey: .offset)
        case let .conflict(offset):
            try values.encode("conflict", forKey: .kind)
            try values.encode(offset, forKey: .offset)
        }
    }
}

/// Mac-authoritative offsets and intent receipts in the existing account-scoped sync-state store.
actor WiltedMacShowStartOffsetStore {
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
        self.loadBytes = { owner in try await store.syncState(for: owner)?.engineState }
        self.saveBytes = { key, data in
            try await store.save(syncState: LocalLibrarySyncState(key: key, engineState: data))
        }
        self.now = { Date() }
    }

    static func key(for owner: String) -> String { "library-show-start-offsets:\(owner)" }

    func offsets(owner: String) async throws -> [String: LibraryShowStartOffset] {
        try await load(owner: owner).offsets
    }

    /// State and command receipt are saved together, so replay after a crash returns the same result.
    func apply(
        commandID: String, owner: String, feedID: ItemID, seconds: Double, basedOnRevision: Int64
    ) async throws -> WiltedMacShowStartOffsetApplyResult {
        guard !commandID.isEmpty, basedOnRevision >= 0,
              seconds.isFinite, (0...LibraryShowStartOffset.maximumSeconds).contains(seconds) else {
            throw LibraryTransportError.transport("show start offset command is invalid")
        }
        var envelope = try await load(owner: owner)
        if let previous = envelope.receipts[commandID] { return previous.result }
        let current = try envelope.offsets[feedID.rawValue]
            ?? LibraryShowStartOffset(feedID: feedID, seconds: 0, revision: 0)
        let result: WiltedMacShowStartOffsetApplyResult
        if current.revision == basedOnRevision {
            guard current.revision < Int64.max else {
                throw LibraryTransportError.transport("show start offset revision is exhausted")
            }
            let updated = try LibraryShowStartOffset(
                feedID: feedID, seconds: seconds, revision: current.revision + 1)
            envelope.offsets[feedID.rawValue] = updated
            result = .applied(updated)
        } else {
            result = .conflict(current)
        }
        envelope.receipts[commandID] = .init(commandID: commandID, result: result, appliedAt: now())
        if envelope.receipts.count > Self.maximumReceipts {
            let oldest = envelope.receipts.values.sorted { $0.appliedAt < $1.appliedAt }
                .prefix(envelope.receipts.count - Self.maximumReceipts)
                .map(\.commandID)
            for id in oldest { envelope.receipts.removeValue(forKey: id) }
        }
        try await save(envelope)
        return result
    }

    private func load(owner: String) async throws -> WiltedMacShowStartOffsetEnvelope {
        guard !owner.isEmpty else { throw WiltedMacLibraryAccountError.notApproved }
        guard let data = try await loadBytes(Self.key(for: owner)) else {
            return WiltedMacShowStartOffsetEnvelope(ownerToken: owner, offsets: [:], receipts: [:])
        }
        let envelope = try JSONDecoder().decode(WiltedMacShowStartOffsetEnvelope.self, from: data)
        try envelope.validate(owner: owner)
        return envelope
    }

    private func save(_ envelope: WiltedMacShowStartOffsetEnvelope) async throws {
        try envelope.validate(owner: envelope.ownerToken)
        try await saveBytes(Self.key(for: envelope.ownerToken), JSONEncoder().encode(envelope))
    }
}
