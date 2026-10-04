import AppKit
import Foundation
import WiltedDomain
import WiltedProducer

/// What a normal quit has to finish before the process may exit.
///
/// The local step must succeed inside the budget or the quit is cancelled.
/// The network step only gets whatever budget remains. Pending cloud work is
/// already durable in the local outbox, so the network step never waits for
/// cloud success, and running out of time there does not cancel the quit.
@MainActor
protocol WiltedMacTerminationDraining: AnyObject {
    /// Pause now, stop admitting new work, then write the playhead,
    /// lifetime totals and in-flight download bytes. Throws when a write fails.
    func drainLocalWorkForTermination() async throws
    /// Cancel outstanding network generations, then close and join the
    /// library controllers.
    func closeNetworkWorkForTermination() async
    /// Undo what the drain stopped, because the app is staying open.
    func resumeAfterCancelledTermination()
}

/// Why a quit was cancelled.
enum WiltedMacTerminationFailure: Error, Equatable {
    case timedOut
    case saveFailed(String)

    var message: String {
        switch self {
        case .timedOut: "Saving took longer than 10 seconds."
        case let .saveFailed(detail): "Saving failed: \(detail)"
        }
    }
}

/// Runs a normal quit as `applicationShouldTerminate` → `terminateLater`:
/// drain the local work, close the network work, then reply exactly once.
///
/// A failed or timed-out local drain replies `false`, so the app stays open,
/// and offers a retry that quits again. Forced exits and crashes skip all of
/// this. They lose at most the disclosed tails: about 10 s of listening time
/// and 1 s of download bytes since the last periodic flush.
@MainActor
final class WiltedMacTerminationCoordinator {
    enum State: Equatable {
        case idle
        case draining
        case failed(WiltedMacTerminationFailure)
        case approved
    }

    static let localBudget: Duration = .seconds(10)

    private(set) var state: State = .idle
    private(set) var replies: [Bool] = []
    private weak var owner: (any WiltedMacTerminationDraining)?
    private let budget: Duration
    private let reply: @MainActor (Bool) -> Void
    private let presentFailure: @MainActor (WiltedMacTerminationFailure) -> Void
    private let journal: WiltedMacTerminationJournal?
    private var attempt: UInt64 = 0

    init(
        owner: any WiltedMacTerminationDraining,
        budget: Duration = WiltedMacTerminationCoordinator.localBudget,
        journal: WiltedMacTerminationJournal? = nil,
        reply: @escaping @MainActor (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) },
        presentFailure: @escaping @MainActor (WiltedMacTerminationFailure) -> Void = WiltedMacTerminationAlert.present
    ) {
        self.owner = owner
        self.budget = budget
        self.journal = journal
        self.reply = reply
        self.presentFailure = presentFailure
    }

    /// The delegate's answer. Starts at most one drain at a time. A repeated
    /// quit while one runs joins it rather than starting another, so there is
    /// still exactly one reply.
    func shouldTerminate() -> NSApplication.TerminateReply {
        journal?.record("should-terminate")
        switch state {
        case .approved:
            return .terminateNow
        case .draining:
            return .terminateLater
        case .idle, .failed:
            break
        }
        guard owner != nil else { return .terminateNow }
        state = .draining
        attempt &+= 1
        let current = attempt
        Task { await self.drain(attempt: current) }
        return .terminateLater
    }

    private func drain(attempt current: UInt64) async {
        let started = ContinuousClock.now
        let local = await Self.withinBudget(budget) { [weak owner] in
            try await owner?.drainLocalWorkForTermination()
        }
        guard current == attempt, state == .draining else { return }
        if case let .failure(failure) = local {
            owner?.resumeAfterCancelledTermination()
            state = .failed(failure)
            send(false)
            journal?.record("failed", detail: failure.message)
            presentFailure(failure)
            return
        }
        journal?.record("local-drained")
        let remaining = budget - (ContinuousClock.now - started)
        if remaining > .zero {
            let network = await Self.withinBudget(remaining) { [weak owner] in
                await owner?.closeNetworkWorkForTermination()
            }
            if case .failure = network { journal?.record("network-join-abandoned") }
        }
        guard current == attempt, state == .draining else { return }
        state = .approved
        send(true)
    }

    private func send(_ answer: Bool) {
        replies.append(answer)
        journal?.record("reply", detail: answer ? "terminate" : "cancel")
        reply(answer)
    }

    /// Runs `work`, giving up after `budget`. On timeout the work is
    /// cancelled, and its late completion can no longer change the answer.
    static func withinBudget(
        _ budget: Duration,
        _ work: @escaping @MainActor () async throws -> Void
    ) async -> Result<Void, WiltedMacTerminationFailure> {
        let box = WiltedMacTerminationOutcome()
        return await withCheckedContinuation { continuation in
            box.continuation = continuation
            let worker = Task { @MainActor in
                do {
                    try await work()
                    box.resolve(.success(()))
                } catch {
                    box.resolve(.failure(.saveFailed(String(describing: error))))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: budget)
                if box.resolve(.failure(.timedOut)) { worker.cancel() }
            }
        }
    }
}

/// Resolves a budgeted wait once, whichever side finishes first.
@MainActor
private final class WiltedMacTerminationOutcome {
    var continuation: CheckedContinuation<Result<Void, WiltedMacTerminationFailure>, Never>?

    @discardableResult
    func resolve(_ result: Result<Void, WiltedMacTerminationFailure>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: result)
        return true
    }
}

/// The visible retry state for a cancelled quit.
@MainActor
enum WiltedMacTerminationAlert {
    static func present(_ failure: WiltedMacTerminationFailure) {
        // After the reply, on the next turn, so AppKit has left its
        // terminate-later state before a sheet or modal runs.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Wilted didn't quit because it couldn't finish saving."
            alert.informativeText = "\(failure.message) Wilted stays open so your place and statistics are kept."
            alert.addButton(withTitle: "Try Quitting Again")
            alert.addButton(withTitle: "Keep Wilted Open")
            let respond: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertFirstButtonReturn { NSApplication.shared.terminate(nil) }
            }
            if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: \.isVisible) {
                alert.beginSheetModal(for: window, completionHandler: respond)
            } else {
                respond(alert.runModal())
            }
        }
    }
}

/// Fixture-only record of what the quit path did, one JSON object per line.
/// A fixture process writes it so a separate test process can assert
/// delegate entry, the reply and the drained position after exit.
final class WiltedMacTerminationJournal: @unchecked Sendable {
    static let argument = "--wilted-termination-journal"
    static let failFirstDrainArgument = "--wilted-termination-fail-first-drain"

    let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    /// The journal a fixture launch asked for; nil for every normal launch.
    static func forLaunch(arguments: [String], isFixture: Bool) -> WiltedMacTerminationJournal? {
        guard isFixture, let index = arguments.firstIndex(of: argument),
              arguments.indices.contains(index + 1) else { return nil }
        return WiltedMacTerminationJournal(url: URL(fileURLWithPath: arguments[index + 1]))
    }

    func record(_ event: String, detail: String? = nil, values: [String: String] = [:]) {
        var entry = values
        entry["event"] = event
        if let detail { entry["detail"] = detail }
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}

/// The app delegate SwiftUI hosts through `NSApplicationDelegateAdaptor`.
/// It owns the termination answer and nothing else.
@MainActor
final class WiltedMacAppDelegate: NSObject, NSApplicationDelegate {
    /// Installed by `WiltedMacApp.init`. Nil in a hosted test run, where
    /// quitting must never wait on the owner's library.
    static var termination: WiltedMacTerminationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.onLaunch?()
    }

    /// Fixture hook: lets a fixture record that it is ready to be quit.
    static var onLaunch: (@MainActor () -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.termination?.shouldTerminate() ?? .terminateNow
    }
}

extension WiltedMacModel: WiltedMacTerminationDraining {
    func drainLocalWorkForTermination() async throws {
        stopAdmittingWorkForTermination()
        try await flushPlaybackForTermination()
        await cancelAndAwaitDownloadsForTermination()
    }

    func closeNetworkWorkForTermination() async {
        await closeLibraryControllersForTermination()
    }

    func resumeAfterCancelledTermination() {
        resumeAdmittingWorkAfterCancelledTermination()
    }
}

/// Fixture-only owner: optionally fails its first drain before writing
/// anything, and journals the drained playhead so a process test can compare
/// it with what the reopened store committed.
@MainActor
final class WiltedMacFixtureDrain: WiltedMacTerminationDraining {
    private let model: WiltedMacModel
    private let journal: WiltedMacTerminationJournal
    private var failsNext: Bool

    init(model: WiltedMacModel, journal: WiltedMacTerminationJournal, failsFirst: Bool) {
        self.model = model
        self.journal = journal
        failsNext = failsFirst
    }

    func drainLocalWorkForTermination() async throws {
        if failsNext {
            failsNext = false
            throw CocoaError(.fileWriteUnknown)
        }
        try await model.drainLocalWorkForTermination()
        let summary = try? await model.store?.lifetimeStatisticsSummary()
        journal.record("playhead", values: [
            "item": model.playback?.itemID?.rawValue ?? "",
            "revision": model.playback?.revisionID?.rawValue ?? "",
            "position": String(model.playback?.livePositionSeconds ?? -1),
            "summaryState": summary?.state.rawValue ?? "",
            "playedMilliseconds": String(summary?.measured.playedMilliseconds ?? -1),
        ])
    }

    func closeNetworkWorkForTermination() async { await model.closeNetworkWorkForTermination() }
    func resumeAfterCancelledTermination() { model.resumeAfterCancelledTermination() }
}

extension WiltedMacModel {
    /// A normal quit's playback step. The audio stops now, not behind the
    /// command queue, a Stop fences any pending start or selection so nothing
    /// starts afterwards, and the playhead and lifetime totals are written
    /// with their errors surfaced. A failure here cancels the quit.
    func flushPlaybackForTermination() async throws {
        stopAutomationTicker()
        stopTicketDrainTicker()
        cancelSeamMarker()
#if canImport(WiltedProducer)
        guard let playback else { return }
        _ = issuePlaybackCommand(.stop, pending: nil) { _ in }
        guard playback.revisionID != nil else { return }
        try await playback.handlePauseOrQuit()
        isPlaying = playback.liveIsPlaying
        try await playback.flushLifetimeMeasures()
        refreshPlaybackReadout()
        // The sync outbox is local; this enqueues and never waits on cloud.
        await queueCurrentPlaybackCheckpoint()
#endif
    }
}

extension WiltedMacAppDelegate {
    /// Wires the quit path for a launch. A hosted test run gets none, so the
    /// delegate answers `terminateNow` and the test host is never held open.
    /// A fixture launch with a journal records instead of showing an alert.
    static func installTermination(for model: WiltedMacModel, arguments: [String], hostsTests: Bool) {
        guard !hostsTests else { return }
        guard let journal = WiltedMacTerminationJournal.forLaunch(
            arguments: arguments, isFixture: WiltedMacModel.isFixtureLaunch(arguments: arguments)
        ) else {
            termination = WiltedMacTerminationCoordinator(owner: model)
            return
        }
        let owner = WiltedMacFixtureDrain(
            model: model, journal: journal,
            failsFirst: arguments.contains(WiltedMacTerminationJournal.failFirstDrainArgument)
        )
        fixtureOwner = owner
        termination = WiltedMacTerminationCoordinator(owner: owner, journal: journal, presentFailure: { _ in })
        onLaunch = { [weak model] in
            Task { @MainActor in
                // Ready once the fixture is actually playing, plus a moment,
                // so the quit has a position and listening time to save.
                for _ in 0..<400 where !(model?.playback?.liveIsPlaying ?? false) {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                // The fixture backend's clock never advances on its own, so a
                // distinctive seek gives the quit a playhead worth saving.
                model?.seek(by: 37)
                for _ in 0..<200 where (model?.playback?.livePositionSeconds ?? 0) < 37 {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                try? await Task.sleep(for: .milliseconds(1_500))
                journal.record("ready", values: [
                    "pid": String(ProcessInfo.processInfo.processIdentifier),
                    "playing": String(model?.playback?.liveIsPlaying ?? false),
                ])
            }
        }
    }

    /// Keeps a fixture's owner alive; the coordinator holds its owner weakly.
    private static var fixtureOwner: WiltedMacFixtureDrain?
}
