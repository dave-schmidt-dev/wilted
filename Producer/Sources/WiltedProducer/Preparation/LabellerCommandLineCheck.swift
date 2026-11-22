import Foundation

/// The readiness status of a command-line labelling tool.
public enum LabellerCommandLineStatus: Equatable, Sendable {
    case notFound
    case notSignedIn
    case ready
    case failed(String)
}

/// Checks whether a command-line labelling provider is installed and ready to accept requests.
public enum LabellerCommandLineCheck {
    /// Returns the default executable URL for a command-line provider, or `nil` for key providers.
    public static func defaultExecutableURL(for provider: AdLabellerProvider) -> URL? {
        switch provider {
        case .openCodeCLI:
            return OpenCodeCLILabellerSender.defaultExecutableURL
        case .claudeCodeCLI:
            return ClaudeCodeCLILabellerSender.defaultExecutableURL
        case .codexCLI:
            return CodexCLILabellerSender.defaultExecutableURL
        case .opencodeGoKey, .openRouterKey, .openAIKey, .anthropicKey:
            return nil
        }
    }

    /// Whether the executable for `provider` is found at `executableURL`
    /// (defaulting to the provider's default executable URL). Always `false` for key providers.
    public static func found(provider: AdLabellerProvider, executableURL: URL? = nil) -> Bool {
        switch provider {
        case .openCodeCLI:
            let target = executableURL ?? OpenCodeCLILabellerSender.defaultExecutableURL
            return OpenCodeCLILabellerSender.isAvailable(executableURL: target)
        case .claudeCodeCLI:
            let target = executableURL ?? ClaudeCodeCLILabellerSender.defaultExecutableURL
            return ClaudeCodeCLILabellerSender.isAvailable(executableURL: target)
        case .codexCLI:
            let target = executableURL ?? CodexCLILabellerSender.defaultExecutableURL
            return CodexCLILabellerSender.isAvailable(executableURL: target)
        case .opencodeGoKey, .openRouterKey, .openAIKey, .anthropicKey:
            return false
        }
    }

    /// Checks the status of a command-line provider by sending a tiny test request.
    ///
    /// If the tool is not found, returns `.notFound`. Otherwise sends a prompt requesting "OK"
    /// with a 60-second limit and maps the outcome to `.ready`, `.notSignedIn`, or `.failed`.
    /// Does not touch any request counter, journal, or episode records.
    public static func check(
        provider: AdLabellerProvider,
        executableURL: URL? = nil,
        send: (any LabellerSending)? = nil
    ) async -> LabellerCommandLineStatus {
        if let send {
            if let executableURL, !found(provider: provider, executableURL: executableURL) {
                return .notFound
            }
            if provider.requiresSavedKey {
                return .notFound
            }
            return await runCheck(provider: provider, sender: send)
        } else {
            guard found(provider: provider, executableURL: executableURL) else {
                return .notFound
            }
            let sender: any LabellerSending
            do {
                sender = try LabellerSenderFactory.make(
                    provider: provider,
                    keyStore: nil,
                    timeLimit: .seconds(60)
                )
            } catch {
                return .notFound
            }
            return await runCheck(provider: provider, sender: sender)
        }
    }

    private static func runCheck(
        provider: AdLabellerProvider,
        sender: any LabellerSending
    ) async -> LabellerCommandLineStatus {
        let catalogModels = AdLabellerModelCatalog.modelsByProvider[provider] ?? []
        let modelInfo = catalogModels.first
        let modelID = modelInfo?.id ?? AdLabellerPreferences.defaultModelID
        let level = modelInfo?.supportedLevels.first ?? AdLabellerPreferences.defaultLevel

        let request = LabellerRequest(
            prompt: "Reply with the single word OK.",
            modelID: modelID,
            reasoningLevel: level
        )

        do {
            _ = try await withThrowingTaskGroup(of: LabellerResponse.self) { group in
                group.addTask {
                    try await sender.send(
                        request,
                        onRequestStarted: {},
                        onProgress: { _ in }
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    throw LabellerFailure.temporary
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw LabellerFailure.temporary
                }
                return first
            }
            return .ready
        } catch let failure as LabellerFailure {
            switch failure {
            case .keyRejected:
                return .notSignedIn
            case .commandLineToolUnavailable:
                return .notFound
            default:
                return .failed(failure.reasonSentence)
            }
        } catch is LabellerCommandLineRefusal {
            return .notFound
        } catch is CancellationError {
            return .failed("The check was cancelled.")
        } catch {
            let message = error.localizedDescription
            let lower = message.lowercased()
            if lower.contains("not signed in") || lower.contains("notsignedin") || lower.contains("sign in") {
                return .notSignedIn
            }
            return .failed(message)
        }
    }
}
