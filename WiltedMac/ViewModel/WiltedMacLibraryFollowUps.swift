import Foundation
import ObjectiveC

#if canImport(WiltedProducer)
import WiltedDomain

/// Library work a podcast's natural end owes once the next episode has started.
///
/// The listener hears the successor first: user-facing work is never queued
/// behind backend work. The finished episode's retirement, the queue refresh
/// and the library reloads (with the admission pass the retirement triggers)
/// run here, one job at a time, off the playback command tail. A slow reload
/// therefore delays only the shelf catching up, never the next episode's audio.
///
/// Durability. Before the controller calls the natural-end handler it has
/// already saved the finished episode's listening completion
/// (`checkpointCompletedRevision`), and the continuation takes the episode out
/// of the durable queue before it starts the successor. The only write left
/// for this lane is the retirement stamp, the first step of its job. A normal
/// quit joins the lane (`drainLibraryFollowUpsForTermination`, called from the
/// quit drain after the playhead flush) and so does `close()`, so quitting
/// right after the successor starts still retires the finished episode. A crash
/// in that short window leaves it completed and out of the queue but not
/// retired, the same state the old order left between its queue removal and
/// its retirement.
@MainActor
final class WiltedMacLibraryFollowUps {
    private var tail: Task<Void, Never>?
    /// The latest natural end, while its controller handler or continuation holds it.
    weak var pendingNaturalEnd: WiltedMacNaturalEnd?
    /// Awaited before each job starts; a test holds the lane with it.
    var beforeEachForTesting: (@MainActor () async -> Void)?

    /// Runs `body` after every job queued before it.
    func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = tail
        let hold = beforeEachForTesting
        tail = Task { @MainActor in
            await previous?.value
            await hold?()
            await body()
        }
    }

    /// Returns once every queued job, including any queued while draining, has run.
    func drain() async {
        while let task = tail {
            await task.value
            if tail == task { return }
        }
    }
}

/// One podcast's natural end, from end of file until its retirement is queued.
///
/// The controller saves the completion, reports it through
/// `podcastCompletionHandler`, and then either calls the natural-end handler
/// or, when a newer load landed meanwhile, drops it uncalled. The old wiring
/// retired the episode from both places, so every natural end ran the
/// retirement and its reloads twice, the duplicate in parallel with the
/// successor's start. This token owes exactly one retirement instead: the
/// continuation takes it after the start, a quit drain takes it if the
/// continuation has not yet, and a handler dropped uncalled after the
/// completion was saved queues it as the token is released.
@MainActor
final class WiltedMacNaturalEnd {
    let finishedID: ItemID
    let reachedEndAt: ContinuousClock.Instant
    /// The controller saved the completion and reported it.
    var completionIsDurable = false
    /// The controller called the natural-end handler, which it does only after saving the completion.
    var handedOff = false
    private var retirementTaken = false
    private weak var model: WiltedMacModel?

    init(finishedID: ItemID, reachedEndAt: ContinuousClock.Instant, model: WiltedMacModel) {
        self.finishedID = finishedID
        self.reachedEndAt = reachedEndAt
        self.model = model
    }

    /// The completion is saved and no one has queued the retirement yet.
    var owesRetirement: Bool { (completionIsDurable || handedOff) && !retirementTaken }

    /// True for exactly one caller, the one that will queue the retirement.
    func takeRetirement() -> Bool {
        guard !retirementTaken else { return false }
        retirementTaken = true
        return true
    }

    isolated deinit {
        guard owesRetirement, takeRetirement() else { return }
        model?.enqueueRetirement(of: finishedID)
    }
}

extension WiltedMacModel {
    var libraryFollowUps: WiltedMacLibraryFollowUps {
        if let lane = objc_getAssociatedObject(self, &libraryFollowUpsKey) as? WiltedMacLibraryFollowUps {
            return lane
        }
        let lane = WiltedMacLibraryFollowUps()
        objc_setAssociatedObject(self, &libraryFollowUpsKey, lane, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return lane
    }

    /// The controller saved a podcast's completion. A pending natural end of
    /// the same episode retires it after the successor starts; any other
    /// completion (a manual Next, a playlist or outside-the-shelf end) is
    /// retired now, on the lane.
    func retireDurablePodcastCompletion(_ id: ItemID) {
        if let end = libraryFollowUps.pendingNaturalEnd, end.finishedID == id {
            end.completionIsDurable = true
            return
        }
        enqueueRetirement(of: id)
    }

    /// Retirement alone, with the reload that takes the row off the shelf.
    func enqueueRetirement(of id: ItemID) {
        libraryFollowUps.enqueue { [weak self] in
            guard let self else { return }
            _ = await self.completeAndRetire(id)
            if !self.isClosingTemporaryState { await self.reloadLibraryRows() }
        }
    }

    /// A normal quit's step for the lane: queue a saved natural end's
    /// retirement that its continuation has not reached yet (a quit can land
    /// between the successor's start and that hand-off), then wait for every
    /// queued job. Every step that starts after the closing flag skips its
    /// reload and admission, so the wait is the retirement writes plus at most
    /// the one reload or admission pass already running when the quit began.
    func drainLibraryFollowUpsForTermination() async {
        if let end = libraryFollowUps.pendingNaturalEnd, end.owesRetirement, end.takeRetirement() {
            enqueueRetirement(of: end.finishedID)
        }
        await libraryFollowUps.drain()
    }
}

private nonisolated(unsafe) var libraryFollowUpsKey: UInt8 = 0
#endif
