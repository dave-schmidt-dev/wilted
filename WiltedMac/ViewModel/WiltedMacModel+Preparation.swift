import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

extension WiltedMacModel {
    /// Crosses one work-ticket state transition into the store's actor-isolated
    /// ticket table. Best-effort and fire-and-forget by design: the in-memory
    /// projection (`preparationRequestSequences`) is already what the reader
    /// sees and what orders the gate, so a store-less model or a call that
    /// throws must not fail or block the caller -- it only fails to make this
    /// one transition durable yet. A ticket a launch could not write here is
    /// recreated (as `.pending`) by the next successful
    /// `reconcileWorkTickets(in:)` pass instead, which is what keeps a
    /// store-less request from being lost outright rather than merely
    /// delayed.
    ///
    /// An admission is the one exception to normal forward-only transitions:
    /// a newer request sequence atomically replaces a terminal attempt's
    /// policy and stale failure/run metadata in the same durable row. Within
    /// that new sequence, subsequent transitions remain forward-only and its
    /// policy stays immutable.
    /// The work-ticket durability log. A rejected or failed transition write
    /// is not silent: it lands here at `.warning`, retrievable with
    /// `log show --predicate 'subsystem == "com.zerodelta.wilted.mac"'`.
    private static let workTicketLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "WorkTicket")
    static let playbackLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "Playback")

    /// Records one state transition for a work ticket, find-or-inserting it
    /// first if this is its first write.
    ///
    /// The actual find/validate/mutate/save happens in a single call to
    /// `LocalLibraryStore.applyWorkTicketTransition` -- one actor hop, no
    /// `await` in the middle -- because that is what serializes two
    /// concurrent transitions for the same subject. This method is called
    /// from detached `Task`s at nine call sites (register/consume/withdraw,
    /// download, article and podcast preparation), and Swift gives no
    /// ordering guarantee between those Tasks: a `.running` written by one
    /// can race a `.pending` written by another for the same subject. Doing
    /// the whole transition inside one actor-isolated store call, rather than
    /// composing `issueWorkTicket` + local mutation + `upsertWorkTicket`
    /// across two awaits, is what closes that window -- the actor itself
    /// orders the two calls, whichever arrives second simply sees the first
    /// one's result already applied.
    ///
    /// Errors are never swallowed. An illegal transition (a terminal ticket
    /// dragged back open) and any store-level failure are both logged at
    /// `.warning` with the subject and the attempted state; a lost or
    /// rejected ticket write has to be observable somewhere, given the
    /// store's own measured behavior that a conflicting unique-constraint
    /// insert already throws on neither side.
    func recordWorkTicketTransition(
        kind: WorkTicketKind,
        subjectID: String,
        requestSequence: Int? = nil,
        state: WorkTicketState,
        resolvedItemID: String? = nil,
        policySnapshot: Data? = nil,
        processingPolicy: Data? = nil,
        failureKind: String? = nil,
        lastFailureMessage: String? = nil,
        admitting: Bool = false
    ) async {
        guard let store else { return }
        let now = Timestamp(Date())
        do {
            if admitting, let requestSequence {
                _ = try await store.readmitWorkTicket(
                    kind: kind, subjectID: subjectID, requestSequence: requestSequence,
                    resolvedItemID: resolvedItemID, policySnapshot: policySnapshot,
                    processingPolicy: processingPolicy, to: state, at: now
                )
            } else {
                _ = try await store.applyWorkTicketTransition(
                    kind: kind, subjectID: subjectID, requestSequence: requestSequence,
                    resolvedItemID: resolvedItemID, policySnapshot: policySnapshot,
                    processingPolicy: processingPolicy, to: state,
                    failureKind: failureKind, lastFailureMessage: lastFailureMessage, at: now
                )
            }
        } catch {
            Self.workTicketLog.warning(
                "work ticket transition failed: kind=\(kind.rawValue, privacy: .public) subject=\(subjectID, privacy: .public) attemptedState=\(state.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Removes the advertisements and synchronises the transcript.
    ///
    /// Runs automatically once a download lands, and manually from the row for
    /// an episode that was downloaded before preparation existed or whose last
    /// attempt failed. Every stage is reported as it happens: the speech and
    /// classification passes take minutes, and a silent window is
    /// indistinguishable from a hung one.
    func prepareEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        removeDeferredAutomaticPreparation(episode.id)
        _ = prepareEpisode(episode, policySnapshot: Self.preparationPolicySnapshot(from: automationSettings))
#endif
    }

    @discardableResult
    func prepareEpisode(
        _ episode: WiltedMacEpisode,
        policySnapshot: PodcastPreparationPolicySnapshot
    ) -> Bool {
#if canImport(WiltedProducer)
        guard podcastPreparationTasks[episode.id] == nil else { return false }
        if fixtureMode {
            // No worker in fixture mode; the row still has to leave the state
            // it was in, so a UI test can tell a live control from a drawn one.
            startProjectedProcessorRun(for: episode)
            updateEpisode(episode.id) { $0.preparationState = .preparing(stage: "Preparing…") }
            podcastPreparationTasks[episode.id] = Task { [weak self] in
                defer {
                    self?.podcastPreparationTasks[episode.id] = nil
                    self?.finishProjectedProcessorRun(for: episode.id)
                }
                await Task.yield()
                self?.updateEpisode(episode.id) { $0.preparationState = .failed("No preparation worker in fixture mode") }
            }
            return true
        }
        guard let pipeline = podcastPreparationPipeline,
              let itemID = try? ItemID(rawValue: episode.id) else { return false }
        // Whether this run waits is decided now, so the row can say so now,
        // and so Prep can list it in the order it will run. The place in line
        // is taken here rather than where the run suspends on the gate: those
        // are one main-actor hop apart, and a row saying `Queued` that Prep
        // cannot name is the gap this closes.
        //
        // The gate is asked, and so is this process: a run becomes the gate's
        // business only when its task body reaches `admit()`, one main-actor
        // hop after it was started, so two downloads landing together could
        // both find the gate free and both claim to be preparing. A task
        // already in the table is a run that precedes this one -- this episode
        // cannot be in it, the guard above refused that -- and if that run
        // turns out to be leaving, this one is admitted immediately and the
        // row is corrected below rather than left waiting.
        let queued = preparationGate.isBusy || !podcastPreparationTasks.isEmpty
            || articlePreparationIsPending
        updateEpisode(episode.id) {
            $0.preparationState = .preparing(stage: queued ? Self.preparationQueuedStage : Self.preparingStage)
        }
        if queued {
            preparationQueue.enter(WiltedMacWaitingPreparation(
                id: episode.id, title: episode.title, source: episode.feedTitle
            ))
        }
        // A retry replaces the old terminal row immediately. Queued retries
        // are represented by preparationQueue; once one owns the gate it
        // gets the active projection below.
        processorRuns.removeAll { $0.isPodcast && $0.itemID == episode.id }
        if !queued { startProjectedProcessorRun(for: episode) }
        podcastOperationMessage = queued
            ? "\(episode.title) is queued behind the preparation in flight."
            : "Preparing \(episode.title)…"
        // The row says only that the episode is preparing. Every status the
        // worker emits is journalled by the pipeline, and Prep reads that
        // journal back as the narrative and, on request, the full log.
        //
        // The request sequence was issued when the reader asked for the
        // episode, so the gate can order this run against requests that have
        // not finished downloading yet.
        // Encoded once here, at admission, and never re-derived: the ticket
        // this becomes carries this exact snapshot verbatim through to run
        // start, even if `automationSettings` changes while the run sits
        // queued behind another one on the gate.
        let admittedPolicyData = try? JSONEncoder().encode(policySnapshot)
        let requestSequence = consumePreparationRequest(
            for: episode.id, policySnapshot: admittedPolicyData
        )
        podcastPreparationTasks[episode.id] = Task { [weak self] in
            defer {
                self?.podcastPreparationTasks[episode.id] = nil
                // Every way out of this run leaves the line, including the
                // ones that never reached the admission below.
                self?.preparationQueue.leave(episode.id)
                self?.finishProjectedProcessorRun(for: episode.id)
            }
            guard let gate = self?.preparationGate else { return }
            do {
                try await gate.admit(sequence: requestSequence)
            } catch {
                self?.updateEpisode(episode.id) { $0.preparationState = .notPrepared }
                self?.podcastOperationMessage = "Preparation cancelled."
                await self?.recordWorkTicketTransition(
                    kind: .podcastPreparation, subjectID: episode.id,
                    requestSequence: requestSequence, state: .cancelled
                )
                return
            }
            defer { gate.release() }
            self?.preparationQueue.leave(episode.id)
            self?.startProjectedProcessorRun(for: episode)
            if queued {
                self?.updateEpisode(episode.id) { $0.preparationState = .preparing(stage: Self.preparingStage) }
                self?.podcastOperationMessage = "Preparing \(episode.title)…"
            }
            // Admission is also dispatched when the request is consumed, but
            // that task can race this run after an immediately available gate.
            // Await the same idempotent write before reading its policy.
            await self?.recordWorkTicketTransition(
                kind: .podcastPreparation, subjectID: episode.id,
                requestSequence: requestSequence, state: .running,
                policySnapshot: admittedPolicyData, admitting: true
            )
            // Decoded verbatim from the ticket written at admission, never
            // re-derived from live settings at run start. Falls back to the
            // locally-captured snapshot only when there is no store (fixture
            // mode, or a store-less test) to have written the ticket at all.
            var runPolicySnapshot = policySnapshot
            if let self, let store = self.store,
               let ticket = try? await store.workTicket(kind: .podcastPreparation, subjectID: episode.id),
               let data = ticket.policySnapshot,
               let decoded = try? JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: data) {
                runPolicySnapshot = decoded
            }
            do {
                let result = try await pipeline.prepare(episodeID: itemID, policy: runPolicySnapshot)
                guard let self else { return }
                let summary = result.summary
                self.podcastOperationMessage = "\(episode.title): \(summary)"
                await self.recordWorkTicketTransition(
                    kind: .podcastPreparation, subjectID: episode.id,
                    requestSequence: requestSequence, state: .succeeded
                )
                if let store = self.store {
                    let values = try await self.loadLibrary(from: store)
                    self.articles = values.articles
                    self.applyEpisodes(values.episodes)
                    self.subscriptions = values.subscriptions
                    // The reload derives preparation state from the durable
                    // outcome row this run just wrote, with this run's own
                    // journalled detail (already carrying the ad count) as the
                    // label. But `applyEpisodes` carries this episode's *prior*
                    // in-memory `.preparing` back onto the reloaded row, because
                    // this task is still tracked as running until the outer
                    // `defer` clears it once this closure returns -- so the
                    // freshly derived state has to be re-applied for this one
                    // episode now, rather than left for `applyingRunningPreparations`
                    // to overwrite.
                    if let derived = values.episodes.first(where: { $0.id == episode.id })?.preparationState {
                        self.updateEpisode(episode.id) { $0.preparationState = derived }
                    }
                }
                await self.reloadPreparedPlayback(episode.id, itemID: itemID)
                await self.refreshLifetimeStatistics()
            } catch is CancellationError {
                self?.updateEpisode(episode.id) { $0.preparationState = .notPrepared }
                self?.podcastOperationMessage = "Preparation cancelled."
                await self?.recordWorkTicketTransition(
                    kind: .podcastPreparation, subjectID: episode.id,
                    requestSequence: requestSequence, state: .cancelled
                )
            } catch {
                // The reason is on Prep, with the log that led to it.
                self?.updateEpisode(episode.id) { $0.preparationState = .failed(Self.preparationFailedLabel) }
                self?.podcastOperationMessage = "\(episode.title): \(Self.preparationFailedLabel)"
                // `PreparationCoordinator` classifies every terminal failure
                // into a `ProducerError` with its own `retryable` flag before
                // it ever reaches here; anything else reaching this catch
                // (a decode fault, a thrown non-`ProducerError`) has no
                // classification to trust and is conservatively terminal.
                let failureKind: PodcastDownloadFailureKind =
                    (error as? ProducerError)?.retryable == true ? .retryable : .terminal
                await self?.recordWorkTicketTransition(
                    kind: .podcastPreparation, subjectID: episode.id,
                    requestSequence: requestSequence, state: .failed,
                    failureKind: failureKind.rawValue, lastFailureMessage: String(describing: error)
                )
            }
        }
        return true
#else
        return false
#endif
    }

#if canImport(WiltedProducer)
    /// Publishes the active run before the preparation actor has written its
    /// first journal entry. Queued work remains in preparationQueue until it
    /// owns the gate, so the two Processor sections cannot show duplicate rows.
    private func startProjectedProcessorRun(for episode: WiltedMacEpisode) {
        let run = WiltedMacProcessorRun(
            id: Self.podcastRequestPrefix + episode.id,
            itemID: episode.id,
            isPodcast: true,
            title: episode.title,
            source: episode.feedTitle,
            stage: "preparing",
            detail: Self.preparingStage,
            narrative: Self.preparingStage,
            fraction: nil,
            outcome: .running,
            updatedAt: Date()
        )
        projectedProcessorRuns[episode.id] = run
        processorRuns.removeAll { $0.isPodcast && $0.itemID == episode.id }
        processorRuns.insert(run, at: 0)
    }

    /// Drops the local projection once the task has left the process-owned
    /// table. The next journal refresh then supplies the durable terminal row,
    /// if one exists.
    private func finishProjectedProcessorRun(for episodeID: String) {
        let projected = projectedProcessorRuns.removeValue(forKey: episodeID)
        if let projected, let index = processorRuns.firstIndex(of: projected) {
            processorRuns.remove(at: index)
        }
        refreshProcessorRuns()
    }
#endif

    /// What a row says when its preparation failed. The cause is on Prep.
    nonisolated static let preparationFailedLabel = "Preparation failed. Retry it from Larder."

    /// What a row says once its preparation owns the single run slot.
    nonisolated static let preparingStage = "Preparing…"

    /// What a row says while it waits for the run ahead of it to finish. The
    /// GPU admits one preparation, so the rest queue instead of failing.
    nonisolated static let preparationQueuedStage = "Queued"

    /// The article composer's equivalent of `preparationQueuedStage`. An
    /// article has one detail line rather than a row stage, so it says the
    /// whole sentence.
    nonisolated static let articlePreparationQueuedDetail = "Queued behind the preparation in flight."

    /// Runs a podcast preparation again from its row on Prep. A failed run's
    /// retry lives next to the failure rather than in the Larder, where the
    /// row only says to look here.
    func retryProcessorRun(_ run: WiltedMacProcessorRun) {
        guard run.isPodcast else { return }
        guard let episode = episodes.first(where: { $0.id == run.itemID }) else {
            // The restore control lives on Feeds, so the sentence has to name
            // the surface the reader can actually press.
            processorOperationMessage = dismissedEpisodes.contains(where: { $0.id == run.itemID })
                ? "Restore \(run.title) from Feeds before retrying preparation."
                : "\(run.title) is no longer in Feeds. Add it again before retrying preparation."
            return
        }
        processorOperationMessage = nil
        prepareEpisode(episode)
    }

    func cancelEpisodePreparation(_ episode: WiltedMacEpisode) {
        if deferredAutomaticPreparations.contains(where: { $0.episodeID == episode.id }) {
            removeDeferredAutomaticPreparation(episode.id)
            updateEpisode(episode.id) { $0.preparationState = .notPrepared }
            podcastOperationMessage = "Preparation cancelled."
            return
        }
        podcastPreparationTasks[episode.id]?.cancel()
    }

    /// Stops a run that is still waiting for the slot, from Prep, where the
    /// waiting run is named but its episode row is not in reach. The gate lets
    /// a queued caller leave at the moment it is cancelled rather than when
    /// the run ahead of it finishes, so the row clears now.
    /// Whether a queued row is waiting for its off-peak window rather than for
    /// the preparation gate.
    ///
    /// Both render the same "Queued" stage, and only this one can be started
    /// early. Overriding the gate would run two preparations at once, which is
    /// the thing the gate exists to prevent.
    func isDeferredToOffPeak(_ episodeID: String) -> Bool {
        deferredAutomaticPreparations.contains { $0.episodeID == episodeID }
    }

    /// Runs a job that is waiting on the clock, now.
    ///
    /// It runs under the policy snapshot it was admitted with, exactly as
    /// `startEligibleAutomaticPreparations` does when the window opens on its
    /// own. That is the difference between this and the Stop-then-Prepare the
    /// owner had to use before it existed: cancelling discards the snapshot, so
    /// the job came back under whatever Settings happened to say at the time.
    func prepareDeferredPreparationNow(_ episodeID: String) {
        guard let deferred = deferredAutomaticPreparations.first(where: { $0.episodeID == episodeID }),
              let episode = episodes.first(where: { $0.id == episodeID }) else { return }
        preparationQueue.leave(episodeID)
        if prepareEpisode(episode, policySnapshot: deferred.policySnapshot) {
            removeDeferredAutomaticPreparation(episodeID, leaveQueue: false)
            return
        }
        // The gate is busy with another episode. Put it back the way it was and
        // say so, rather than leaving a button that looks broken.
        preparationQueue.enter(WiltedMacWaitingPreparation(
            id: episode.id, title: episode.title, source: episode.feedTitle
        ))
        podcastOperationMessage = "\(episode.title) will start when the current preparation finishes."
    }

    func cancelWaitingPreparation(_ waiting: WiltedMacWaitingPreparation) {
        if deferredAutomaticPreparations.contains(where: { $0.episodeID == waiting.id }) {
            removeDeferredAutomaticPreparation(waiting.id)
            updateEpisode(waiting.id) { $0.preparationState = .notPrepared }
            podcastOperationMessage = "Preparation cancelled."
            return
        }
        podcastPreparationTasks[waiting.id]?.cancel()
    }

#if canImport(WiltedProducer)
    /// Starts whatever the Menu has next, once the episode that was playing
    /// has been finished by hand.
    ///
    /// Playing an episode to its end advances inside the controller's own
    /// completion sequence. Saying "I am done with this" at 91% means the same
    /// thing to a listener, and it was stopping the audio instead: the two ways
    /// of finishing an episode agreed about the durable record and disagreed
    /// about what happened next. `retireFinishedEpisode` has already taken the
    /// finished episode off the queue, so the next one is normally its head --
    /// asking the controller for "next" would be asking relative to an item
    /// that is no longer in the list.
    ///
    /// "Normally" is doing real work there, which is why the head is not
    /// trusted blindly. `retireFinishedEpisode` swallows a failed
    /// `removePodcastQueueEpisode`, and `refreshPodcastQueueState` returns
    /// early when the store cannot be read, so either fault leaves the episode
    /// that was just finished sitting at the head of the queue. Starting it
    /// again is the worst possible answer to "I am done with this", so the
    /// episode just retired is skipped explicitly rather than assumed gone.
    func advanceToNextMenuEpisode() {
        guard isPodcastPlayback else {
            Self.playbackLog.notice("advanceToNextMenuEpisode: not podcast playback")
            return
        }
        guard let next = nextMenuEpisodeToPlay() else {
            Self.playbackLog.notice("advanceToNextMenuEpisode: no next episode")
            return
        }
        Self.playbackLog.notice(
            "advanceToNextMenuEpisode: nextEpisode=\(next.id, privacy: .public)"
        )
        playEpisode(next)
    }

#endif
}
