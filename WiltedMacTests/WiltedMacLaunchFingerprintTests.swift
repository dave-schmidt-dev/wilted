import Foundation
import XCTest
import WiltedProducer
@testable import WiltedMac

private let launchDriftRule = PodcastPreparationInvalidationRule(
    id: "test.launch-drift", consequence: .resetPreparation, applies: { _ in true }
)

@MainActor
final class WiltedMacLaunchFingerprintTests: XCTestCase {
    func testEmptyRulesLaunchSkipsResolutionAndTheFingerprintReadoutStep() async throws {
        let directory = wiltedTemporaryDirectory("launch-fingerprint-empty")
        let resolver = LaunchFingerprintResolver(value: "must-not-resolve")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprintResolution: { await resolver.resolve() },
            invalidationRules: [],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        var steps: [WiltedMacStartupStep] = []
        model.startupStepObserverForTesting = { steps.append($0) }

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertNotNil(model.store, "the library still opens")
        let calls = await resolver.calls
        XCTAssertEqual(calls, 0, "an empty rule set must not hash the worker and Python trees")
        XCTAssertFalse(steps.contains(.checkingPreparationFingerprint),
                       "the readout must not name a wait that is not happening")
    }

    func testNonEmptyRulesEnterTheResolverAndHoldTheReadoutUntilReleased() async throws {
        let directory = wiltedTemporaryDirectory("launch-fingerprint-held")
        let released = FingerprintGate()
        defer { Task { await released.open() } }
        let resolver = LaunchFingerprintResolver(value: "resolved-launch", gate: released)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprintResolution: { await resolver.resolve() },
            invalidationRules: [launchDriftRule],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        var steps: [WiltedMacStartupStep] = []
        model.startupStepObserverForTesting = { steps.append($0) }
        model.startStoreBootstrap()

        try await awaitCondition { steps.contains(.checkingPreparationFingerprint) }
        let entered = await resolver.calls
        XCTAssertEqual(entered, 1, "a configured rule needs the fingerprint resolution")
        XCTAssertEqual(model.startupState.loadingStep, .checkingPreparationFingerprint)
        XCTAssertFalse(steps.contains(.closingInterruptedRuns),
                       "bootstrap must still be waiting on the fingerprint")

        await released.open()
        await model.waitForStoreBootstrap()
        let calls = await resolver.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.startupState, .ready)
    }

    func testNonEmptyRulesInvalidateOnceWithTheResolvedFingerprint() async throws {
        let directory = wiltedTemporaryDirectory("launch-fingerprint-invalidation")
        let released = FingerprintGate()
        defer { Task { await released.open() } }
        let resolver = LaunchFingerprintResolver(value: "resolved-launch", gate: released)
        let invalidated = FingerprintRecorder()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprintResolution: { await resolver.resolve() },
            staleInvalidationOverride: { _, fingerprint in
                await invalidated.record(fingerprint)
                return PodcastPreparationInvalidationResult()
            },
            invalidationRules: [launchDriftRule],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()

        try await awaitCondition { model.startupState.loadingStep == .checkingPreparationFingerprint }
        let beforeRelease = await invalidated.values
        XCTAssertEqual(beforeRelease, [], "invalidation ran before the fingerprint resolved")

        await released.open()
        await model.waitForStoreBootstrap()

        let afterRelease = await invalidated.values
        XCTAssertEqual(afterRelease, ["resolved-launch"],
                       "invalidation must see the resolved value, exactly once")
        XCTAssertEqual(model.startupState, .ready)
    }

    func testFailedResolutionNeverInvalidatesOrCarriesTheSentinel() async throws {
        let directory = wiltedTemporaryDirectory("launch-fingerprint-failed")
        let invalidated = FingerprintRecorder()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprintResolution: { nil },
            staleInvalidationOverride: { _, fingerprint in
                await invalidated.record(fingerprint)
                return PodcastPreparationInvalidationResult()
            },
            invalidationRules: [launchDriftRule],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let attempted = await invalidated.values
        XCTAssertEqual(attempted, [],
                       "a failed resolution must invalidate nothing, not compare the sentinel")
        XCTAssertEqual(model.startupState, .ready,
                       "an unresolved fingerprint is not a startup failure")
        XCTAssertNil(model.pipelineFingerprint, "startup must not forge a resolved value")
    }

    func testExplicitInvalidationOverrideStillResolvesWithEmptyRules() async throws {
        let directory = wiltedTemporaryDirectory("launch-fingerprint-override")
        let invalidated = FingerprintRecorder()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprintResolution: { "override-resolved" },
            staleInvalidationOverride: { _, fingerprint in
                await invalidated.record(fingerprint)
                return PodcastPreparationInvalidationResult()
            },
            invalidationRules: [],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        var steps: [WiltedMacStartupStep] = []
        model.startupStepObserverForTesting = { steps.append($0) }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertTrue(steps.contains(.checkingPreparationFingerprint),
                      "the explicit override keeps the resolution contract")
        let values = await invalidated.values
        XCTAssertEqual(values, ["override-resolved"])
        XCTAssertEqual(model.startupState, .ready)
    }

    func testEmptyRulesLaunchLeavesTheOriginalResolverForLaterRecovery() async throws {
        let directory = wiltedTemporaryDirectory("launch-fingerprint-later")
        let resolver = LaunchFingerprintResolver(value: "later-recovery")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            pipelineFingerprintResolution: { await resolver.resolve() },
            invalidationRules: [],
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let launchCalls = await resolver.calls
        XCTAssertEqual(launchCalls, 0)
        let resolved = await model.pipelineFingerprintResolution()
        _ = await model.pipelineFingerprintResolution()
        XCTAssertEqual(resolved, "later-recovery",
                       "a later recovery must still reach the original resolver")
        let laterCalls = await resolver.calls
        XCTAssertEqual(laterCalls, 2,
                       "the launch must neither replace nor memoize the shared resolver")
    }

    private func awaitCondition(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never held within \(timeout)s")
    }
}

private actor LaunchFingerprintResolver {
    private(set) var calls = 0
    private let value: String?
    private let gate: FingerprintGate?

    init(value: String?, gate: FingerprintGate? = nil) {
        self.value = value
        self.gate = gate
    }

    func resolve() async -> String? {
        calls += 1
        await gate?.wait()
        return value
    }
}
