import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

/// Durable account-scoped author evidence and the captured obligation that must be retried.
/// The date is absent until every captured mutation and its sent token are acknowledged.
struct WiltedMacLibraryPublicationPending: Codable, Equatable, Sendable {
    var id: String
    var writerDeviceID: String
    var captured: [LibraryChange]
    var remaining: [LibraryChange]
    var contentAcknowledged = false
    var sentToken: LibraryChangeToken?
    var publishedAt: Date?

    func receipt() throws -> LibraryPublication? {
        guard let publishedAt else { return nil }
        return try LibraryPublication(id: id, publishedAt: publishedAt, writerDeviceID: writerDeviceID)
    }
}

struct WiltedMacLibraryPublicationEnvelope: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var ownerToken: String
    var pending: WiltedMacLibraryPublicationPending?
    var fulfilled: LibraryPublication?

    func validate(for owner: String) throws {
        guard schemaVersion == 1, !owner.isEmpty, ownerToken == owner else {
            throw LibraryTransportError.transport("publication sidecar has an unsupported owner or schema")
        }
        if let pending {
            guard !pending.id.isEmpty, !pending.writerDeviceID.isEmpty,
                  !pending.captured.isEmpty,
                  Set(pending.captured.map(\.key)).count == pending.captured.count,
                  Set(pending.remaining.map(\.key)).count == pending.remaining.count,
                  pending.remaining.allSatisfy({ pending.captured.contains($0) }),
                  pending.contentAcknowledged || !pending.remaining.isEmpty,
                  !pending.contentAcknowledged || pending.remaining.isEmpty,
                  pending.publishedAt == nil || pending.contentAcknowledged else {
                throw LibraryTransportError.transport("publication sidecar contains an invalid obligation")
            }
            _ = try pending.receipt()
        }
    }
}

/// Uses the existing opaque Producer sync-state sidecar, keeping historical accounts separate.
/// Persistence failures propagate; remote receipt acknowledgement alone is never local success.
struct WiltedMacLibraryPublicationStore: Sendable {
    var loadBytes: @Sendable (String) async throws -> Data?
    var saveBytes: @Sendable (String, Data) async throws -> Void

    static func key(for owner: String) -> String { "library-author-publication:\(owner)" }

    static func store(_ store: LocalLibraryStore) -> Self {
        Self(loadBytes: { try await store.syncState(for: $0)?.engineState },
             saveBytes: { try await store.save(syncState: LocalLibrarySyncState(key: $0, engineState: $1)) })
    }

    func load(owner: String) async throws -> WiltedMacLibraryPublicationEnvelope {
        guard !owner.isEmpty else { throw WiltedMacLibraryAccountError.notApproved }
        guard let bytes = try await loadBytes(Self.key(for: owner)) else {
            return WiltedMacLibraryPublicationEnvelope(ownerToken: owner)
        }
        let envelope = try JSONDecoder().decode(WiltedMacLibraryPublicationEnvelope.self, from: bytes)
        try envelope.validate(for: owner)
        return envelope
    }

    /// Display-only read of the last-approved owner. Revalidates the binding after the sidecar awaits.
    func displayPublication(binding: LocalLibraryAccountBinding,
        currentBinding: @Sendable () async throws -> LocalLibraryAccountBinding?) async throws -> LibraryPublication? {
        guard let owner = binding.ownerToken, [.bound, .quarantined].contains(binding.state) else { return nil }
        let value = try await load(owner: owner).fulfilled
        guard try await currentBinding() == binding else { throw LibraryTransportError.superseded }
        return value
    }

    func save(_ envelope: WiltedMacLibraryPublicationEnvelope) async throws {
        try envelope.validate(for: envelope.ownerToken)
        try await saveBytes(Self.key(for: envelope.ownerToken), JSONEncoder().encode(envelope))
    }
}

extension WiltedMacModel {
    /// Last durable author evidence for the currently approved account, including offline reads.
    /// Later status surfaces may display this date without treating it as mirror equality.
    /// Hydrates saved author evidence without opening the account gate or making a transport call.
    func hydrateSavedLibraryPublication() async {
        guard let store, let controller = librarySyncController, let account = controller.account else { return }
        do {
            guard let binding = try await store.libraryAccountBinding() else { return }
            let value = try await WiltedMacLibraryPublicationStore.store(store).displayPublication(binding: binding,
                currentBinding: { try await store.libraryAccountBinding() })
            guard !Task.isCancelled, !isClosingTemporaryState, librarySyncController === controller,
                  controller.account === account, try await store.libraryAccountBinding() == binding else { return }
            librarySyncActivity.publication = value
            librarySyncActivity.publicationOwner = binding.ownerToken
        } catch { /* Missing/corrupt/superseded author evidence stays unknown; cached library remains. */ }
    }

    func fulfilledLibraryPublication() async throws -> LibraryPublication? {
        try await librarySyncController?.publisher.fulfilledPublication()
    }
}
