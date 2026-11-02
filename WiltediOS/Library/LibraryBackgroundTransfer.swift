import BackgroundTasks
import Foundation
import OSLog
import UIKit
import WiltedDomain

private let transferLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryBackgroundTransfer")

/// The system's handle on the running background task, reduced to what the phone uses. A fake stands in
/// for it in tests, because the real one only exists on a device with the Info key declared.
@MainActor
protocol LibraryBackgroundTransferTask: AnyObject {
    /// Bytes done and bytes expected across every direct job the task covers.
    func setProgress(completed: Int64, total: Int64)
    func setText(title: String, subtitle: String)
    /// Called when the system ends the task early (time, resources, or the person's Cancel).
    var expirationHandler: (@MainActor () -> Void)? { get set }
    func complete(success: Bool)
}

/// Submits the one background task that keeps direct downloads going when the app leaves the front.
protocol LibraryBackgroundTransferScheduling: Sendable {
    /// Asks the system to run `start` once the task begins. Throws when the request is refused.
    @MainActor func submit(
        title: String, subtitle: String, start: @escaping @MainActor (any LibraryBackgroundTransferTask) -> Void
    ) throws
}

/// One background task for all direct downloads. The first Get audio submits it; a second joins the
/// running task instead of submitting another. Its progress is the bytes received across every queued
/// direct job over their total. When the system ends it early, every direct job stops where it is, its
/// partial file kept, and `onExpire` lets the model resume them the next time the app is in front.
@MainActor
final class LibraryDirectTransferCoordinator {
    static let title = "Downloading from your Mac"

    private struct Part { var done: Int64; var total: Int64; var finished = false }

    private let scheduler: any LibraryBackgroundTransferScheduling
    private let onExpire: @MainActor () -> Void
    private var parts: [ItemID: Part] = [:]
    private var task: (any LibraryBackgroundTransferTask)?
    private var submitted = false

    /// How many times a task was submitted; for tests.
    private(set) var submissions = 0

    init(scheduler: any LibraryBackgroundTransferScheduling, onExpire: @escaping @MainActor () -> Void) {
        self.scheduler = scheduler
        self.onExpire = onExpire
    }

    /// Bytes done and expected across the queued jobs.
    var totals: (completed: Int64, total: Int64) {
        (parts.values.reduce(0) { $0 + $1.done }, parts.values.reduce(0) { $0 + $1.total })
    }

    var jobCount: Int { parts.count }

    /// A direct job begins with `bytes` already on disk. The first one submits the task.
    func join(entryID: ItemID, bytes: Int64, total: Int64) {
        parts[entryID] = Part(done: min(bytes, total), total: total)
        if !submitted {
            submitted = true
            submissions += 1
            do {
                try scheduler.submit(title: Self.title, subtitle: subtitle) { [weak self] started in
                    self?.taskStarted(started)
                }
            } catch {
                // No background time: the downloads go on while the app is in front.
                transferLog.notice("The background task was not submitted: \(String(describing: error), privacy: .public)")
            }
        }
        publish()
    }

    func progress(entryID: ItemID, bytes: Int64) {
        guard var part = parts[entryID] else { return }
        part.done = min(max(part.done, bytes), part.total)
        parts[entryID] = part
        publish()
    }

    /// A job ended. A finished one stays in the totals until every job is done; one that stopped for any
    /// other reason leaves them.
    func leave(entryID: ItemID, finished: Bool) {
        if finished, var part = parts[entryID] {
            part.done = part.total
            part.finished = true
            parts[entryID] = part
        } else {
            parts[entryID] = nil
        }
        publish()
        if parts.values.allSatisfy(\.finished) { finishTask(success: true) }
    }

    private var subtitle: String { parts.count == 1 ? "1 episode" : "\(parts.count) episodes" }

    private func publish() {
        guard let task else { return }
        let (completed, total) = totals
        task.setProgress(completed: completed, total: total)
        task.setText(title: Self.title, subtitle: subtitle)
    }

    private func taskStarted(_ started: any LibraryBackgroundTransferTask) {
        guard submitted, !parts.isEmpty else { started.complete(success: true); return }
        task = started
        started.expirationHandler = { [weak self] in self?.expired() }
        publish()
    }

    /// The system ended the task. The model stops the runs (their partial files stay) and resumes them in
    /// the foreground.
    private func expired() {
        transferLog.notice("The background task expired with \(self.parts.count, privacy: .public) direct jobs")
        finishTask(success: false)
        onExpire()
    }

    private func finishTask(success: Bool) {
        let ended = task
        task = nil
        submitted = false
        parts = [:]
        ended?.complete(success: success)
    }
}

// MARK: - Live scheduler

/// The `BGContinuedProcessingTaskRequest` with the fixed identifier. It needs the identifier in the app's
/// `BGTaskSchedulerPermittedIdentifiers`; without it, or when the system refuses the request, the downloads
/// get a short `beginBackgroundTask` extension instead. One instance per process: registering the same
/// identifier twice kills the app.
@MainActor
final class LiveBackgroundTransferScheduler: LibraryBackgroundTransferScheduling {
    static let identifier = "com.zerodelta.wilted.ios.media-download"
    static let shared = LiveBackgroundTransferScheduler()

    private var registered = false
    private var pending: (@MainActor (any LibraryBackgroundTransferTask) -> Void)?

    private init() {}

    func submit(
        title: String, subtitle: String, start: @escaping @MainActor (any LibraryBackgroundTransferTask) -> Void
    ) throws {
        pending = start
        if !registered {
            registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.identifier, using: nil,
                launchHandler: mainActorCallback { (task: BGTask) in LiveBackgroundTransferScheduler.shared.launched(task) })
        }
        guard registered else { return beginExtension(start) }
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier, title: title, subtitle: subtitle)
        request.strategy = .queue
        do { try BGTaskScheduler.shared.submit(request) } catch {
            transferLog.notice("The background request was refused: \(String(describing: error), privacy: .public)")
            beginExtension(start)
        }
    }

    private func launched(_ task: BGTask) {
        guard let continued = task as? BGContinuedProcessingTask, let start = pending else {
            task.setTaskCompleted(success: pending == nil)
            return
        }
        pending = nil
        start(ContinuedTask(continued))
    }

    private func beginExtension(_ start: @escaping @MainActor (any LibraryBackgroundTransferTask) -> Void) {
        pending = nil
        start(ExtensionTask())
    }
}

/// Adapts main-actor work for a system callback that runs on the system's own queue. A closure
/// written inside main-actor code is main-actor isolated, and Swift 6 traps when the system calls it
/// off the main thread; this one is nonisolated and hops to the main actor.
nonisolated func mainActorCallback<Value: AnyObject>(
    _ body: @escaping @MainActor (Value) -> Void
) -> @Sendable (Value) -> Void {
    { value in
        let handle = UncheckedHandle(value)
        Task { @MainActor in body(handle.value) }
    }
}

/// The no-argument form of `mainActorCallback`, for expiration handlers.
nonisolated func mainActorCallback(_ body: @escaping @MainActor () -> Void) -> @Sendable () -> Void {
    { Task { @MainActor in body() } }
}

/// Carries a system object from its callback's queue to the main actor, where it is used.
private final class UncheckedHandle<Value: AnyObject>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The system's task, adapted. Progress is reported through its `NSProgress`.
@MainActor
private final class ContinuedTask: LibraryBackgroundTransferTask {
    private let task: BGContinuedProcessingTask
    var expirationHandler: (@MainActor () -> Void)? {
        didSet {
            let handler = expirationHandler
            task.expirationHandler = mainActorCallback { handler?() }
        }
    }

    init(_ task: BGContinuedProcessingTask) { self.task = task }

    func setProgress(completed: Int64, total: Int64) {
        task.progress.totalUnitCount = max(1, total)
        task.progress.completedUnitCount = completed
    }

    func setText(title: String, subtitle: String) { task.updateTitle(title, subtitle: subtitle) }
    func complete(success: Bool) { task.setTaskCompleted(success: success) }
}

/// The fallback: a `beginBackgroundTask` assertion, which has no progress to show.
@MainActor
private final class ExtensionTask: LibraryBackgroundTransferTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    var expirationHandler: (@MainActor () -> Void)?

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Wilted audio download",
            expirationHandler: mainActorCallback { [weak self] in self?.expirationHandler?() })
    }

    func setProgress(completed: Int64, total: Int64) {}
    func setText(title: String, subtitle: String) {}

    func complete(success: Bool) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
