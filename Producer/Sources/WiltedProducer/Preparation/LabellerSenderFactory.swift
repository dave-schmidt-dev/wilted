import Foundation

/// A single pure factory that returns the right sender for any ``AdLabellerProvider``,
/// or the typed refusal from ``AdLabellerProviderChoices`` when a command-line tool is missing.
///
/// It must never fall back to a different provider.
public enum LabellerSenderFactory {
    /// Creates a sender for the given provider.
    ///
    /// - Parameters:
    ///   - provider: The chosen labelling provider.
    ///   - keyStore: The key store to use for key-based providers. Defaults to `KeychainLabellerKeyStore(provider: provider)`.
    ///   - homeDirectory: Private home directory for command-line tools.
    ///   - realHomeDirectory: Real home directory for command-line tools.
    ///   - configuration: URLSession configuration for network requests.
    ///   - timeLimit: Time limit for requests.
    ///   - isExecutableAvailable: Pure availability check for command-line tools (injected for tests).
    /// - Returns: A sender conforming to ``LabellerSending``.
    /// - Throws: ``LabellerCommandLineRefusal`` if a command-line provider tool is missing or not usable.
    public static func make(
        provider: AdLabellerProvider,
        keyStore: (any LabellerKeyStoring)? = nil,
        homeDirectory: URL? = nil,
        realHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        configuration: URLSessionConfiguration = .ephemeral,
        timeLimit: Duration = .seconds(900),
        isExecutableAvailable: (@Sendable (AdLabellerProvider) -> Bool)? = nil
    ) throws(LabellerCommandLineRefusal) -> any LabellerSending {
        switch provider {
        case .opencodeGoKey:
            let resolvedKeyStore = keyStore ?? KeychainLabellerKeyStore(provider: .opencodeGoKey)
            return LabellerClient(
                keyStore: resolvedKeyStore,
                configuration: configuration,
                timeLimit: timeLimit
            )

        case .openRouterKey:
            let resolvedKeyStore = keyStore ?? KeychainLabellerKeyStore(provider: .openRouterKey)
            return OpenAIStyleLabellerSender(
                target: .openRouter,
                keyStore: resolvedKeyStore,
                configuration: configuration,
                timeLimit: timeLimit
            )

        case .openAIKey:
            let resolvedKeyStore = keyStore ?? KeychainLabellerKeyStore(provider: .openAIKey)
            return OpenAIStyleLabellerSender(
                target: .openAI,
                keyStore: resolvedKeyStore,
                configuration: configuration,
                timeLimit: timeLimit
            )

        case .anthropicKey:
            let resolvedKeyStore = keyStore ?? KeychainLabellerKeyStore(provider: .anthropicKey)
            return AnthropicMessagesLabellerSender(
                keyStore: resolvedKeyStore,
                configuration: configuration,
                timeLimit: timeLimit
            )

        case .openCodeCLI:
            let available = isExecutableAvailable?(provider) ?? OpenCodeCLILabellerSender.isAvailable()
            guard available else {
                throw LabellerCommandLineRefusal.executableNotUsable(provider: .openCodeCLI)
            }
            let home = homeDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("wilted-opencode-cli")
            return OpenCodeCLILabellerSender(
                homeDirectory: home,
                realHomeDirectory: realHomeDirectory,
                timeLimit: timeLimit
            )

        case .claudeCodeCLI:
            let available = isExecutableAvailable?(provider) ?? ClaudeCodeCLILabellerSender.isAvailable()
            guard available else {
                throw LabellerCommandLineRefusal.executableNotUsable(provider: .claudeCodeCLI)
            }
            let home = homeDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("wilted-claude-cli")
            return ClaudeCodeCLILabellerSender(
                homeDirectory: home,
                realHomeDirectory: realHomeDirectory,
                timeLimit: timeLimit
            )

        case .codexCLI:
            let available = isExecutableAvailable?(provider) ?? CodexCLILabellerSender.isAvailable()
            guard available else {
                throw LabellerCommandLineRefusal.executableNotUsable(provider: .codexCLI)
            }
            let home = homeDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("wilted-codex-cli")
            return CodexCLILabellerSender(
                homeDirectory: home,
                realHomeDirectory: realHomeDirectory,
                timeLimit: timeLimit
            )
        }
    }
}
