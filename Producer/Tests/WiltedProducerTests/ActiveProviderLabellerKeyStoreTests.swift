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
            if provider == .openRouterKey || provider == .openAIKey {
                preferences.setModelID("some-model", for: provider)
            }

            #expect(keyStore.hasKey() == !provider.requiresSavedKey)
            #expect(keyStore.isReady(provider: provider) == !provider.requiresSavedKey)
            #expect(!keyStore.savedKeyPresent())

            if provider.requiresSavedKey {
                // Save a key for this provider
                try keyStore.save("key-for-\(provider.rawValue)")
                #expect(keyStore.savedKeyPresent(), "\(provider) should report saved key present after save")
                #expect(try keyStore.read() == "key-for-\(provider.rawValue)")

                #expect(keyStore.hasKey())
                #expect(keyStore.isReady(provider: provider))

                // Remove the key
                try keyStore.remove()
                #expect(!keyStore.hasKey(), "\(provider) should not be ready after key removal")
                #expect(!keyStore.isReady(provider: provider))
                #expect(!keyStore.savedKeyPresent())
                #expect(try keyStore.read() == nil)
            }
        }
    }

    @Test func savedKeyAndValidModelMakeProviderReadyImmediately() throws {
        let suite = "test-provider-ready-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AdLabellerPreferences(preferences: defaults)
        preferences.provider = .openAIKey
        preferences.setModelID("gpt-4o", for: .openAIKey)
        let keyStore = ActiveProviderKeyStore.inMemory(preferences: preferences)
        try keyStore.save("test-key")
        #expect(keyStore.isReady(provider: .openAIKey))
    }

    @Test func slotIsolationAcrossProviders() throws {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        preferences.setModelID("gpt-4o", for: .openAIKey)

        let keyStore = ActiveProviderKeyStore.inMemory(preferences: preferences)

        // Save key for OpenAI
        preferences.provider = .openAIKey
        try keyStore.save("sk-openai-12345")
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .openAIKey))
        #expect(try keyStore.read() == "sk-openai-12345")

        // Switch to Anthropic: slot should be empty
        preferences.provider = .anthropicKey
        #expect(!keyStore.hasKey())
        #expect(!keyStore.isReady(provider: .anthropicKey))
        #expect(try keyStore.read() == nil)

        // Save key for Anthropic
        try keyStore.save("sk-ant-67890")
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .anthropicKey))
        #expect(try keyStore.read() == "sk-ant-67890")

        // Switch back to OpenAI: slot is intact
        preferences.provider = .openAIKey
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .openAIKey))
        #expect(try keyStore.read() == "sk-openai-12345")

        // Switch to OpenCode CLI: hasKey is true (no key required), read is nil
        preferences.provider = .openCodeCLI
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .openCodeCLI))
        #expect(try keyStore.read() == nil)

        // Remove key from OpenAI
        preferences.provider = .openAIKey
        try keyStore.remove()
        #expect(!keyStore.hasKey())
        #expect(!keyStore.isReady(provider: .openAIKey))
        #expect(try keyStore.read() == nil)

        // Anthropic still has its key
        preferences.provider = .anthropicKey
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .anthropicKey))
        #expect(try keyStore.read() == "sk-ant-67890")
    }

    @Test func preloadedInMemorySlotsTruthTable() throws {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let initialKeys: [AdLabellerProvider: String] = [
            .opencodeGoKey: "opencode-key",
            .openRouterKey: "router-key",
        ]
        preferences.setModelID("openrouter-model", for: .openRouterKey)
        let keyStore = ActiveProviderKeyStore(preferences: preferences, inMemoryKeys: initialKeys)

        preferences.provider = .opencodeGoKey
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .opencodeGoKey))
        #expect(try keyStore.read() == "opencode-key")

        preferences.provider = .openRouterKey
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .openRouterKey))
        #expect(try keyStore.read() == "router-key")

        preferences.provider = .openAIKey
        #expect(!keyStore.hasKey())
        #expect(!keyStore.isReady(provider: .openAIKey))
        #expect(try keyStore.read() == nil)

        preferences.provider = .anthropicKey
        #expect(!keyStore.hasKey())
        #expect(!keyStore.isReady(provider: .anthropicKey))
        #expect(try keyStore.read() == nil)

        preferences.provider = .openCodeCLI
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .openCodeCLI))

        preferences.provider = .claudeCodeCLI
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .claudeCodeCLI))

        preferences.provider = .codexCLI
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .codexCLI))
    }
}
