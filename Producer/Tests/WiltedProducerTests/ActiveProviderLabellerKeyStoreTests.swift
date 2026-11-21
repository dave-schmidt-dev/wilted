import Foundation
import Testing
@testable import WiltedProducer

@Suite("Labeller active provider key store")
struct ActiveProviderLabellerKeyStoreTests {
    private func makePreferences() -> (UserDefaults, AdLabellerPreferences) {
        let suite = "test-active-keystore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, AdLabellerPreferences(preferences: defaults))
    }

    @Test func truthTableAcrossProvidersWithInMemorySlots() throws {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        // Start with empty in-memory slots
        let keyStore = ActiveProviderKeyStore.inMemory(preferences: preferences)

        for provider in AdLabellerProvider.allCases {
            preferences.provider = provider

            if provider.requiresSavedKey {
                // Key-based provider with no saved key
                #expect(!keyStore.hasKey(), "\(provider) should have no key initially")
                #expect(!keyStore.savedKeyPresent(), "\(provider) should report no saved key initially")
                #expect(try keyStore.read() == nil)

                // Save a key for this provider
                try keyStore.save("key-for-\(provider.rawValue)")
                #expect(keyStore.hasKey(), "\(provider) should have key after saving")
                #expect(keyStore.savedKeyPresent(), "\(provider) should report saved key after saving")
                #expect(try keyStore.read() == "key-for-\(provider.rawValue)")

                // Remove the key
                try keyStore.remove()
                #expect(!keyStore.hasKey(), "\(provider) should have no key after removal")
                #expect(try keyStore.read() == nil)
            } else {
                // Command-line providers require no saved key; hasKey() is always true
                #expect(keyStore.hasKey(), "\(provider) CLI tool requires no saved key, hasKey() must be true")
                #expect(!keyStore.savedKeyPresent(), "\(provider) has no saved key in its slot initially")
                #expect(try keyStore.read() == nil)
            }
        }
    }

    @Test func slotIsolationAcrossProviders() throws {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let keyStore = ActiveProviderKeyStore.inMemory(preferences: preferences)

        // Save key for OpenAI
        preferences.provider = .openAIKey
        try keyStore.save("sk-openai-12345")
        #expect(keyStore.hasKey())
        #expect(try keyStore.read() == "sk-openai-12345")

        // Switch to Anthropic: slot should be empty
        preferences.provider = .anthropicKey
        #expect(!keyStore.hasKey())
        #expect(try keyStore.read() == nil)

        // Save key for Anthropic
        try keyStore.save("sk-ant-67890")
        #expect(keyStore.hasKey())
        #expect(try keyStore.read() == "sk-ant-67890")

        // Switch back to OpenAI: slot is intact
        preferences.provider = .openAIKey
        #expect(keyStore.hasKey())
        #expect(try keyStore.read() == "sk-openai-12345")

        // Switch to OpenCode CLI: hasKey is true (no key required), read is nil
        preferences.provider = .openCodeCLI
        #expect(keyStore.hasKey())
        #expect(try keyStore.read() == nil)

        // Remove key from OpenAI
        preferences.provider = .openAIKey
        try keyStore.remove()
        #expect(!keyStore.hasKey())
        #expect(try keyStore.read() == nil)

        // Anthropic still has its key
        preferences.provider = .anthropicKey
        #expect(keyStore.hasKey())
        #expect(try keyStore.read() == "sk-ant-67890")
    }

    @Test func preloadedInMemorySlotsTruthTable() throws {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let initialKeys: [AdLabellerProvider: String] = [
            .opencodeGoKey: "opencode-key",
            .openRouterKey: "router-key",
        ]
        let keyStore = ActiveProviderKeyStore(preferences: preferences, inMemoryKeys: initialKeys)

        preferences.provider = .opencodeGoKey
        #expect(keyStore.hasKey())
        #expect(try keyStore.read() == "opencode-key")

        preferences.provider = .openRouterKey
        #expect(keyStore.hasKey())
        #expect(try keyStore.read() == "router-key")

        preferences.provider = .openAIKey
        #expect(!keyStore.hasKey())
        #expect(try keyStore.read() == nil)

        preferences.provider = .anthropicKey
        #expect(!keyStore.hasKey())
        #expect(try keyStore.read() == nil)

        preferences.provider = .openCodeCLI
        #expect(keyStore.hasKey())

        preferences.provider = .claudeCodeCLI
        #expect(keyStore.hasKey())

        preferences.provider = .codexCLI
        #expect(keyStore.hasKey())
    }
}
