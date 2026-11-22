import Foundation
import Testing
@testable import WiltedProducer

@Suite("Labeller sender factory")
struct LabellerSenderFactoryTests {
    @Test func factoryReturnsRightSenderTypeForEveryProvider() throws {
        let keyStore = InMemoryLabellerKeyStore(key: "test-key")
        let tempHome = URL(fileURLWithPath: "/tmp/wilted-test-home")

        let alwaysAvailable: @Sendable (AdLabellerProvider) -> Bool = { _ in true }

        // Key providers
        let openCodeGo = try LabellerSenderFactory.make(
            provider: .opencodeGoKey,
            keyStore: keyStore
        )
        #expect(openCodeGo is LabellerClient)

        let openRouter = try LabellerSenderFactory.make(
            provider: .openRouterKey,
            keyStore: keyStore
        )
        let openRouterSender = try #require(openRouter as? OpenAIStyleLabellerSender)
        #expect(openRouterSender.target == .openRouter)

        let openAI = try LabellerSenderFactory.make(
            provider: .openAIKey,
            keyStore: keyStore
        )
        let openAISender = try #require(openAI as? OpenAIStyleLabellerSender)
        #expect(openAISender.target == .openAI)

        let anthropic = try LabellerSenderFactory.make(
            provider: .anthropicKey,
            keyStore: keyStore
        )
        #expect(anthropic is AnthropicMessagesLabellerSender)

        // CLI providers when available
        let openCodeCLI = try LabellerSenderFactory.make(
            provider: .openCodeCLI,
            homeDirectory: tempHome,
            isExecutableAvailable: alwaysAvailable
        )
        #expect(openCodeCLI is OpenCodeCLILabellerSender)

        let claudeCLI = try LabellerSenderFactory.make(
            provider: .claudeCodeCLI,
            homeDirectory: tempHome,
            isExecutableAvailable: alwaysAvailable
        )
        #expect(claudeCLI is ClaudeCodeCLILabellerSender)

        let codexCLI = try LabellerSenderFactory.make(
            provider: .codexCLI,
            homeDirectory: tempHome,
            isExecutableAvailable: alwaysAvailable
        )
        #expect(codexCLI is CodexCLILabellerSender)
    }

    @Test func factoryNeverFallsBackWhenCommandLineToolIsMissing() {
        let neverAvailable: @Sendable (AdLabellerProvider) -> Bool = { _ in false }

        #expect(throws: LabellerCommandLineRefusal(provider: .openCodeCLI)) {
            try LabellerSenderFactory.make(
                provider: .openCodeCLI,
                isExecutableAvailable: neverAvailable
            )
        }

        #expect(throws: LabellerCommandLineRefusal(provider: .claudeCodeCLI)) {
            try LabellerSenderFactory.make(
                provider: .claudeCodeCLI,
                isExecutableAvailable: neverAvailable
            )
        }

        #expect(throws: LabellerCommandLineRefusal(provider: .codexCLI)) {
            try LabellerSenderFactory.make(
                provider: .codexCLI,
                isExecutableAvailable: neverAvailable
            )
        }
    }
}
