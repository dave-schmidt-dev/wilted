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
        public let lastCheckResult: String?
        public let isChosen: Bool

        public init(
            provider: AdLabellerProvider,
            name: String,
            kind: String,
            hasSavedKey: Bool,
            status: String,
            lastCheckResult: String?,
            isChosen: Bool
        ) {
            self.id = provider
            self.name = name
            self.kind = kind
            self.hasSavedKey = hasSavedKey
            self.status = status
            self.lastCheckResult = lastCheckResult
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
    private var statusGenerations: [AdLabellerProvider: Int] = [:]

    private struct StatusSummary {
        let readiness: String
        let lastCheckResult: String?
        let setupDetail: String?
    }

    private enum KeyProviderStatus: Equatable {
        case noKeySet
        case ready
        case rejected
        case unavailable
        case rateLimited
        case usageLimit
        case modelUnavailable
        case unusableAnswer
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
        if provider.requiresSavedKey {
            keyProviderStatuses.removeValue(forKey: provider)
        }
        statusGenerations[provider, default: 0] += 1

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
        statusGenerations[provider, default: 0] += 1
        if provider.requiresSavedKey {
            keyProviderStatuses.removeValue(forKey: provider)
        }
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

        let summary = statusSummary(for: targetProvider)

        return Row(
            provider: targetProvider,
            name: targetProvider.displayName,
            kind: kind,
            hasSavedKey: hasSaved,
            status: summary.readiness,
            lastCheckResult: summary.lastCheckResult,
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
            statusGenerations[provider, default: 0] += 1
            revision += 1
        } catch {
            keyMessage = "The key could not be saved."
        }
    }

    public func removeKey(for provider: AdLabellerProvider) {
        try? keyStore.slot(for: provider).remove()
        keyProviderStatuses.removeValue(forKey: provider)
        statusGenerations[provider, default: 0] += 1
        revision += 1
    }

    @discardableResult
    public func check(_ provider: AdLabellerProvider) async -> Bool {
        guard !runningChecks.contains(provider) else { return false }

        if provider.requiresSavedKey {
            guard keyStore.savedKeyPresent(for: provider) else {
                keyProviderStatuses[provider] = .noKeySet
                revision += 1
                return false
            }
        }
        guard keyStore.isReady(provider: provider) else {
            revision += 1
            return false
        }

        if provider.requiresSavedKey {
            let generation = statusGenerations[provider, default: 0]
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
                switch failure {
                case .keyRejected: status = .rejected
                case .temporary, .commandLineToolUnavailable: status = .unavailable
                case .rateLimited: status = .rateLimited
                case .usageLimit: status = .usageLimit
                case .modelUnavailable: status = .modelUnavailable
                case .unusableAnswer: status = .unusableAnswer
                }
            } catch {
                status = .unavailable
            }
            guard generation == statusGenerations[provider, default: 0],
                  keyStore.isReady(provider: provider) else { return false }
            keyProviderStatuses[provider] = status
            return status == .ready
        }

        runningChecks.insert(provider)
        revision += 1
        let generation = statusGenerations[provider, default: 0]
        defer {
            runningChecks.remove(provider)
            revision += 1
        }

        let result = await checkProvider(provider)
        guard generation == statusGenerations[provider, default: 0],
              keyStore.isReady(provider: provider) else { return false }
        commandLineStatuses[provider] = result
        return result == .ready
    }

    /// Checks each provider at once, so one press refreshes all seven statuses.
    public func checkAll() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in Self.rowOrder {
                group.addTask { _ = await self.check(provider) }
            }
        }
    }

    /// Whether any provider check is still running.
    public var isCheckingAny: Bool { !runningChecks.isEmpty }

    /// Whether a manual check is running for this provider.
    public func isChecking(_ provider: AdLabellerProvider) -> Bool {
        runningChecks.contains(provider)
    }

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
        let summary = statusSummary(for: provider)
        var line = "\(summary.readiness): \(provider.displayName)"
        if let setupDetail = summary.setupDetail {
            line += " · \(setupDetail)"
        } else if let lastCheckResult = summary.lastCheckResult {
            line += summary.readiness == "Ready"
                ? " · Last provider check passed"
                : " · Last provider check: \(lastCheckResult)"
        } else if summary.readiness == "Readiness unknown" {
            line += " · Check it in Providers"
        }
        return line + "."
    }

    private func statusSummary(for targetProvider: AdLabellerProvider) -> StatusSummary {
        if runningChecks.contains(targetProvider) {
            return StatusSummary(readiness: "Checking...", lastCheckResult: nil, setupDetail: nil)
        }
        guard keyStore.isReady(provider: targetProvider) else {
            let hasValidModel = AdLabellerModelCatalog.isValid(
                provider: targetProvider,
                model: labeller.modelID(for: targetProvider),
                level: labeller.level(for: targetProvider)
            )
            let detail = hasValidModel ? "No key saved" : "Choose a valid model and thinking level"
            return StatusSummary(readiness: "Not ready", lastCheckResult: nil, setupDetail: detail)
        }
        if targetProvider.requiresSavedKey {
            switch keyProviderStatuses[targetProvider] {
            case .ready?:
                return StatusSummary(readiness: "Ready", lastCheckResult: "Passed", setupDetail: nil)
            case .rejected?:
                return StatusSummary(readiness: "Not ready", lastCheckResult: "Key rejected", setupDetail: nil)
            case .unavailable?:
                return StatusSummary(readiness: "Not ready", lastCheckResult: "Service unavailable", setupDetail: nil)
            case .rateLimited?:
                return StatusSummary(readiness: "Not ready", lastCheckResult: "Too many requests", setupDetail: nil)
            case .usageLimit?:
                return StatusSummary(readiness: "Not ready", lastCheckResult: "Provider usage limit", setupDetail: nil)
            case .modelUnavailable?:
                return StatusSummary(readiness: "Not ready", lastCheckResult: "Model unavailable", setupDetail: nil)
            case .unusableAnswer?:
                return StatusSummary(readiness: "Not ready", lastCheckResult: "No usable response", setupDetail: nil)
            case .noKeySet?, nil:
                return StatusSummary(readiness: "Readiness unknown", lastCheckResult: nil, setupDetail: nil)
            }
        }
        guard let checkStatus = commandLineStatuses[targetProvider] else {
            return StatusSummary(readiness: "Readiness unknown", lastCheckResult: nil, setupDetail: nil)
        }
        switch checkStatus {
        case .notFound:
            return StatusSummary(readiness: "Not ready", lastCheckResult: "Tool not found on this Mac", setupDetail: nil)
        case .notSignedIn:
            return StatusSummary(readiness: "Not ready", lastCheckResult: "Not signed in", setupDetail: nil)
        case .ready:
            return StatusSummary(readiness: "Ready", lastCheckResult: "Passed", setupDetail: nil)
        case .failed(let message):
            return StatusSummary(readiness: "Not ready", lastCheckResult: message, setupDetail: nil)
        }
    }

    // MARK: - Private Helpers

    private func supportedLevels(for modelID: String, provider: AdLabellerProvider) -> [String] {
        if let match = AdLabellerModelCatalog.modelsByProvider[provider]?.first(where: { $0.id == modelID }) {
            return match.supportedLevels
        }
        return ["low", "medium", "high"]
    }
}
