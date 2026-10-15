import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

/// Presentation belongs to an exact loaded revision and selection, including same-item reselections.
struct WiltedMacPlaybackPresentationOwner: Equatable {
    let itemID: ItemID
    let revisionID: RevisionID
    let selectionToken: UInt64
    let generation: UInt64
}

extension WiltedMacModel {
    func playbackPresentationOwner(
        itemID: ItemID, revisionID: RevisionID
    ) -> WiltedMacPlaybackPresentationOwner? {
        guard !isClosingTemporaryState, playback?.itemID == itemID,
              playback?.revisionID == revisionID else { return nil }
        return WiltedMacPlaybackPresentationOwner(
            itemID: itemID, revisionID: revisionID,
            selectionToken: playbackCommands.selectionToken,
            generation: playbackPresentationGeneration
        )
    }

    func ownsPlaybackPresentation(_ owner: WiltedMacPlaybackPresentationOwner) -> Bool {
        !isClosingTemporaryState && !Task.isCancelled
            && playbackPresentationGeneration == owner.generation
            && playbackCommands.selectionToken == owner.selectionToken
            && playback?.itemID == owner.itemID && playback?.revisionID == owner.revisionID
    }

    /// The ledger retains cancelled work until it finishes, so close also joins old actor reads.
    func cancelPlaybackPresentation() {
        playbackPresentationGeneration &+= 1
        if let id = playbackPresentationTaskID { playbackPresentationTasks[id]?.cancel() }
        playbackPresentationTaskID = nil
    }

    /// Start presentation after audio admission without appending its reads to the audio tail.
    func requestPlaybackPresentation(
        itemID: ItemID, includesCuts: Bool, refreshQueue: Bool = false, traceToken: UInt64? = nil,
        reloadRows: Bool = false
    ) {
        cancelPlaybackPresentation()
        guard let revisionID = playback?.revisionID,
              let owner = playbackPresentationOwner(itemID: itemID, revisionID: revisionID) else { return }
        let id = UUID()
        playbackPresentationTaskID = id
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.playbackPresentationTasks[id] = nil
                if self.playbackPresentationTaskID == id { self.playbackPresentationTaskID = nil }
            }
            if let traceToken { self.playbackCommands.trace.record(.transcriptTailBegan, token: traceToken) }
            defer {
                if let traceToken { self.playbackCommands.trace.record(.transcriptTailEnded, token: traceToken) }
            }
            // Observation reloads can be scheduled during load; the command-tail
            // barrier belongs only to the traced command's own presentation request.
            if traceToken != nil { await self.playbackCommands.beforeTranscriptTailForTesting?() }
            guard self.ownsPlaybackPresentation(owner) else { return }
            await self.readPlaybackPresentation(owner, includesCuts: includesCuts)
            guard self.ownsPlaybackPresentation(owner) else { return }
            if reloadRows { await self.reloadLibraryRows() }
            guard self.ownsPlaybackPresentation(owner) else { return }
            if refreshQueue { await self.refreshPodcastQueueState() }
            guard self.ownsPlaybackPresentation(owner) else { return }
            self.refreshPlaybackReadout()
        }
        playbackPresentationTasks[id] = task
    }

    /// Presentation settlement is deliberately independent of audio-command settlement.
    func waitForPlaybackPresentationForTesting() async {
        let id = playbackPresentationTaskID
        if let id { await playbackPresentationTasks[id]?.value }
    }

    /// Read immutable values first; apply text and cuts together only while the owner still matches.
    func readPlaybackPresentation(_ owner: WiltedMacPlaybackPresentationOwner, includesCuts: Bool) async {
        guard let store, ownsPlaybackPresentation(owner) else { return }
        let transcript = try? await store.transcript(for: owner.itemID, revisionID: owner.revisionID)
        guard ownsPlaybackPresentation(owner) else { return }
        var spans: [WiltedMacRemovedSpan] = []
        if includesCuts {
            if let timeline = try? await store.latestPreparationTimeline(
                for: owner.itemID, revisionID: owner.revisionID
            ) { spans = Self.removedSpans(in: timeline) }
        }
        await playbackPresentationReadBarrierForTesting?()
        guard ownsPlaybackPresentation(owner) else { return }
        currentTranscript = transcript.map(WiltedMacTranscript.init(stored:))
            ?? WiltedMacTranscript(availability: .absent, text: nil)
        if includesCuts {
            removedSpansByEpisode[owner.itemID.rawValue] = spans
            rescheduleSeamMarker()
        }
    }
}
#endif
