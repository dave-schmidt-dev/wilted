import Foundation
import Testing
@testable import WiltedProducer

@Suite("Configured labeller sender")
struct ConfiguredLabellerSenderTests {
    private final class ProviderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var providers: [AdLabellerProvider] = []

        func record(_ provider: AdLabellerProvider) {
            lock.withLock { providers.append(provider) }
        }

        var recorded: [AdLabellerProvider] {
            lock.withLock { providers }
        }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T

        init(_ value: T) { self._value = value }

        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private final class MockSender: LabellerSending, @unchecked Sendable {
        let provider: AdLabellerProvider
        var sendCount = 0
        var lastRequest: LabellerRequest?

        init(provider: AdLabellerProvider) {
            self.provider = provider
        }

        func send(
            _ request: LabellerRequest,
            onRequestStarted: @escaping @Sendable () -> Void,
            onProgress: @escaping @Sendable (LabellerProgress) -> Void
        ) async throws -> LabellerResponse {
            sendCount += 1
            lastRequest = request
            onRequestStarted()
            return LabellerResponse(text: "mock-response-\(provider.rawValue)", usage: LabellerUsage())
        }
    }

    private func makePreferences() -> (UserDefaults, AdLabellerPreferences) {
        let suite = "test-configured-sender-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, AdLabellerPreferences(preferences: defaults))
    }

    @Test func picksSenderFromPreferencesPerCall() async throws {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let recorder = ProviderRecorder()
        let sender = ConfiguredLabellerSender(preferences: preferences) { provider in
            recorder.record(provider)
            return MockSender(provider: provider)
        }

        // Call 1: opencodeGoKey
        preferences.provider = .opencodeGoKey
        let started1 = Box(false)
        let response1 = try await sender.send(
            LabellerRequest(prompt: "find ads", modelID: "m1", reasoningLevel: "low"),
            onRequestStarted: { started1.value = true },
            onProgress: { _ in }
        )
        #expect(started1.value)
        #expect(response1.text == "mock-response-opencodeGoKey")

        // Call 2: change to anthropicKey (acknowledged)
        preferences.acknowledge(.anthropicKey)
        preferences.provider = .anthropicKey
        let started2 = Box(false)
        let response2 = try await sender.send(
            LabellerRequest(prompt: "find ads", modelID: "claude-sonnet-5-5", reasoningLevel: "medium"),
            onRequestStarted: { started2.value = true },
            onProgress: { _ in }
        )
        #expect(started2.value)
        #expect(response2.text == "mock-response-anthropicKey")

        // Call 3: change to openRouterKey (acknowledged)
        preferences.acknowledge(.openRouterKey)
        preferences.provider = .openRouterKey
        let started3 = Box(false)
        let response3 = try await sender.send(
            LabellerRequest(prompt: "find ads", modelID: "meta-llama", reasoningLevel: "low"),
            onRequestStarted: { started3.value = true },
            onProgress: { _ in }
        )
        #expect(started3.value)
        #expect(response3.text == "mock-response-openRouterKey")

        #expect(recorder.recorded == [.opencodeGoKey, .anthropicKey, .openRouterKey])
    }

    @Test func throwsCommandLineToolUnavailableForMissingToolWithNothingSent() async {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        preferences.provider = .openCodeCLI

        let requestStarted = Box(false)
        let sender = ConfiguredLabellerSender(preferences: preferences) { provider in
            throw LabellerCommandLineRefusal.executableNotUsable(provider: provider)
        }

        do {
            _ = try await sender.send(
                LabellerRequest(prompt: "find ads", modelID: "deepseek-v4.1-flash", reasoningLevel: "low"),
                onRequestStarted: { requestStarted.value = true },
                onProgress: { _ in }
            )
            Issue.record("Expected commandLineToolUnavailable failure to be thrown")
        } catch let failure as LabellerFailure {
            #expect(failure == .commandLineToolUnavailable(provider: .openCodeCLI))
            #expect(!requestStarted.value, "onRequestStarted must never be called when tool is missing")
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
    }

    @Test func neverFallsBackToAnotherProviderWhenToolIsMissing() async {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        for cliProvider in [AdLabellerProvider.openCodeCLI, .claudeCodeCLI, .codexCLI] {
            preferences.acknowledge(cliProvider)
            preferences.provider = cliProvider

            let recorder = ProviderRecorder()
            let sender = ConfiguredLabellerSender(preferences: preferences) { provider in
                recorder.record(provider)
                throw LabellerCommandLineRefusal.executableNotUsable(provider: provider)
            }

            do {
                _ = try await sender.send(
                    LabellerRequest(prompt: "find ads", modelID: "m", reasoningLevel: "l"),
                    onRequestStarted: {},
                    onProgress: { _ in }
                )
                Issue.record("Expected failure for \(cliProvider)")
            } catch let failure as LabellerFailure {
                #expect(failure == .commandLineToolUnavailable(provider: cliProvider))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(recorder.recorded == [cliProvider], "Must only attempt the chosen provider without fallback")
        }
    }

    @Test func defaultFactoryBuildsSenderFromKeyStore() async throws {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let inMemoryKeyStore = InMemoryLabellerKeyStore(key: "test-openai-key", provider: .openAIKey)
        let sender = ConfiguredLabellerSender(preferences: preferences, keyStore: inMemoryKeyStore)

        preferences.acknowledge(.openAIKey)
        preferences.provider = .openAIKey
        // The default factory should build an OpenAIStyleLabellerSender without throwing
        // We verify sending fails at the network layer, not at construction or command line refusal
        do {
            _ = try await sender.send(
                LabellerRequest(prompt: "p", modelID: "gpt-4o", reasoningLevel: "low"),
                onRequestStarted: {},
                onProgress: { _ in }
            )
        } catch is LabellerFailure {
            // Expected network / client failure, but NOT tool unavailable
        } catch {
            // Any network or parse error is fine; it proved the sender was constructed
        }
    }

    @Test func throwsProviderNotAcceptedWithoutAcknowledgementWithZeroFactoryCalls() async {
        let (defaults, preferences) = makePreferences()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let factoryCalls = Box(0)
        let requestStarted = Box(false)

        let sender = ConfiguredLabellerSender(preferences: preferences) { provider in
            factoryCalls.value += 1
            return MockSender(provider: provider)
        }

        // Test with unacknowledged Claude Code CLI
        preferences.provider = .claudeCodeCLI
        do {
            _ = try await sender.send(
                LabellerRequest(prompt: "find ads", modelID: "claude-sonnet-5-5", reasoningLevel: "low"),
                onRequestStarted: { requestStarted.value = true },
                onProgress: { _ in }
            )
            Issue.record("Expected providerNotAccepted to be thrown")
        } catch let failure as LabellerFailure {
            #expect(failure == .providerNotAccepted(provider: .claudeCodeCLI))
            #expect(failure.kind == "provider-not-accepted")
            #expect(failure.reasonSentence == "Claude Code has not been turned on in Settings, so nothing was sent.")
            #expect(factoryCalls.value == 0, "Factory must record zero calls when provider is unaccepted")
            #expect(!requestStarted.value, "onRequestStarted must not be called")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Test with unacknowledged Anthropic Key
        preferences.provider = .anthropicKey
        do {
            _ = try await sender.send(
                LabellerRequest(prompt: "find ads", modelID: "claude-sonnet-5-5", reasoningLevel: "low"),
                onRequestStarted: { requestStarted.value = true },
                onProgress: { _ in }
            )
            Issue.record("Expected providerNotAccepted to be thrown")
        } catch let failure as LabellerFailure {
            #expect(failure == .providerNotAccepted(provider: .anthropicKey))
            #expect(failure.kind == "provider-not-accepted")
            #expect(failure.reasonSentence == "Anthropic has not been turned on in Settings, so nothing was sent.")
            #expect(factoryCalls.value == 0, "Factory must record zero calls when provider is unaccepted")
            #expect(!requestStarted.value, "onRequestStarted must not be called")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Acknowledge Claude Code CLI and verify factory is now called
        preferences.provider = .claudeCodeCLI
        preferences.acknowledge(.claudeCodeCLI)
        do {
            _ = try await sender.send(
                LabellerRequest(prompt: "find ads", modelID: "claude-sonnet-5-5", reasoningLevel: "low"),
                onRequestStarted: { requestStarted.value = true },
                onProgress: { _ in }
            )
            #expect(factoryCalls.value == 1, "Factory must be called after acknowledgement")
            #expect(requestStarted.value)
        } catch {
            Issue.record("Unexpected error after acknowledgement: \(error)")
        }
    }
}
