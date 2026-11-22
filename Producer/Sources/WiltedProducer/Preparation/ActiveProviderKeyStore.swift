import Foundation

private final class InMemorySlotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [AdLabellerProvider: InMemoryLabellerKeyStore] = [:]

    init(initialKeys: [AdLabellerProvider: String]) {
        for (provider, key) in initialKeys {
            stores[provider] = InMemoryLabellerKeyStore(key: key, provider: provider)
        }
    }

    func slot(for provider: AdLabellerProvider) -> InMemoryLabellerKeyStore {
        lock.withLock {
            if let existing = stores[provider] {
                return existing
            }
            let created = InMemoryLabellerKeyStore(provider: provider)
            stores[provider] = created
            return created
        }
    }
}

/// A key store that routes key operations to the slot of whichever provider is currently
/// chosen in `AdLabellerPreferences`.
///
/// `hasKey()` returns `true` when the chosen provider needs no saved key (command-line providers)
/// or when its own slot holds a key. `read()`, `save(_:)`, and `remove()` always act on
/// the chosen provider's slot.
public struct ActiveProviderKeyStore: LabellerKeyStoring, @unchecked Sendable {
    public let preferences: AdLabellerPreferences
    private let slotResolver: @Sendable (AdLabellerProvider) -> any LabellerKeyStoring

    public init(
        preferences: AdLabellerPreferences,
        slotResolver: (@Sendable (AdLabellerProvider) -> any LabellerKeyStoring)? = nil
    ) {
        self.preferences = preferences
        self.slotResolver = slotResolver ?? { KeychainLabellerKeyStore(provider: $0) }
    }

    /// Resolves the key store slot for a specific provider.
    public func slot(for provider: AdLabellerProvider) -> any LabellerKeyStoring {
        slotResolver(provider)
    }

    /// Resolves the key store slot for the currently active provider.
    public func currentSlot() -> any LabellerKeyStoring {
        slot(for: preferences.provider)
    }

    public func save(_ key: String) throws {
        try currentSlot().save(key)
    }

    public func read() throws -> String? {
        try currentSlot().read()
    }

    public func remove() throws {
        try currentSlot().remove()
    }

    /// Returns `true` when the chosen provider is ready to send.
    public func hasKey() -> Bool {
        isReady(provider: preferences.provider)
    }

    /// Readiness requires a valid model and level, plus a saved key for key providers.
    public func isReady(provider: AdLabellerProvider) -> Bool {
        guard AdLabellerModelCatalog.isValid(
            provider: provider,
            model: preferences.modelID(for: provider),
            level: preferences.level(for: provider)
        ) else { return false }
        guard provider.requiresSavedKey else { return true }
        return slot(for: provider).hasKey()
    }

    /// Whether a saved key is present in the chosen provider's slot.
    public func savedKeyPresent() -> Bool {
        currentSlot().hasKey()
    }

    /// Whether a saved key is present for `targetProvider`.
    public func savedKeyPresent(for targetProvider: AdLabellerProvider) -> Bool {
        slot(for: targetProvider).hasKey()
    }

    /// Creates an active key store backed by in-memory slots per provider (for tests and fixture mode).
    public static func inMemory(
        preferences: AdLabellerPreferences,
        initialKeys: [AdLabellerProvider: String] = [:]
    ) -> ActiveProviderKeyStore {
        let box = InMemorySlotBox(initialKeys: initialKeys)
        return ActiveProviderKeyStore(preferences: preferences) { provider in
            box.slot(for: provider)
        }
    }

    /// Convenience initializer with preloaded in-memory keys.
    public init(
        preferences: AdLabellerPreferences,
        inMemoryKeys: [AdLabellerProvider: String]
    ) {
        self = .inMemory(preferences: preferences, initialKeys: inMemoryKeys)
    }

    /// Convenience initializer for in-memory or Keychain-backed storage.
    public init(
        preferences: AdLabellerPreferences,
        inMemory: Bool
    ) {
        if inMemory {
            self = .inMemory(preferences: preferences)
        } else {
            self.init(preferences: preferences, slotResolver: nil)
        }
    }
}
