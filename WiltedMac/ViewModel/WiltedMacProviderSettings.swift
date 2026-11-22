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

struct WiltedMacFixtureProviderCheckSender: LabellerSending {
    func send(
        _ request: LabellerRequest,
        onRequestStarted: @escaping @Sendable () -> Void,
        onProgress: @escaping @Sendable (LabellerProgress) -> Void
    ) async throws -> LabellerResponse {
        LabellerResponse(text: "OK", usage: LabellerUsage())
    }
}

// MARK: - ViewModel

/// The Provider settings card's model: provider choices, per-provider model and
/// thinking level, provider readiness checks, and saved keys.
@MainActor @Observable
public final class WiltedMacProviderSettings {

    /// One row representing an ad labeller provider.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: AdLabellerProvider
        public var provider: AdLabellerProvider { id }
        public let name: String
        public let kind: String
        public let hasSavedKey: Bool
        public let status: String
        public let isChosen: Bool

        public init(
            provider: AdLabellerProvider,
            name: String,
            kind: String,
            hasSavedKey: Bool,
            status: String,
            isChosen: Bool
        ) {
            self.id = provider
            self.name = name
            self.kind = kind
            self.hasSavedKey = hasSavedKey
            self.status = status
            self.isChosen = isChosen
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
    private let makeKeySender: @Sendable (AdLabellerProvider, any LabellerKeyStoring) throws -> any LabellerSending

    /// Draft text for typed model id.
    public var typedModel: String = ""
    public private(set) var typedModelMessage: String?
    public private(set) var levelMessage: String?
    public private(set) var keyMessage: String?

    /// Bumped by every change made through this model, so views reading the stored
    /// preferences and keys redraw: those stores are not observable themselves.
    private var revision = 0

    private var runningChecks: Set<AdLabellerProvider> = []
    private var commandLineStatuses: [AdLabellerProvider: LabellerCommandLineStatus] = [:]
    private var keyProviderStatuses: [AdLabellerProvider: KeyProviderStatus] = [:]
    private var keyStatusGenerations: [AdLabellerProvider: Int] = [:]

    private enum KeyProviderStatus {
        case noKeySet
        case ready
        case rejected
        case unreachable

        var text: String {
            switch self {
            case .noKeySet: "No key set"
            case .ready: "Ready"
            case .rejected: "Key rejected"
            case .unreachable: "Can't reach it"
            }
        }
    }

    public init(
        preferences: UserDefaults,
        keyStore: ActiveProviderKeyStore,
        check: @escaping @Sendable (AdLabellerProvider) async -> LabellerCommandLineStatus = {
            await LabellerCommandLineCheck.check(provider: $0)
        },
        makeKeySender: (@Sendable (AdLabellerProvider, any LabellerKeyStoring) throws -> any LabellerSending)? = nil
    ) {
        self.preferences = preferences
        self.keyStore = keyStore
        self.checkProvider = check
        self.makeKeySender = makeKeySender ?? { provider, keySlot in
            try LabellerSenderFactory.make(
                provider: provider,
                keyStore: keySlot,
                timeLimit: .seconds(15)
            )
        }
        let labeller = AdLabellerPreferences(preferences: preferences)
        self.typedModel = labeller.modelID(for: labeller.provider)
    }

    private var labeller: AdLabellerPreferences {
        AdLabellerPreferences(preferences: preferences)
    }

    // MARK: - Choice

    public var provider: AdLabellerProvider {
        _ = revision
        return labeller.provider
    }

    public func setProvider(_ newProvider: AdLabellerProvider) {
        labeller.provider = newProvider
        revision += 1
        typedModel = labeller.modelID(for: newProvider)
        typedModelMessage = nil
        levelMessage = nil
        keyMessage = nil
    }

    public var modelChoices: [AdLabellerModelCatalog.ModelInfo] {
        AdLabellerModelCatalog.modelsByProvider[provider] ?? []
    }

    public var model: String {
        _ = revision
        return labeller.modelID(for: provider)
    }

    public func setModel(_ newModel: String) {
        let trimmed = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        labeller.setModelID(trimmed, for: provider)
        revision += 1
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
        _ = revision
        return labeller.level(for: provider)
    }

    public func setLevel(_ newLevel: String) {
        let choices = levelChoices
        guard choices.contains(newLevel) else {
            levelMessage = "This model does not support that thinking level."
            return
        }
        levelMessage = nil
        labeller.setLevel(newLevel, for: provider)
        revision += 1
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
        _ = revision
        return Self.rowOrder.map { row(for: $0) }
    }

    private func row(for targetProvider: AdLabellerProvider) -> Row {
        let kind = targetProvider.requiresSavedKey ? "Key" : "Command-line tool"
        let hasSaved = targetProvider.requiresSavedKey ? keyStore.savedKeyPresent(for: targetProvider) : false
        let isChosen = targetProvider == provider

        let statusText: String
        if targetProvider.requiresSavedKey {
            if !hasSaved {
                if case .noKeySet? = keyProviderStatuses[targetProvider] {
                    statusText = "No key set"
                } else {
                    statusText = "No key saved"
                }
            } else if runningChecks.contains(targetProvider) {
                statusText = "Checking..."
            } else {
                if case .noKeySet? = keyProviderStatuses[targetProvider] {
                    statusText = "Ready"
                } else {
                    statusText = keyProviderStatuses[targetProvider]?.text ?? "Ready"
                }
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
            keyProviderStatuses.removeValue(forKey: provider)
            keyStatusGenerations[provider, default: 0] += 1
            revision += 1
        } catch {
            keyMessage = "The key could not be saved."
        }
    }

    public func removeKey(for provider: AdLabellerProvider) {
        try? keyStore.slot(for: provider).remove()
        keyProviderStatuses.removeValue(forKey: provider)
        keyStatusGenerations[provider, default: 0] += 1
        revision += 1
    }

    public func check(_ provider: AdLabellerProvider) async {
        guard !runningChecks.contains(provider) else { return }

        if provider.requiresSavedKey {
            guard keyStore.savedKeyPresent(for: provider) else {
                keyProviderStatuses[provider] = .noKeySet
                revision += 1
                return
            }
            let keyGeneration = keyStatusGenerations[provider, default: 0]
            runningChecks.insert(provider)
            revision += 1
            defer {
                runningChecks.remove(provider)
                revision += 1
            }
            let status: KeyProviderStatus
            do {
                let sender = try makeKeySender(provider, keyStore.slot(for: provider))
                _ = try await sender.send(
                    keyCheckRequest(for: provider),
                    onRequestStarted: {},
                    onProgress: { _ in }
                )
                status = .ready
            } catch let failure as LabellerFailure {
                status = failure == .keyRejected ? .rejected : .unreachable
            } catch {
                status = .unreachable
            }
            if keyGeneration == keyStatusGenerations[provider, default: 0],
               keyStore.savedKeyPresent(for: provider) {
                keyProviderStatuses[provider] = status
            }
            return
        }

        runningChecks.insert(provider)
        revision += 1
        defer { runningChecks.remove(provider) }

        let result = await checkProvider(provider)
        commandLineStatuses[provider] = result
        revision += 1
    }

    /// Checks each provider at once, so one press refreshes all seven statuses.
    public func checkAll() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in Self.rowOrder {
                group.addTask { await self.check(provider) }
            }
        }
    }

    /// Whether any provider check is still running.
    public var isCheckingAny: Bool { !runningChecks.isEmpty }

    private func keyCheckRequest(for provider: AdLabellerProvider) -> LabellerRequest {
        let configuredModel = labeller.modelID(for: provider)
        let model = configuredModel.isEmpty ? Self.keyCheckFallbackModel(for: provider) : configuredModel
        return LabellerRequest(
            prompt: "Reply OK.",
            modelID: model,
            reasoningLevel: "low",
            purpose: .providerCheck
        )
    }

    private static func keyCheckFallbackModel(for provider: AdLabellerProvider) -> String {
        switch provider {
        case .opencodeGoKey:
            return AdLabellerPreferences.defaultModelID
        case .openRouterKey:
            return "openai/gpt-4o-mini"
        case .openAIKey:
            return "gpt-4o-mini"
        case .anthropicKey:
            return AdLabellerModelCatalog.modelsByProvider[provider]?.first?.id ?? "claude-sonnet-5-5"
        case .openCodeCLI, .claudeCodeCLI, .codexCLI:
            return AdLabellerPreferences.defaultModelID
        }
    }

    // MARK: - Readiness Line

    public var readinessLine: String {
        _ = revision
        // Priority 1: No model chosen
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Type a model id."
        }

        // Priority 2: Key provider with no key
        if provider.requiresSavedKey && !keyStore.savedKeyPresent(for: provider) {
            return "No key saved. Add one in Providers."
        }

        // Priority 3: Command-line provider not found or not signed in per last check (if checked)
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

        // Priority 4: Ready
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
}
