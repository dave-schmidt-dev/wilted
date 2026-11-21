import Foundation

/// Online providers that can label advertising breaks.
public enum AdLabellerProvider: String, Codable, CaseIterable, Sendable {
    case opencodeGoKey
    case openCodeCLI
    case claudeCodeCLI
    case codexCLI
    case openRouterKey
    case openAIKey
    case anthropicKey

    /// Whether reaching this provider requires a saved key.
    public var requiresSavedKey: Bool {
        switch self {
        case .opencodeGoKey, .openRouterKey, .openAIKey, .anthropicKey:
            return true
        case .openCodeCLI, .claudeCodeCLI, .codexCLI:
            return false
        }
    }

    /// User-facing display name.
    public var displayName: String {
        switch self {
        case .opencodeGoKey: return "OpenCode Go (Key)"
        case .openCodeCLI: return "OpenCode"
        case .claudeCodeCLI: return "Claude Code"
        case .codexCLI: return "Codex"
        case .openRouterKey: return "OpenRouter"
        case .openAIKey: return "OpenAI"
        case .anthropicKey: return "Anthropic"
        }
    }
}

/// Known models and supported thinking levels per provider.
public struct AdLabellerModelCatalog: Sendable {
    /// A known model definition.
    public struct ModelInfo: Sendable {
        public let id: String
        public let displayName: String
        public let supportedLevels: [String]

        public init(id: String, displayName: String, supportedLevels: [String]) {
            self.id = id
            self.displayName = displayName
            self.supportedLevels = supportedLevels
        }
    }

    /// Known models by provider, checked against the models actually available on 2026-11-21.
    /// Any other model id may still be typed in; only listed models limit the thinking level.
    public static let modelsByProvider: [AdLabellerProvider: [ModelInfo]] = [
        .opencodeGoKey: deepSeekModels,
        .openCodeCLI: deepSeekModels,
        .claudeCodeCLI: claudeModels,
        .codexCLI: [
            ModelInfo(id: "gpt-6.1-terra", displayName: "GPT 6.1 Terra", supportedLevels: ["low", "medium", "high", "xhigh"]),
        ],
        .anthropicKey: claudeModels,
    ]

    private static let deepSeekModels = [
        ModelInfo(id: "deepseek-v4.1-flash", displayName: "DeepSeek V4.1 Flash", supportedLevels: ["default", "low", "high", "max"]),
        ModelInfo(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", supportedLevels: ["default", "low", "high", "max"]),
    ]

    private static let claudeModels = [
        ModelInfo(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", supportedLevels: ["low", "medium", "high", "xhigh", "max"]),
        ModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", supportedLevels: ["low", "medium", "high", "xhigh", "max"]),
        ModelInfo(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", supportedLevels: ["low", "medium", "high"]),
    ]

    /// Whether reaching this provider requires a saved key.
    public static func requiresSavedKey(provider: AdLabellerProvider) -> Bool {
        provider.requiresSavedKey
    }

    /// Validates whether a (provider, model, level) combination is allowed.
    ///
    /// For known models in the catalog, level must be one of its supported levels.
    /// For unknown custom model ids, any non-empty level is accepted.
    public static func isValid(provider: AdLabellerProvider, model: String, level: String) -> Bool {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !level.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let knownModels = modelsByProvider[provider] ?? []
        if let match = knownModels.first(where: { $0.id == model }) {
            return match.supportedLevels.contains(level)
        }
        // Unknown custom model id: accepted as long as level is non-empty.
        return true
    }
}

/// A typed refusal when a chosen command-line provider cannot be run.
public struct LabellerCommandLineRefusal: Equatable, Sendable, Error {
    public let provider: AdLabellerProvider

    public static func executableNotUsable(provider: AdLabellerProvider) -> LabellerCommandLineRefusal {
        LabellerCommandLineRefusal(provider: provider)
    }

    /// Plain reason sentence, without code words.
    public var reasonSentence: String {
        switch provider {
        case .openCodeCLI:
            return "The OpenCode command-line tool is not installed or not usable on this Mac."
        case .claudeCodeCLI:
            return "The Claude Code command-line tool is not installed or not usable on this Mac."
        case .codexCLI:
            return "The Codex command-line tool is not installed or not usable on this Mac."
        default:
            return "The command-line tool is not installed or not usable on this Mac."
        }
    }
}
