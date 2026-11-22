import Foundation
import XCTest
import WiltedProducer
@testable import WiltedMac

private final class MockCheckBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [AdLabellerProvider] = []
    private var _statusToReturn: [AdLabellerProvider: LabellerCommandLineStatus] = [:]
    private var _delayNanoseconds: UInt64 = 0

    func setStatus(_ status: LabellerCommandLineStatus, for provider: AdLabellerProvider) {
        lock.withLock { _statusToReturn[provider] = status }
    }

    func setDelay(nanoseconds: UInt64) {
        lock.withLock { _delayNanoseconds = nanoseconds }
    }

    var invocations: [AdLabellerProvider] {
        lock.withLock { _invocations }
    }

    var invocationCount: Int {
        lock.withLock { _invocations.count }
    }

    func check(provider: AdLabellerProvider) async -> LabellerCommandLineStatus {
        let delay: UInt64 = lock.withLock {
            _invocations.append(provider)
            return _delayNanoseconds
        }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        return lock.withLock { _statusToReturn[provider] ?? .ready }
    }
}

@MainActor
final class WiltedMacProviderSettingsTests: XCTestCase {

    private func makeSettings(
        initialKeys: [AdLabellerProvider: String] = [:]
    ) -> (settings: WiltedMacProviderSettings, preferences: UserDefaults, keyStore: ActiveProviderKeyStore, mockCheck: MockCheckBox) {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let labellerPrefs = AdLabellerPreferences(preferences: preferences)
        let keyStore = ActiveProviderKeyStore.inMemory(preferences: labellerPrefs, initialKeys: initialKeys)
        let mockCheck = MockCheckBox()
        let settings = WiltedMacProviderSettings(
            preferences: preferences,
            keyStore: keyStore,
            check: { await mockCheck.check(provider: $0) }
        )
        return (settings, preferences, keyStore, mockCheck)
    }

    // MARK: - Fresh State

    func testFreshStateEqualsTodayChoice() {
        let (settings, _, _, _) = makeSettings()

        XCTAssertEqual(settings.provider, .opencodeGoKey)
        XCTAssertEqual(settings.model, "deepseek-v4.1-flash")
        XCTAssertEqual(settings.level, "low")
        XCTAssertFalse(settings.usesTypedModel)
        XCTAssertEqual(settings.modelChoices.map(\.id), ["deepseek-v4.1-flash", "deepseek-v4-pro"])
        XCTAssertEqual(settings.levelChoices, ["default", "low", "high", "max"])
        XCTAssertEqual(settings.levelLabel(settings.level), "Low")

        let expectedOrder: [AdLabellerProvider] = [
            .openCodeCLI,
            .claudeCodeCLI,
            .codexCLI,
            .opencodeGoKey,
            .openRouterKey,
            .openAIKey,
            .anthropicKey,
        ]
        XCTAssertEqual(settings.rows.map(\.id), expectedOrder)
        XCTAssertEqual(settings.rows.first(where: { $0.id == .opencodeGoKey })?.isChosen, true)
        for row in settings.rows where row.id != .opencodeGoKey {
            XCTAssertFalse(row.isChosen, "\(row.id) should not be chosen")
        }
    }

    // MARK: - Provider Switching

    func testProviderSwitchKeepsEachProviderOwnModelAndLevel() {
        let (settings, _, _, _) = makeSettings()

        // 1. OpenCode Go Key: customize model & level
        settings.setModel("deepseek-v4-pro")
        settings.setLevel("high")
        XCTAssertEqual(settings.model, "deepseek-v4-pro")
        XCTAssertEqual(settings.level, "high")

        // 2. Switch to Claude Code CLI
        settings.setProvider(.claudeCodeCLI)
        XCTAssertEqual(settings.provider, .claudeCodeCLI)
        XCTAssertEqual(settings.model, "claude-sonnet-5-5")
        XCTAssertEqual(settings.level, "low")
        settings.setModel("claude-opus-5-5")
        settings.setLevel("max")
        XCTAssertEqual(settings.model, "claude-opus-5-5")
        XCTAssertEqual(settings.level, "max")

        // 3. Switch to Codex CLI
        settings.setProvider(.codexCLI)
        XCTAssertEqual(settings.provider, .codexCLI)
        XCTAssertEqual(settings.model, "gpt-6.1-terra")
        XCTAssertEqual(settings.level, "low")
        settings.setLevel("xhigh")
        XCTAssertEqual(settings.level, "xhigh")

        // 4. Switch back to OpenCode Go Key
        settings.setProvider(.opencodeGoKey)
        XCTAssertEqual(settings.model, "deepseek-v4-pro")
        XCTAssertEqual(settings.level, "high")

        // 5. Switch back to Claude Code CLI
        settings.setProvider(.claudeCodeCLI)
        XCTAssertEqual(settings.model, "claude-opus-5-5")
        XCTAssertEqual(settings.level, "max")

        // 6. Switch back to Codex CLI
        settings.setProvider(.codexCLI)
        XCTAssertEqual(settings.model, "gpt-6.1-terra")
        XCTAssertEqual(settings.level, "xhigh")
    }

    // MARK: - Unsupported Level Refused

    func testUnsupportedLevelRefused() {
        let (settings, _, _, _) = makeSettings()
        settings.setProvider(.openCodeCLI)
        XCTAssertEqual(settings.model, "deepseek-v4.1-flash")
        XCTAssertEqual(settings.level, "low")
        XCTAssertNil(settings.levelMessage)

        // "medium" is not in deepseek-v4.1-flash's supported levels: ["default", "low", "high", "max"]
        settings.setLevel("medium")
        XCTAssertEqual(settings.level, "low", "Level must remain unchanged when unsupported")
        XCTAssertNotNil(settings.levelMessage)

        // Valid level clears the message and updates
        settings.setLevel("high")
        XCTAssertEqual(settings.level, "high")
        XCTAssertNil(settings.levelMessage)
    }

    // MARK: - Level Moves When Model Changes

    func testLevelMovesWhenModelChanges() {
        let (settings, _, _, _) = makeSettings()
        settings.setProvider(.claudeCodeCLI)
        XCTAssertEqual(settings.model, "claude-sonnet-5-5")

        // Claude Sonnet supports ["low", "medium", "high", "xhigh", "max"]
        settings.setLevel("xhigh")
        XCTAssertEqual(settings.level, "xhigh")

        // Claude Haiku supports ["low", "medium", "high"] (no xhigh or max)
        settings.setModel("claude-haiku-5-5")
        XCTAssertEqual(settings.model, "claude-haiku-5-5")
        XCTAssertEqual(settings.level, "low", "Should move to 'low' because xhigh is unsupported by Haiku")

        // When new model supports current level, it stays
        settings.setLevel("medium")
        settings.setModel("claude-sonnet-5-5")
        XCTAssertEqual(settings.level, "medium", "Medium is supported by Sonnet, so it should stay")
    }

    // MARK: - Typed Model for OpenAI and OpenRouter

    func testTypedModelForOpenAIAndOpenRouterBlankRefused() {
        let (settings, _, _, _) = makeSettings()

        // 1. OpenRouter
        settings.setProvider(.openRouterKey)
        XCTAssertTrue(settings.usesTypedModel)
        XCTAssertEqual(settings.modelChoices.count, 0)
        XCTAssertEqual(settings.model, "")

        // Blank typed model refused
        settings.typedModel = "   \n  "
        settings.saveTypedModel()
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(settings.typedModelMessage, "Enter a model id first.")

        // Valid typed model saved
        settings.typedModel = "  anthropic/claude-3.5-sonnet  "
        settings.saveTypedModel()
        XCTAssertEqual(settings.model, "anthropic/claude-3.5-sonnet")
        XCTAssertEqual(settings.typedModel, "anthropic/claude-3.5-sonnet")
        XCTAssertNil(settings.typedModelMessage)
        XCTAssertEqual(settings.levelChoices, ["low", "medium", "high"])

        // 2. OpenAI
        settings.setProvider(.openAIKey)
        XCTAssertTrue(settings.usesTypedModel)
        XCTAssertEqual(settings.modelChoices.count, 0)
        XCTAssertEqual(settings.model, "")

        // Blank typed model refused
        settings.typedModel = ""
        settings.saveTypedModel()
        XCTAssertEqual(settings.model, "")
        XCTAssertNotNil(settings.typedModelMessage)

        // Valid model saved
        settings.typedModel = "gpt-4o"
        settings.saveTypedModel()
        XCTAssertEqual(settings.model, "gpt-4o")
        XCTAssertNil(settings.typedModelMessage)
    }

    // MARK: - Level Labels

    func testLevelLabelMappings() {
        let (settings, _, _, _) = makeSettings()

        XCTAssertEqual(settings.levelLabel("low"), "Low")
        XCTAssertEqual(settings.levelLabel("medium"), "Medium")
        XCTAssertEqual(settings.levelLabel("high"), "High")
        XCTAssertEqual(settings.levelLabel("xhigh"), "Extra high")
        XCTAssertEqual(settings.levelLabel("extra high"), "Extra high")
        XCTAssertEqual(settings.levelLabel("max"), "Max")
        XCTAssertEqual(settings.levelLabel("default"), "Default")
    }

    // MARK: - Row Status Across States

    func testRowStatusTextAcrossStates() async throws {
        let (settings, _, keyStore, mockCheck) = makeSettings()

        // Key provider initial states
        let openCodeGoRow = try XCTUnwrap(settings.rows.first(where: { $0.id == .opencodeGoKey }))
        XCTAssertEqual(openCodeGoRow.kind, "Key")
        XCTAssertEqual(openCodeGoRow.status, "No key saved")

        let anthropicRow = try XCTUnwrap(settings.rows.first(where: { $0.id == .anthropicKey }))
        XCTAssertEqual(anthropicRow.kind, "Key")
        XCTAssertEqual(anthropicRow.status, "No key saved")

        try? keyStore.slot(for: .anthropicKey).save("sk-ant-test")
        let anthropicReadyRow = try XCTUnwrap(settings.rows.first(where: { $0.id == .anthropicKey }))
        XCTAssertEqual(anthropicReadyRow.status, "Ready")

        try? keyStore.slot(for: .opencodeGoKey).save("sk-open-test")
        let openCodeGoReadyRow = try XCTUnwrap(settings.rows.first(where: { $0.id == .opencodeGoKey }))
        XCTAssertEqual(openCodeGoReadyRow.status, "Ready")

        // Command-line provider initial state
        let cliRowInitial = try XCTUnwrap(settings.rows.first(where: { $0.id == .openCodeCLI }))
        XCTAssertEqual(cliRowInitial.kind, "Command-line tool")
        XCTAssertEqual(cliRowInitial.status, "Not checked yet")

        // Mock check returning notFound
        mockCheck.setStatus(.notFound, for: .openCodeCLI)
        await settings.check(.openCodeCLI)
        let cliNotFoundRow = try XCTUnwrap(settings.rows.first(where: { $0.id == .openCodeCLI }))
        XCTAssertEqual(cliNotFoundRow.status, "Tool not found on this Mac")

        // Mock check returning notSignedIn
        mockCheck.setStatus(.notSignedIn, for: .claudeCodeCLI)
        await settings.check(.claudeCodeCLI)
        let cliNotSignedInRow = try XCTUnwrap(settings.rows.first(where: { $0.id == .claudeCodeCLI }))
        XCTAssertEqual(cliNotSignedInRow.status, "Not signed in")

        // Mock check returning ready
        mockCheck.setStatus(.ready, for: .codexCLI)
        await settings.check(.codexCLI)
        let cliReadyRow = try XCTUnwrap(settings.rows.first(where: { $0.id == .codexCLI }))
        XCTAssertEqual(cliReadyRow.status, "Ready")

        // Mock check returning failed sentence
        mockCheck.setStatus(.failed("Custom error description"), for: .openCodeCLI)
        await settings.check(.openCodeCLI)
        let cliFailedRow = try XCTUnwrap(settings.rows.first(where: { $0.id == .openCodeCLI }))
        XCTAssertEqual(cliFailedRow.status, "Custom error description")
    }

    // MARK: - Key Storage Safety

    func testSaveKeyNeverStoredInPreferencesAndTrimsRefusesBlank() {
        let (settings, preferences, keyStore, _) = makeSettings()

        // 1. Refuses blank
        settings.saveKey("   \t  ", for: .anthropicKey)
        XCTAssertEqual(settings.keyMessage, "Enter a provider key first.")
        XCTAssertFalse(keyStore.slot(for: .anthropicKey).hasKey())

        // 2. Saves trimmed key to keyStore
        let secretKey = "anthropic-secret-token-XYZ-789"
        settings.saveKey("  \(secretKey)  \n", for: .anthropicKey)
        XCTAssertNil(settings.keyMessage)
        XCTAssertTrue(keyStore.slot(for: .anthropicKey).hasKey())
        XCTAssertEqual(try? keyStore.slot(for: .anthropicKey).read(), secretKey)

        // 3. Assert UserDefaults dictionary has no value equal to the key
        let defaultsDict = preferences.dictionaryRepresentation()
        for (key, value) in defaultsDict {
            let valueString = String(describing: value)
            XCTAssertFalse(valueString.contains(secretKey), "Key appeared in preferences key '\(key)'!")
        }

        // 4. Remove key
        settings.removeKey(for: .anthropicKey)
        XCTAssertFalse(keyStore.slot(for: .anthropicKey).hasKey())
    }

    // MARK: - Check Constraints & Concurrency

    func testCheckRunsOnlyForCommandLineProvidersAndIgnoresConcurrentCall() async {
        let (settings, _, _, mockCheck) = makeSettings()

        // 1. Key providers are ignored
        await settings.check(.opencodeGoKey)
        await settings.check(.anthropicKey)
        await settings.check(.openRouterKey)
        await settings.check(.openAIKey)
        XCTAssertEqual(mockCheck.invocationCount, 0, "Check must never run for key providers")

        // 2. Command-line provider concurrency
        mockCheck.setDelay(nanoseconds: 100_000_000) // 100ms
        let task1 = Task {
            await settings.check(.openCodeCLI)
        }

        // Give task1 a moment to begin and set running state
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(settings.rows.first(where: { $0.id == .openCodeCLI })?.status, "Checking...")

        // Attempt second concurrent check for openCodeCLI
        await settings.check(.openCodeCLI)

        _ = await task1.value

        XCTAssertEqual(mockCheck.invocationCount, 1, "Concurrent check should have been ignored")
        XCTAssertEqual(settings.rows.first(where: { $0.id == .openCodeCLI })?.status, "Ready")
    }

    // MARK: - ReadinessLine Priority

    func testReadinessLinePriority() async {
        let (settings, _, keyStore, mockCheck) = makeSettings()

        // Priority 1: No model chosen
        settings.setProvider(.openRouterKey)
        XCTAssertEqual(settings.readinessLine, "Type a model id.")

        // Priority 2: Key provider with no key
        settings.setModel("anthropic/claude-3.5-sonnet")
        XCTAssertEqual(settings.readinessLine, "No key saved. Add one in Providers.")

        try? keyStore.slot(for: .openRouterKey).save("sk-openrouter-key")
        XCTAssertEqual(settings.readinessLine, "Ready: OpenRouter · anthropic/claude-3.5-sonnet · Low")

        // Priority 3: Command-line provider not found or not signed in per last check (if checked)
        settings.setProvider(.claudeCodeCLI)

        // Before check: falls through to Ready
        XCTAssertEqual(settings.readinessLine, "Ready: Claude Code · Claude Sonnet 5.5 · Low")

        // When checked and not found
        mockCheck.setStatus(.notFound, for: .claudeCodeCLI)
        await settings.check(.claudeCodeCLI)
        XCTAssertEqual(settings.readinessLine, "Tool not found on this Mac.")

        // When checked and not signed in
        mockCheck.setStatus(.notSignedIn, for: .claudeCodeCLI)
        await settings.check(.claudeCodeCLI)
        XCTAssertEqual(settings.readinessLine, "Not signed in.")

        // When checked and failed
        mockCheck.setStatus(.failed("Service timeout"), for: .claudeCodeCLI)
        await settings.check(.claudeCodeCLI)
        XCTAssertEqual(settings.readinessLine, "Service timeout")

        // When checked and ready -> Priority 4
        mockCheck.setStatus(.ready, for: .claudeCodeCLI)
        await settings.check(.claudeCodeCLI)
        XCTAssertEqual(settings.readinessLine, "Ready: Claude Code · Claude Sonnet 5.5 · Low")
    }
}
