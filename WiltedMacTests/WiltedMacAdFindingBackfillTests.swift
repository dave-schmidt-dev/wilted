import SwiftUI
import XCTest
import WiltedProducer
@testable import WiltedMac

/// The Ad finding card's label-only backfill row: when it appears, how the
/// model moves through checking and running, and the exact ending messages.
/// No Keychain, no preferences domain, and no network: the backfill closure
/// is injected.
@MainActor
final class WiltedMacAdFindingBackfillTests: XCTestCase {

    // MARK: Row visibility

    func testBackfillRowAbsentWithoutKeySwitchOrClosure() throws {
        let show = publicShow()
        let withClosureNoKey = makeModel(shows: { [show] }, backfill: immediate(.finished(recorded: 0)))
        XCTAssertFalse(withClosureNoKey.offersBackfill)
        XCTAssertFalse(try cardText(withClosureNoKey).contains("Prepared episodes"))

        let offline = makeReadyModel(shows: { [show] }, backfill: immediate(.finished(recorded: 0)))
        offline.setOnlineFinding(false)
        XCTAssertFalse(offline.offersBackfill)
        XCTAssertFalse(try cardText(offline).contains("Prepared episodes"))

        let noClosure = makeReadyModel(shows: { [show] }, backfill: nil)
        XCTAssertFalse(noClosure.offersBackfill)
        XCTAssertFalse(try cardText(noClosure).contains("Prepared episodes"))

        let ready = makeReadyModel(shows: { [show] }, backfill: immediate(.finished(recorded: 0)))
        XCTAssertTrue(ready.offersBackfill)
        XCTAssertTrue(try cardText(ready).contains("Prepared episodes"))
        XCTAssertTrue(try cardText(ready).contains("Label now"))
    }

    // MARK: Progress and endings

    func testStartBackfillMovesThroughCheckingRunningAndEachEndingMessage() async throws {
        let cases: [(LabellerBackfill.Summary?, String)] = [
            (summary(recorded: 3, failed: 0, remaining: 0, ending: .finished), "3 labelled"),
            (summary(recorded: 2, failed: 1, remaining: 0, ending: .finished), "2 labelled, 1 failed"),
            (summary(recorded: 0, failed: 0, remaining: 0, ending: .nothingToLabel), "Nothing to label right now"),
            (summary(recorded: 4, failed: 0, remaining: 2, ending: .cancelled), "Stopped. 4 labelled"),
            (summary(recorded: 1, failed: 0, remaining: 5, ending: .dailyCapReached),
             "Today's request limit is reached. 1 labelled, 5 left for tomorrow"),
            (summary(recorded: 1, failed: 0, remaining: 3, ending: .stopped(kind: "rate-limited")),
             "The provider is limiting requests. 1 labelled, 3 left"),
            (summary(recorded: 1, failed: 0, remaining: 3, ending: .stopped(kind: "key-rejected")),
             "The provider rejected the key. 1 labelled, 3 left"),
            (summary(recorded: 1, failed: 0, remaining: 3, ending: .stopped(kind: "model-unavailable")),
             "The provider's model is unavailable. 1 labelled, 3 left"),
            (summary(recorded: 1, failed: 0, remaining: 3, ending: .stopped(kind: "usage-limit")),
             "The provider's usage limit is reached. 1 labelled, 3 left"),
            (summary(recorded: 1, failed: 0, remaining: 3, ending: .stopped(kind: "transport")),
             "The provider could not be reached. 1 labelled, 3 left"),
            (summary(recorded: 0, failed: 0, remaining: 0, ending: .inactive),
             "Turn on online ad finding first"),
            (summary(recorded: 0, failed: 0, remaining: 0, ending: .unavailable),
             "The stored transcripts could not be read"),
            (nil, "The stored transcripts could not be read"),
        ]

        for (chosen, expected) in cases {
            let gate = HoldGate()
            let model = makeReadyModel(shows: { [self.publicShow()] }) { onProgress in
                onProgress(LabellerBackfill.Progress(done: 1, total: 5, recorded: 1, failed: 0))
                await gate.waitUntilReleased()
                return chosen
            }
            XCTAssertEqual(model.backfillState, .idle)
            model.startBackfill()
            XCTAssertEqual(model.backfillState, .checking)
            guard await (WiltedMacHeadless.eventually("backfill reaches running") {
                if case .running(let done, let total) = model.backfillState {
                    return done == 1 && total == 5
                }
                return false
            }) else { return }
            gate.release()
            guard await (WiltedMacHeadless.eventually("backfill ends with \(expected)") {
                model.backfillState == .ended(expected)
            }) else { return }
        }
    }

    func testSecondStartDuringRunDoesNotStartAnotherRun() async throws {
        let gate = HoldGate()
        var calls = 0
        let model = makeReadyModel(shows: { [self.publicShow()] }) { onProgress in
            calls += 1
            onProgress(LabellerBackfill.Progress(done: 0, total: 2, recorded: 0, failed: 0))
            await gate.waitUntilReleased()
            return self.summary(recorded: 0, failed: 0, remaining: 2, ending: .cancelled)
        }
        model.startBackfill()
        guard await (WiltedMacHeadless.eventually("first run is active") { calls == 1 }) else { return }
        XCTAssertTrue(model.isBackfilling)
        model.startBackfill()
        model.startBackfill()
        XCTAssertEqual(calls, 1, "a second start during a run must not call the closure again")
        gate.release()
        guard await (WiltedMacHeadless.eventually("first run ends") { !model.isBackfilling }) else { return }
        XCTAssertEqual(calls, 1)
    }

    func testStopBackfillCancelsTaskAndEndsStopped() async throws {
        let started = HoldGate()
        let model = makeReadyModel(shows: { [self.publicShow()] }) { onProgress in
            onProgress(LabellerBackfill.Progress(done: 2, total: 4, recorded: 2, failed: 0))
            started.release()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return self.summary(recorded: 2, failed: 0, remaining: 2, ending: .cancelled)
        }
        model.startBackfill()
        await started.waitUntilReleased()
        guard await (WiltedMacHeadless.eventually("running before stop") {
            if case .running = model.backfillState { return true }
            return false
        }) else { return }
        model.stopBackfill()
        guard await (WiltedMacHeadless.eventually("stopped message") {
            model.backfillState == .ended("Stopped. 2 labelled")
        }) else { return }
    }

    func testTurningSwitchOffDuringRunStopsBackfill() async throws {
        let started = HoldGate()
        let model = makeReadyModel(shows: { [self.publicShow()] }) { onProgress in
            onProgress(LabellerBackfill.Progress(done: 1, total: 3, recorded: 1, failed: 0))
            started.release()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return self.summary(recorded: 1, failed: 0, remaining: 2, ending: .cancelled)
        }
        model.startBackfill()
        await started.waitUntilReleased()
        guard await (WiltedMacHeadless.eventually("running before switch off") {
            model.isBackfilling
        }) else { return }
        model.setOnlineFinding(false)
        XCTAssertFalse(model.offersBackfill)
        guard await (WiltedMacHeadless.eventually("switch-off stop message") {
            model.backfillState == .ended("Stopped. 1 labelled")
        }) else { return }
    }

    // MARK: Rendering

    func testRenderedViewShowsLabellingProgressStopAndEndedMessage() async throws {
        let gate = HoldGate()
        let model = makeReadyModel(shows: { [self.publicShow()] }) { onProgress in
            onProgress(LabellerBackfill.Progress(done: 1, total: 5, recorded: 1, failed: 0))
            await gate.waitUntilReleased()
            return self.summary(recorded: 3, failed: 0, remaining: 0, ending: .finished)
        }
        model.startBackfill()
        guard await (WiltedMacHeadless.eventually("running(done: 1, total: 5)") {
            model.backfillState == .running(done: 1, total: 5)
        }) else { return }

        let runningText = try cardText(model)
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "Labelling 2 of 5", in: runningText), 1, runningText)
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "Stop", in: runningText), 1, runningText)
        XCTAssertFalse(runningText.contains("Label now"), runningText)

        gate.release()
        guard await (WiltedMacHeadless.eventually("ended with 3 labelled") {
            model.backfillState == .ended("3 labelled")
        }) else { return }

        let endedText = try cardText(model)
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "3 labelled", in: endedText), 1, endedText)
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "Prepared episodes", in: endedText), 1, endedText)
        XCTAssertTrue(endedText.contains("Label now"), endedText)
    }

    // MARK: Helpers

    private func makeReadyModel(
        shows: @escaping @MainActor () -> [WiltedMacAdFindingSettings.Show],
        backfill: WiltedMacAdFindingSettings.BackfillRun?
    ) -> WiltedMacAdFindingSettings {
        let preferences = WiltedMacTestPreferences.ephemeral()
        AdLabellerPreferences(preferences: preferences).setConfirmed(feedID: "feed-a", true)
        let model = WiltedMacAdFindingSettings(
            preferences: preferences, keyStore: InMemoryLabellerKeyStore(key: "fixture-key"),
            shows: shows, backfill: backfill)
        model.setOnlineFinding(true)
        XCTAssertTrue(model.hasKey)
        XCTAssertTrue(model.isOnlineFindingOn)
        return model
    }

    private func makeModel(
        shows: @escaping @MainActor () -> [WiltedMacAdFindingSettings.Show],
        backfill: WiltedMacAdFindingSettings.BackfillRun?
    ) -> WiltedMacAdFindingSettings {
        WiltedMacAdFindingSettings(
            preferences: WiltedMacTestPreferences.ephemeral(),
            keyStore: InMemoryLabellerKeyStore(),
            shows: shows,
            backfill: backfill)
    }

    private func immediate(_ ending: ImmediateEnding) -> WiltedMacAdFindingSettings.BackfillRun {
        { _ in
            switch ending {
            case .finished(let recorded):
                return self.summary(recorded: recorded, failed: 0, remaining: 0, ending: .finished)
            }
        }
    }

    private enum ImmediateEnding {
        case finished(recorded: Int)
    }

    private func summary(
        recorded: Int, failed: Int, remaining: Int, ending: LabellerBackfill.Ending
    ) -> LabellerBackfill.Summary {
        LabellerBackfill.Summary(
            recorded: recorded, failed: failed, remaining: remaining, ending: ending)
    }

    private func publicShow() -> WiltedMacAdFindingSettings.Show {
        WiltedMacAdFindingSettings.Show(
            feedID: "feed-a", title: "Public Show",
            feedURL: URL(string: "https://feeds.example.test/feed-a.xml"))
    }

    private func cardText(_ model: WiltedMacAdFindingSettings) throws -> String {
        try WiltedMacHeadless.recognizedText(
            WiltedMacAdFindingSettingsView(model: model), size: CGSize(width: 700, height: 600)
        ).joined(separator: " ")
    }
}

/// Releases a held backfill step so a test can assert mid-run state.
@MainActor
private final class HoldGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
