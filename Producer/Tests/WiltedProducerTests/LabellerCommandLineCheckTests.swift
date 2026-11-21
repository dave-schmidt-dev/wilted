import Foundation
import Testing
@testable import WiltedProducer

@Suite("Labeller command-line tool check")
struct LabellerCommandLineCheckTests {
    private final class MockSender: LabellerSending, @unchecked Sendable {
        let outcome: Result<LabellerResponse, any Error>
        private let lock = NSLock()
        private var _lastRequest: LabellerRequest?
        private var _sendCount = 0

        init(outcome: Result<LabellerResponse, any Error>) {
            self.outcome = outcome
        }

        init(response: LabellerResponse) {
            self.outcome = .success(response)
        }

        init(error: any Error) {
            self.outcome = .failure(error)
        }

        var lastRequest: LabellerRequest? {
            lock.withLock { _lastRequest }
        }

        var sendCount: Int {
            lock.withLock { _sendCount }
        }

        func send(
            _ request: LabellerRequest,
            onRequestStarted: @escaping @Sendable () -> Void,
            onProgress: @escaping @Sendable (LabellerProgress) -> Void
        ) async throws -> LabellerResponse {
            lock.withLock {
                _sendCount += 1
                _lastRequest = request
            }
            onRequestStarted()
            switch outcome {
            case .success(let response):
                return response
            case .failure(let error):
                throw error
            }
        }
    }

    @Test func foundTruthTableAcrossProviders() {
        let keyProviders: [AdLabellerProvider] = [.opencodeGoKey, .openRouterKey, .openAIKey, .anthropicKey]
        let cliProviders: [AdLabellerProvider] = [.openCodeCLI, .claudeCodeCLI, .codexCLI]

        // Key providers always return false, even when an executable file is passed
        let existingBinary = URL(fileURLWithPath: "/bin/sh")
        for provider in keyProviders {
            #expect(!LabellerCommandLineCheck.found(provider: provider))
            #expect(!LabellerCommandLineCheck.found(provider: provider, executableURL: existingBinary))
            #expect(LabellerCommandLineCheck.defaultExecutableURL(for: provider) == nil)
        }

        // CLI providers with explicit URLs
        let nonExistentBinary = URL(fileURLWithPath: "/nonexistent/tool-\(UUID().uuidString)")
        for provider in cliProviders {
            #expect(LabellerCommandLineCheck.found(provider: provider, executableURL: existingBinary))
            #expect(!LabellerCommandLineCheck.found(provider: provider, executableURL: nonExistentBinary))
            #expect(LabellerCommandLineCheck.defaultExecutableURL(for: provider) != nil)
        }

        #expect(LabellerCommandLineCheck.defaultExecutableURL(for: .openCodeCLI) == OpenCodeCLILabellerSender.defaultExecutableURL)
        #expect(LabellerCommandLineCheck.defaultExecutableURL(for: .claudeCodeCLI) == ClaudeCodeCLILabellerSender.defaultExecutableURL)
        #expect(LabellerCommandLineCheck.defaultExecutableURL(for: .codexCLI) == CodexCLILabellerSender.defaultExecutableURL)
    }

    @Test func checkMappingWithFakeSenderReady() async {
        let fake = MockSender(response: LabellerResponse(text: "OK", usage: LabellerUsage()))
        let status = await LabellerCommandLineCheck.check(provider: .openCodeCLI, send: fake)

        #expect(status == .ready)
        #expect(fake.sendCount == 1)
        #expect(fake.lastRequest?.prompt == "Reply with the single word OK.")
        #expect(fake.lastRequest?.modelID == "deepseek-v4.1-flash")
        #expect(fake.lastRequest?.reasoningLevel == "default")
    }

    @Test func checkMappingWithFakeSenderKeyRejected() async {
        let fake = MockSender(error: LabellerFailure.keyRejected)
        let status = await LabellerCommandLineCheck.check(provider: .claudeCodeCLI, send: fake)

        #expect(status == .notSignedIn)
        #expect(fake.sendCount == 1)
        #expect(fake.lastRequest?.prompt == "Reply with the single word OK.")
        #expect(fake.lastRequest?.modelID == "claude-sonnet-5-5")
        #expect(fake.lastRequest?.reasoningLevel == "low")
    }

    @Test func checkMappingWithFakeSenderOtherFailures() async {
        // Model unavailable
        let fakeModel = MockSender(error: LabellerFailure.modelUnavailable)
        let statusModel = await LabellerCommandLineCheck.check(provider: .codexCLI, send: fakeModel)
        #expect(statusModel == .failed("The requested model is unavailable."))
        #expect(fakeModel.lastRequest?.modelID == "gpt-6.1-terra")
        #expect(fakeModel.lastRequest?.reasoningLevel == "low")

        // Temporary failure
        let fakeTemp = MockSender(error: LabellerFailure.temporary)
        let statusTemp = await LabellerCommandLineCheck.check(provider: .openCodeCLI, send: fakeTemp)
        #expect(statusTemp == .failed("A temporary problem prevented finding ads."))

        // Usage limit failure
        let fakeUsage = MockSender(error: LabellerFailure.usageLimit)
        let statusUsage = await LabellerCommandLineCheck.check(provider: .openCodeCLI, send: fakeUsage)
        #expect(statusUsage == .failed("The provider usage limit has been reached."))

        // Rate limited failure
        let fakeRate = MockSender(error: LabellerFailure.rateLimited(retryAfter: nil))
        let statusRate = await LabellerCommandLineCheck.check(provider: .openCodeCLI, send: fakeRate)
        #expect(statusRate == .failed("The provider is temporarily rate limited."))
    }

    @Test func checkMappingWithFakeSenderNotFound() async {
        // 1. Fake sender throwing commandLineToolUnavailable
        let fakeUnavailable = MockSender(error: LabellerFailure.commandLineToolUnavailable(provider: .openCodeCLI))
        let statusUnavailable = await LabellerCommandLineCheck.check(provider: .openCodeCLI, send: fakeUnavailable)
        #expect(statusUnavailable == .notFound)

        // 2. Passing a non-existent explicit executable URL
        let fake = MockSender(response: LabellerResponse(text: "OK", usage: LabellerUsage()))
        let nonExistentBinary = URL(fileURLWithPath: "/nonexistent/path/tool-\(UUID().uuidString)")
        let statusNonExistent = await LabellerCommandLineCheck.check(
            provider: .openCodeCLI,
            executableURL: nonExistentBinary,
            send: fake
        )
        #expect(statusNonExistent == .notFound)
        #expect(fake.sendCount == 0, "Fake sender must not be called when binary is not found")

        // 3. Passing a key provider (not a CLI provider)
        let statusKeyProvider = await LabellerCommandLineCheck.check(provider: .opencodeGoKey, send: fake)
        #expect(statusKeyProvider == .notFound)
        #expect(fake.sendCount == 0, "Key providers must not be called as CLI tools")
    }

    @Test func checkDoesNotTouchRequestCounterOrJournal() async {
        let suite = "test-counter-isolation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let counter = LabellerRequestCounter(preferences: defaults)
        #expect(counter.count == 0)

        let fake = MockSender(response: LabellerResponse(text: "OK", usage: LabellerUsage()))
        let status = await LabellerCommandLineCheck.check(provider: .openCodeCLI, send: fake)

        #expect(status == .ready)
        #expect(counter.count == 0, "Check must never record into the daily request counter")
    }
}
