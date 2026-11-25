import Foundation
import WiltedDomain
import WiltedLibrary

/// Applies revisioned show-rate intents and publishes an idempotent outcome.
actor WiltedMacShowPlaybackSpeedIntentHandler {
    static let conflictReason = "showPlaybackSpeedConflict"
    private let store: WiltedMacShowPlaybackSpeedStore
    private let transport: any LibraryTransport
    private let ownerProvider: @Sendable () async -> String?
    private let feedValidator: @Sendable (ItemID) async throws -> Bool
    private let now: @Sendable () -> Date
    private let onApplied: @Sendable () async -> Void

    init(
        store: WiltedMacShowPlaybackSpeedStore, transport: any LibraryTransport,
        ownerProvider: @escaping @Sendable () async -> String?,
        feedValidator: @escaping @Sendable (ItemID) async throws -> Bool = { _ in true },
        now: @escaping @Sendable () -> Date = { Date() },
        onApplied: @escaping @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.transport = transport
        self.ownerProvider = ownerProvider
        self.feedValidator = feedValidator
        self.now = now
        self.onApplied = onApplied
    }

    func applyIfShowPlaybackSpeed(_ intent: LibraryIntent) async throws -> Bool {
        guard case let .setShowPlaybackSpeed(feedID, speed, basedOnRevision) = intent.action else { return false }
        let generation = await transport.operationGeneration()
        guard let owner = await ownerProvider(), !owner.isEmpty else { throw WiltedMacLibraryAccountError.notApproved }
        guard await transport.operationGeneration() == generation, await ownerProvider() == owner else {
            throw LibraryTransportError.superseded
        }
        guard try await feedValidator(feedID) else {
            try await transport.publishIntentOutcome(.rejected(for: intent, reason: IntentOutcome.reasonNotApplicable, at: now()))
            return true
        }
        let result = try await store.apply(
            commandID: intent.id, owner: owner, feedID: feedID, speed: speed, basedOnRevision: basedOnRevision)
        guard await transport.operationGeneration() == generation, await ownerProvider() == owner else {
            throw LibraryTransportError.superseded
        }
        let outcome: IntentOutcome
        switch result {
        case .applied:
            outcome = try .applied(for: intent, at: now())
            await onApplied()
        case .conflict:
            outcome = try .rejected(for: intent, reason: Self.conflictReason, at: now())
        }
        try await transport.publishIntentOutcome(outcome)
        guard await transport.operationGeneration() == generation, await ownerProvider() == owner else {
            throw LibraryTransportError.superseded
        }
        return true
    }
}
