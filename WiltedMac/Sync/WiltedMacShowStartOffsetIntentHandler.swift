import Foundation
import WiltedDomain
import WiltedLibrary

/// Applies the revisioned offset intent outside the generic decision ledger.
/// The offset store writes its idempotency receipt in the same sync-state save.
actor WiltedMacShowStartOffsetIntentHandler {
    static let conflictReason = LibraryShowStartOffset.conflictReason

    private let store: WiltedMacShowStartOffsetStore
    private let transport: any LibraryTransport
    private let ownerProvider: @Sendable () async -> String?
    private let feedValidator: @Sendable (ItemID) async throws -> Bool
    private let now: @Sendable () -> Date
    private let onApplied: @Sendable () async -> Void

    init(
        store: WiltedMacShowStartOffsetStore,
        transport: any LibraryTransport,
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

    /// Returns false for every other action so the regular sink can route it.
    func applyIfOffset(_ intent: LibraryIntent) async throws -> Bool {
        guard case let .setShowStartOffset(feedID, seconds, basedOnRevision) = intent.action else { return false }
        let generation = await transport.operationGeneration()
        guard let owner = await ownerProvider(), !owner.isEmpty else {
            throw WiltedMacLibraryAccountError.notApproved
        }
        guard await transport.operationGeneration() == generation,
              await ownerProvider() == owner else { throw LibraryTransportError.superseded }
        guard try await feedValidator(feedID) else {
            guard await transport.operationGeneration() == generation,
                  await ownerProvider() == owner else { throw LibraryTransportError.superseded }
            let rejected = try IntentOutcome.rejected(for: intent, reason: IntentOutcome.reasonNotApplicable, at: now())
            try await transport.publishIntentOutcome(rejected)
            return true
        }
        guard await transport.operationGeneration() == generation,
              await ownerProvider() == owner else { throw LibraryTransportError.superseded }
        let result = try await store.apply(
            commandID: intent.id, owner: owner, feedID: feedID,
            seconds: seconds, basedOnRevision: basedOnRevision)
        guard await transport.operationGeneration() == generation,
              await ownerProvider() == owner else { throw LibraryTransportError.superseded }
        let outcome: IntentOutcome
        switch result {
        case .applied:
            outcome = try .applied(for: intent, at: now())
            await onApplied()
        case .conflict:
            outcome = try .rejected(for: intent, reason: Self.conflictReason, at: now())
        }
        try await transport.publishIntentOutcome(outcome)
        guard await transport.operationGeneration() == generation,
              await ownerProvider() == owner else { throw LibraryTransportError.superseded }
        return true
    }
}
