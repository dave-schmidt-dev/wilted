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

            // 1. Initial state (unacknowledged, no key saved)
            if provider == .openCodeCLI {
                // Grandfathered CLI tool: needs no key and needs no acknowledgement
                #expect(keyStore.hasKey(), "\(provider) is grandfathered CLI and should be ready initially")
                #expect(keyStore.isReady(provider: provider))
                #expect(!keyStore.savedKeyPresent())
            } else {
                #expect(!keyStore.hasKey(), "\(provider) should not be ready initially")
                #expect(!keyStore.isReady(provider: provider))
                #expect(!keyStore.savedKeyPresent())
            }

            if provider.requiresSavedKey {
                // Save a key for this provider
                try keyStore.save("key-for-\(provider.rawValue)")
                #expect(keyStore.savedKeyPresent(), "\(provider) should report saved key present after save")
                #expect(try keyStore.read() == "key-for-\(provider.rawValue)")

                if provider.requiresAcknowledgement {
                    // Has key, but still unacknowledged -> not ready
                    #expect(!keyStore.hasKey(), "\(provider) requires acknowledgement and should not be ready with key alone")
                    #expect(!keyStore.isReady(provider: provider))

                    // Acknowledge -> now ready!
                    preferences.acknowledge(provider)
                    #expect(keyStore.hasKey(), "\(provider) should be ready with key and acknowledgement")
                    #expect(keyStore.isReady(provider: provider))

                    // Revoke acknowledgement -> not ready again
                    preferences.revokeAcknowledgement(provider)
                    #expect(!keyStore.hasKey(), "\(provider) should not be ready after revoking acknowledgement")
                    #expect(!keyStore.isReady(provider: provider))

                    // Re-acknowledge for remaining tests
                    preferences.acknowledge(provider)
                } else {
                    // Grandfathered key provider (opencodeGoKey): ready as soon as key is saved
                    #expect(keyStore.hasKey(), "\(provider) should be ready after saving key")
                    #expect(keyStore.isReady(provider: provider))
                }

                // Remove the key
                try keyStore.remove()
                #expect(!keyStore.hasKey(), "\(provider) should not be ready after key removal")
                #expect(!keyStore.isReady(provider: provider))
                #expect(!keyStore.savedKeyPresent())
                #expect(try keyStore.read() == nil)
            } else if provider.requiresAcknowledgement {
                // Non-grandfathered CLI provider (claudeCodeCLI, codexCLI): needs acknowledgement
                #expect(!keyStore.hasKey(), "\(provider) should not be ready while unacknowledged")
                #expect(!keyStore.isReady(provider: provider))

                preferences.acknowledge(provider)
                #expect(keyStore.hasKey(), "\(provider) should be ready after acknowledgement")
                #expect(keyStore.isReady(provider: provider))

                preferences.revokeAcknowledgement(provider)
                #expect(!keyStore.hasKey(), "\(provider) should not be ready after revoking acknowledgement")
                #expect(!keyStore.isReady(provider: provider))
            }
        }
    }

    @Test func slotIsolationAcrossProviders() throws {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        // Acknowledge non-grandfathered providers so readiness reflects key slot presence
        preferences.acknowledge(.openAIKey)
        preferences.acknowledge(.anthropicKey)

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

        // Switch to OpenCode CLI: hasKey is true (no key required, grandfathered), read is nil
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

        // Acknowledge providers to check key-slot presence readiness
        preferences.acknowledge(.openRouterKey)
        preferences.acknowledge(.openAIKey)
        preferences.acknowledge(.anthropicKey)
        preferences.acknowledge(.claudeCodeCLI)
        preferences.acknowledge(.codexCLI)

        let initialKeys: [AdLabellerProvider: String] = [
            .opencodeGoKey: "opencode-key",
            .openRouterKey: "router-key",
        ]
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
