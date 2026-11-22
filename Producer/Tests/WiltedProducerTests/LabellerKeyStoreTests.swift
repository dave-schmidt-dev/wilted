import Foundation
import Security
import Testing
@testable import WiltedProducer

@Suite("Labeller key store and per-provider slots")
struct LabellerKeyStoreTests {
    @Test func keychainAccountsIncludeProviderRawValueExceptOpenCodeGo() {
        #expect(KeychainLabellerKeyStore.account(for: .opencodeGoKey) == "ad-labeller-api-key")
        #expect(KeychainLabellerKeyStore.account(for: .openRouterKey) == "ad-labeller-api-key-openRouterKey")
        #expect(KeychainLabellerKeyStore.account(for: .openAIKey) == "ad-labeller-api-key-openAIKey")
        #expect(KeychainLabellerKeyStore.account(for: .anthropicKey) == "ad-labeller-api-key-anthropicKey")
        #expect(KeychainLabellerKeyStore.account(for: .openCodeCLI) == "ad-labeller-api-key-openCodeCLI")
        #expect(KeychainLabellerKeyStore.account(for: .claudeCodeCLI) == "ad-labeller-api-key-claudeCodeCLI")
        #expect(KeychainLabellerKeyStore.account(for: .codexCLI) == "ad-labeller-api-key-codexCLI")

        let defaultStore = KeychainLabellerKeyStore()
        #expect(defaultStore.provider == .opencodeGoKey)
        #expect(defaultStore.account == "ad-labeller-api-key")

        let anthropicStore = KeychainLabellerKeyStore(provider: .anthropicKey)
        #expect(anthropicStore.provider == .anthropicKey)
        #expect(anthropicStore.account == "ad-labeller-api-key-anthropicKey")
    }

    @Test func keychainQueriesUseIsolatedAccountPerProvider() {
        let openAIQuery = KeychainLabellerKeyStore.baseQuery(service: "test-svc", account: KeychainLabellerKeyStore.account(for: .openAIKey))
        #expect(openAIQuery[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(openAIQuery[kSecAttrService as String] as? String == "test-svc")
        #expect(openAIQuery[kSecAttrAccount as String] as? String == "ad-labeller-api-key-openAIKey")
        #expect(openAIQuery[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(openAIQuery[kSecUseDataProtectionKeychain as String] as? Bool == true)

        let addQuery = KeychainLabellerKeyStore.addQuery(
            service: "test-svc",
            account: KeychainLabellerKeyStore.account(for: .anthropicKey),
            keyData: Data("k".utf8)
        )
        #expect(addQuery[kSecAttrAccount as String] as? String == "ad-labeller-api-key-anthropicKey")
        #expect(addQuery[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test func inMemoryKeyStoreIsolatesSlotsPerProvider() throws {
        let store = InMemoryLabellerKeyStore(keys: [
            .openRouterKey: "openrouter-secret",
            .anthropicKey: "anthropic-secret",
        ], provider: .openRouterKey)

        #expect(store.hasKey())
        #expect(store.savedKeyPresent())
        #expect(try store.read() == "openrouter-secret")

        // Other providers via savedKeyPresent(for:)
        #expect(store.savedKeyPresent(for: .openRouterKey) == true)
        #expect(store.savedKeyPresent(for: .anthropicKey) == true)
        #expect(store.savedKeyPresent(for: .openAIKey) == false)
        #expect(store.savedKeyPresent(for: .opencodeGoKey) == false)

        // Switching provider store
        let openAIStore = InMemoryLabellerKeyStore(provider: .openAIKey)
        #expect(!openAIStore.hasKey())
        #expect(try openAIStore.read() == nil)
        try openAIStore.save("sk-openai")
        #expect(openAIStore.hasKey())
        #expect(try openAIStore.read() == "sk-openai")

        // Removing key clears only that provider
        try openAIStore.remove()
        #expect(!openAIStore.hasKey())
        #expect(try openAIStore.read() == nil)
    }

    @Test func pureSavedKeyPresentAPI() {
        let keys: [AdLabellerProvider: String] = [
            .openRouterKey: "router-key",
            .openAIKey: "  \n  ", // empty when trimmed
        ]

        #expect(LabellerKeyPresence.savedKeyPresent(for: .openRouterKey, in: keys) == true)
        #expect(LabellerKeyPresence.savedKeyPresent(for: .openAIKey, in: keys) == false)
        #expect(LabellerKeyPresence.savedKeyPresent(for: .anthropicKey, in: keys) == false)

        let presenceLookup: (AdLabellerProvider) -> Bool = { provider in
            provider == .anthropicKey
        }
        #expect(LabellerKeyPresence.savedKeyPresent(for: .anthropicKey, hasKey: presenceLookup) == true)
        #expect(LabellerKeyPresence.savedKeyPresent(for: .openRouterKey, hasKey: presenceLookup) == false)
    }
}
