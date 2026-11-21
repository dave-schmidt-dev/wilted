import Foundation
import Observation
import WiltedProducer

// MARK: - Types

extension AdLabellerProvider: @retroactive Identifiable {
    public var id: Self { self }
}

extension AdLabellerModelCatalog.ModelInfo: @retroactive Identifiable, @retroactive Equatable {
    public static func == (lhs: AdLabellerModelCatalog.ModelInfo, rhs: AdLabellerModelCatalog.ModelInfo) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.supportedLevels == rhs.supportedLevels
    }
}

// MARK: - ViewModel

/// The Provider settings card's model: provider choices, per-provider model and
/// thinking level, command-line tool readiness check, saved keys, and privacy notes.
@MainActor @Observable
public final class WiltedMacProviderSettings {

    /// One row representing an ad labeller provider.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: AdLabellerProvider
        public var provider: AdLabellerProvider { id }
        public let name: String
        public let kind: String
        public let hasSavedKey: Bool
        public let isAcknowledged: Bool
        public let needsAcknowledgement: Bool
        public let status: String
        public let isChosen: Bool

        public init(
            provider: AdLabellerProvider,
            name: String,
            kind: String,
            hasSavedKey: Bool,
            isAcknowledged: Bool,
            needsAcknowledgement: Bool,
            status: String,
            isChosen: Bool
        ) {
            self.id = provider
            self.name = name
            self.kind = kind
            self.hasSavedKey = hasSavedKey
            self.isAcknowledged = isAcknowledged
            self.needsAcknowledgement = needsAcknowledgement
            self.status = status
            self.isChosen = isChosen
        }
    }

    /// Fixed plain privacy note for a provider.
    public struct PrivacyNote: Equatable, Sendable {
        public let sends: String
        public let theirTerms: String
        public let policyURL: URL?

        public init(sends: String, theirTerms: String, policyURL: URL?) {
            self.sends = sends
            self.theirTerms = theirTerms
            self.policyURL = policyURL
        }
    }

    public static let rowOrder: [AdLabellerProvider] = [
        .openCodeCLI,
        .claudeCodeCLI,
        .codexCLI,
        .opencodeGoKey,
        .openRouterKey,
        .openAIKey,
        .anthropicKey,
    ]

    private let preferences: UserDefaults
    private let keyStore: ActiveProviderKeyStore
    private let checkProvider: @Sendable (AdLabellerProvider) async -> LabellerCommandLineStatus

    /// Draft text for typed model id.
    public var typedModel: String = ""
    public private(set) var typedModelMessage: String?
    public private(set) var levelMessage: String?
    public private(set) var keyMessage: String?

    private var runningChecks: Set<AdLabellerProvider> = []
    private var commandLineStatuses: [AdLabellerProvider: LabellerCommandLineStatus] = [:]

    public init(
        preferences: UserDefaults,
        keyStore: ActiveProviderKeyStore,
        check: @escaping @Sendable (AdLabellerProvider) async -> LabellerCommandLineStatus = {
            await LabellerCommandLineCheck.check(provider: $0)
        }
    ) {
        self.preferences = preferences
        self.keyStore = keyStore
        self.checkProvider = check
        let labeller = AdLabellerPreferences(preferences: preferences)
        self.typedModel = labeller.modelID(for: labeller.provider)
    }

    private var labeller: AdLabellerPreferences {
        AdLabellerPreferences(preferences: preferences)
    }

    // MARK: - Choice

    public var provider: AdLabellerProvider {
        labeller.provider
    }

    public func setProvider(_ newProvider: AdLabellerProvider) {
        labeller.provider = newProvider
        typedModel = labeller.modelID(for: newProvider)
        typedModelMessage = nil
        levelMessage = nil
        keyMessage = nil
    }

    public var modelChoices: [AdLabellerModelCatalog.ModelInfo] {
        AdLabellerModelCatalog.modelsByProvider[provider] ?? []
    }

    public var model: String {
        labeller.modelID(for: provider)
    }

    public func setModel(_ newModel: String) {
        let trimmed = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        labeller.setModelID(trimmed, for: provider)
        typedModel = trimmed
        typedModelMessage = nil
        levelMessage = nil

        let currentLevel = labeller.level(for: provider)
        let supported = supportedLevels(for: trimmed, provider: provider)
        if !supported.contains(currentLevel) {
            let fallback = supported.contains("low") ? "low" : (supported.first ?? "low")
            labeller.setLevel(fallback, for: provider)
        }
    }

    public var usesTypedModel: Bool {
        modelChoices.isEmpty
    }

    public func saveTypedModel() {
        let trimmed = typedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            typedModelMessage = "Enter a model id first."
            return
        }
        typedModelMessage = nil
        typedModel = trimmed
        setModel(trimmed)
    }

    public var levelChoices: [String] {
        supportedLevels(for: model, provider: provider)
    }

    public var level: String {
        labeller.level(for: provider)
    }

    public func setLevel(_ newLevel: String) {
        let choices = levelChoices
        guard choices.contains(newLevel) else {
            levelMessage = "This model does not support that thinking level."
            return
        }
        levelMessage = nil
        labeller.setLevel(newLevel, for: provider)
    }

    public static func levelLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh", "extra high", "extrahigh": return "Extra high"
        case "max": return "Max"
        case "default": return "Default"
        default: return level.capitalized
        }
    }

    public func levelLabel(_ level: String) -> String {
        Self.levelLabel(level)
    }

    // MARK: - Per-provider Rows

    public var rows: [Row] {
        Self.rowOrder.map { row(for: $0) }
    }

    private func row(for targetProvider: AdLabellerProvider) -> Row {
        let kind = targetProvider.requiresSavedKey ? "Key" : "Command-line tool"
        let hasSaved = targetProvider.requiresSavedKey ? keyStore.savedKeyPresent(for: targetProvider) : false
        let isAck = labeller.isAcknowledged(targetProvider)
        let needsAck = targetProvider.requiresAcknowledgement && !isAck
        let isChosen = targetProvider == provider

        let statusText: String
        if targetProvider.requiresSavedKey {
            if !hasSaved {
                statusText = "No key saved"
            } else if needsAck {
                statusText = "Key saved, privacy note not accepted yet"
            } else {
                statusText = "Ready"
            }
        } else {
            if runningChecks.contains(targetProvider) {
                statusText = "Checking..."
            } else if let checkResult = commandLineStatuses[targetProvider] {
                switch checkResult {
                case .notFound:
                    statusText = "Tool not found on this Mac"
                case .notSignedIn:
                    statusText = "Not signed in"
                case .ready:
                    statusText = "Ready"
                case .failed(let message):
                    statusText = message
                }
            } else {
                statusText = "Not checked yet"
            }
        }

        return Row(
            provider: targetProvider,
            name: targetProvider.displayName,
            kind: kind,
            hasSavedKey: hasSaved,
            isAcknowledged: isAck,
            needsAcknowledgement: needsAck,
            status: statusText,
            isChosen: isChosen
        )
    }

    // MARK: - Actions

    public func saveKey(_ key: String, for provider: AdLabellerProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyMessage = "Enter a provider key first."
            return
        }
        do {
            try keyStore.slot(for: provider).save(trimmed)
            keyMessage = nil
        } catch {
            keyMessage = "The key could not be saved."
        }
    }

    public func removeKey(for provider: AdLabellerProvider) {
        try? keyStore.slot(for: provider).remove()
    }

    public func acknowledge(_ provider: AdLabellerProvider) {
        labeller.acknowledge(provider)
    }

    public func revokeAcknowledgement(_ provider: AdLabellerProvider) {
        labeller.revokeAcknowledgement(provider)
    }

    public func check(_ provider: AdLabellerProvider) async {
        guard !provider.requiresSavedKey else { return }
        guard !runningChecks.contains(provider) else { return }
        runningChecks.insert(provider)
        defer { runningChecks.remove(provider) }

        let result = await checkProvider(provider)
        commandLineStatuses[provider] = result
    }

    // MARK: - Privacy Note

    public func privacyNote(for provider: AdLabellerProvider) -> PrivacyNote {
        let sends = "Wilted sends the transcript of an allowed show's episode and the show's name, nothing else: no audio, no feed address, no episode title."
        let name = providerTermsName(for: provider)
        let terms = "What \(name) keeps or trains on is set by \(name)'s own terms, not by Wilted."

        let url: URL?
        switch provider {
        case .openAIKey, .codexCLI:
            url = URL(string: "https://openai.com/policies/privacy-policy")
        case .anthropicKey, .claudeCodeCLI:
            url = URL(string: "https://www.anthropic.com/legal/privacy")
        case .openRouterKey:
            url = URL(string: "https://openrouter.ai/privacy")
        case .opencodeGoKey, .openCodeCLI:
            url = nil
        }

        return PrivacyNote(sends: sends, theirTerms: terms, policyURL: url)
    }

    // MARK: - Readiness Line

    public var readinessLine: String {
        // Priority 1: No model chosen
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Type a model id."
        }

        // Priority 2: Key provider with no key
        if provider.requiresSavedKey && !keyStore.savedKeyPresent(for: provider) {
            return "No key saved. Add one in Providers."
        }

        // Priority 3: Needs acknowledgement
        if provider.requiresAcknowledgement && !labeller.isAcknowledged(provider) {
            return "Accept \(provider.displayName)'s privacy note in Providers."
        }

        // Priority 4: Command-line provider not found or not signed in per last check (if checked)
        if !provider.requiresSavedKey, let checkStatus = commandLineStatuses[provider] {
            switch checkStatus {
            case .notFound:
                return "Tool not found on this Mac."
            case .notSignedIn:
                return "Not signed in."
            case .failed(let message):
                return message
            case .ready:
                break
            }
        }

        // Priority 5: Ready
        let modelDisplay = modelDisplayNameOrID
        let levelText = levelLabel(level)
        return "Ready: \(provider.displayName) · \(modelDisplay) · \(levelText)"
    }

    // MARK: - Private Helpers

    private var modelDisplayNameOrID: String {
        let known = AdLabellerModelCatalog.modelsByProvider[provider]?.first(where: { $0.id == model })
        return known?.displayName ?? model
    }

    private func supportedLevels(for modelID: String, provider: AdLabellerProvider) -> [String] {
        if let match = AdLabellerModelCatalog.modelsByProvider[provider]?.first(where: { $0.id == modelID }) {
            return match.supportedLevels
        }
        return ["low", "medium", "high"]
    }

    private func providerTermsName(for provider: AdLabellerProvider) -> String {
        switch provider {
        case .opencodeGoKey, .openCodeCLI:
            return "OpenCode"
        case .claudeCodeCLI:
            return "Claude Code"
        case .codexCLI:
            return "Codex"
        case .openRouterKey:
            return "OpenRouter"
        case .openAIKey:
            return "OpenAI"
        case .anthropicKey:
            return "Anthropic"
        }
    }
}
