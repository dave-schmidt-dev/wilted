import Foundation
import Testing
@testable import WiltedProducer

@Suite("Ad labeller provider choices and validation")
struct AdLabellerProviderChoiceTests {
    @Test func defaultPreferencesMatchToday() {
        let suite = "test-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AdLabellerPreferences(preferences: defaults)
        #expect(prefs.provider == .opencodeGoKey) // OpenCode Go Key default when no preference is stored
        #expect(prefs.modelID == "deepseek-v4.1-flash")
        #expect(prefs.level == "low")
        #expect(prefs.usesOpenCodeCLI == false)
    }

    @Test func legacyUseOpenCodeCLITrueMigratesToOpenCodeCLIProvider() {
        let suite = "test-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "wilted.adLabeller.useOpenCodeCLI")
        let prefs = AdLabellerPreferences(preferences: defaults)
        #expect(prefs.provider == .openCodeCLI)
        #expect(prefs.usesOpenCodeCLI == true)
    }

    @Test func legacyUseOpenCodeCLIFalseMigratesToOpenCodeGoKeyProvider() {
        let suite = "test-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: "wilted.adLabeller.useOpenCodeCLI")
        let prefs = AdLabellerPreferences(preferences: defaults)
        #expect(prefs.provider == .opencodeGoKey)
        #expect(prefs.usesOpenCodeCLI == false)
    }

    @Test func settingProviderUpdatesStoredChoiceAndKeepsLegacyBooleanConsistent() {
        let suite = "test-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AdLabellerPreferences(preferences: defaults)
        prefs.provider = .claudeCodeCLI
        #expect(prefs.provider == .claudeCodeCLI)
        #expect(defaults.string(forKey: "wilted.adLabeller.provider") == "claudeCodeCLI")
        #expect(prefs.usesOpenCodeCLI == false)

        prefs.provider = .openCodeCLI
        #expect(prefs.provider == .openCodeCLI)
        #expect(prefs.usesOpenCodeCLI == true)

        prefs.provider = .opencodeGoKey
        #expect(prefs.provider == .opencodeGoKey)
        #expect(prefs.usesOpenCodeCLI == false)
    }

    @Test func providerRequiresSavedKey() {
        #expect(AdLabellerProvider.opencodeGoKey.requiresSavedKey == true)
        #expect(AdLabellerProvider.openRouterKey.requiresSavedKey == true)
        #expect(AdLabellerProvider.openAIKey.requiresSavedKey == true)
        #expect(AdLabellerProvider.anthropicKey.requiresSavedKey == true)

        #expect(AdLabellerProvider.openCodeCLI.requiresSavedKey == false)
        #expect(AdLabellerProvider.claudeCodeCLI.requiresSavedKey == false)
        #expect(AdLabellerProvider.codexCLI.requiresSavedKey == false)

        #expect(AdLabellerModelCatalog.requiresSavedKey(provider: .opencodeGoKey) == true)
        #expect(AdLabellerModelCatalog.requiresSavedKey(provider: .openCodeCLI) == false)
    }

    @Test func modelAndLevelValidation() {
        // Known model and known levels
        #expect(AdLabellerModelCatalog.isValid(provider: .openCodeCLI, model: "deepseek-v4.1-flash", level: "low"))
        #expect(AdLabellerModelCatalog.isValid(provider: .openCodeCLI, model: "deepseek-v4.1-flash", level: "high"))
        #expect(AdLabellerModelCatalog.isValid(provider: .openCodeCLI, model: "deepseek-v4.1-flash", level: "default"))
        #expect(AdLabellerModelCatalog.isValid(provider: .openCodeCLI, model: "deepseek-v4.1-flash", level: "max"))
        #expect(!AdLabellerModelCatalog.isValid(provider: .openCodeCLI, model: "deepseek-v4.1-flash", level: "unsupported"))
        #expect(!AdLabellerModelCatalog.isValid(provider: .openCodeCLI, model: "deepseek-v4.1-flash", level: ""))

        // Unknown custom model id
        #expect(AdLabellerModelCatalog.isValid(provider: .openCodeCLI, model: "custom-model", level: "anything"))
        #expect(!AdLabellerModelCatalog.isValid(provider: .openCodeCLI, model: "custom-model", level: ""))
    }

    @Test func commandLineRefusalSentences() {
        let missingOpenCode = LabellerCommandLineRefusal.executableNotUsable(provider: .openCodeCLI)
        #expect(missingOpenCode.reasonSentence == "The OpenCode command-line tool is not installed or not usable on this Mac.")

        let missingClaude = LabellerCommandLineRefusal.executableNotUsable(provider: .claudeCodeCLI)
        #expect(missingClaude.reasonSentence == "The Claude Code command-line tool is not installed or not usable on this Mac.")

        let missingCodex = LabellerCommandLineRefusal.executableNotUsable(provider: .codexCLI)
        #expect(missingCodex.reasonSentence == "The Codex command-line tool is not installed or not usable on this Mac.")

        let labellerFailure = LabellerFailure.commandLineToolUnavailable(provider: .openCodeCLI)
        #expect(labellerFailure.kind == "command-line-tool-unavailable")
        #expect(labellerFailure.reasonSentence == "The OpenCode command-line tool is not installed or not usable on this Mac.")
    }

    @Test func perProviderModelAndLevelRoundTrip() {
        let suite = "test-per-provider-roundtrip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AdLabellerPreferences(preferences: defaults)

        for provider in AdLabellerProvider.allCases {
            prefs.setModelID("model-\(provider.rawValue)", for: provider)
            prefs.setLevel("level-\(provider.rawValue)", for: provider)
        }

        for provider in AdLabellerProvider.allCases {
            #expect(prefs.modelID(for: provider) == "model-\(provider.rawValue)")
            #expect(prefs.level(for: provider) == "level-\(provider.rawValue)")
        }
    }

    @Test func legacyGlobalValuesReadForOpenCodeProvidersAndIgnoredForOthers() {
        let suite = "test-legacy-globals-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("legacy-model-global", forKey: "wilted.adLabeller.modelID")
        defaults.set("legacy-level-global", forKey: "wilted.adLabeller.level")

        let prefs = AdLabellerPreferences(preferences: defaults)

        #expect(prefs.modelID(for: .opencodeGoKey) == "legacy-model-global")
        #expect(prefs.level(for: .opencodeGoKey) == "legacy-level-global")
        #expect(prefs.modelID(for: .openCodeCLI) == "legacy-model-global")
        #expect(prefs.level(for: .openCodeCLI) == "legacy-level-global")

        #expect(prefs.modelID(for: .claudeCodeCLI) == "claude-sonnet-5-5")
        #expect(prefs.level(for: .claudeCodeCLI) == "low")
        #expect(prefs.modelID(for: .codexCLI) == "gpt-6.1-terra")
        #expect(prefs.level(for: .codexCLI) == "low")
        #expect(prefs.modelID(for: .anthropicKey) == "claude-sonnet-5-5")
        #expect(prefs.level(for: .anthropicKey) == "low")
        #expect(prefs.modelID(for: .openRouterKey) == "")
        #expect(prefs.level(for: .openRouterKey) == "low")
        #expect(prefs.modelID(for: .openAIKey) == "")
        #expect(prefs.level(for: .openAIKey) == "low")
    }

    @Test func defaultModelsAndThinkingLevels() {
        let suite = "test-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AdLabellerPreferences(preferences: defaults)

        #expect(prefs.modelID(for: .opencodeGoKey) == "deepseek-v4.1-flash")
        #expect(prefs.level(for: .opencodeGoKey) == "low")
        #expect(prefs.modelID(for: .openCodeCLI) == "deepseek-v4.1-flash")
        #expect(prefs.level(for: .openCodeCLI) == "low")
        #expect(prefs.modelID(for: .claudeCodeCLI) == "claude-sonnet-5-5")
        #expect(prefs.level(for: .claudeCodeCLI) == "low")
        #expect(prefs.modelID(for: .codexCLI) == "gpt-6.1-terra")
        #expect(prefs.level(for: .codexCLI) == "low")
        #expect(prefs.modelID(for: .anthropicKey) == "claude-sonnet-5-5")
        #expect(prefs.level(for: .anthropicKey) == "low")
        #expect(prefs.modelID(for: .openRouterKey) == "")
        #expect(prefs.level(for: .openRouterKey) == "low")
        #expect(prefs.modelID(for: .openAIKey) == "")
        #expect(prefs.level(for: .openAIKey) == "low")
    }

    @Test func openAIAndOpenRouterBlankModelMeansNotReadyAndNotValid() {
        let suite = "test-blank-model-not-ready-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AdLabellerPreferences(preferences: defaults)
        let keyStore = ActiveProviderKeyStore.inMemory(preferences: prefs, initialKeys: [
            .openAIKey: "sk-openai-key",
            .openRouterKey: "sk-router-key",
        ])

        prefs.provider = .openAIKey
        #expect(prefs.modelID == "")
        #expect(!prefs.hasValidChoice)
        #expect(!keyStore.hasKey())
        #expect(!keyStore.isReady(provider: .openAIKey))

        prefs.provider = .openRouterKey
        #expect(prefs.modelID == "")
        #expect(!prefs.hasValidChoice)
        #expect(!keyStore.hasKey())
        #expect(!keyStore.isReady(provider: .openRouterKey))

        prefs.setModelID("gpt-4o", for: .openAIKey)
        prefs.provider = .openAIKey
        #expect(prefs.hasValidChoice)
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .openAIKey))
    }

    @Test func switchingProvidersKeepsEachChoiceAndPipelineFacingPropertiesFollow() {
        let suite = "test-switching-keeps-choice-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AdLabellerPreferences(preferences: defaults)

        prefs.provider = .opencodeGoKey
        prefs.modelID = "deepseek-v4-pro"
        prefs.level = "high"

        prefs.provider = .claudeCodeCLI
        prefs.modelID = "claude-opus-5-5"
        prefs.level = "max"

        prefs.provider = .openAIKey
        prefs.modelID = "gpt-4o"
        prefs.level = "medium"

        #expect(prefs.modelID == "gpt-4o")
        #expect(prefs.level == "medium")

        prefs.provider = .claudeCodeCLI
        #expect(prefs.modelID == "claude-opus-5-5")
        #expect(prefs.level == "max")

        prefs.provider = .opencodeGoKey
        #expect(prefs.modelID == "deepseek-v4-pro")
        #expect(prefs.level == "high")
    }

    @Test func unsupportedLevelForKnownModelIsInvalid() {
        let suite = "test-invalid-level-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = AdLabellerPreferences(preferences: defaults)
        prefs.provider = .claudeCodeCLI
        prefs.modelID = "claude-sonnet-5-5"
        prefs.level = "unsupported-level"

        #expect(!prefs.hasValidChoice)
        #expect(!AdLabellerModelCatalog.isValid(provider: .claudeCodeCLI, model: prefs.modelID, level: prefs.level))

        let keyStore = ActiveProviderKeyStore.inMemory(preferences: prefs)
        #expect(!keyStore.hasKey())
        #expect(!keyStore.isReady(provider: .claudeCodeCLI))

        prefs.level = "high"
        #expect(prefs.hasValidChoice)
        #expect(keyStore.hasKey())
        #expect(keyStore.isReady(provider: .claudeCodeCLI))
    }
}
