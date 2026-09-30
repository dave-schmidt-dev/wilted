import Foundation
import WiltedDomain
import WiltedLibrary

/// One transcript load, identified so a cancelled or replaced load never writes state.
struct LibraryTranscriptRun {
    let id = UUID()
    var task: Task<Void, Never>?
}

/// The transcript the Mac published with an episode's audio, kept beside that audio.
///
/// Best effort throughout: a missing transcript or a failed fetch never touches the audio's
/// state. The transcript belongs to the cached revision; when the audio is removed, replaced or
/// the account changes, the transcript goes with it.
extension LibraryAppModel {
    /// The transcript for the audio now on the phone, when there is one.
    func transcript(for entryID: ItemID) -> LibraryTranscript? { transcripts[entryID] }

    /// Loads the transcript for `entryID` from the cache, fetching it once more per session when
    /// the audio is cached but the transcript is not. Call when a screen showing it opens.
    func prepareTranscript(entryID: ItemID) async {
        if let run = transcriptRuns[entryID] {
            await run.task?.value
            return
        }
        let cached = await mediaCache.cachedEntries()[entryID]
        let fetch = cached.map { transcriptRetried[entryID] != $0.revisionID } ?? false
        if fetch, let cached { transcriptRetried[entryID] = cached.revisionID }
        startTranscriptLoad(entryID: entryID, fetchOnMiss: fetch)
        await transcriptRuns[entryID]?.task?.value
    }

    /// Starts loading in the background; `fetchOnMiss` asks the transport when the cache has none.
    func startTranscriptLoad(entryID: ItemID, fetchOnMiss: Bool) {
        transcriptRuns[entryID]?.task?.cancel()
        var run = LibraryTranscriptRun()
        let runID = run.id
        run.task = Task { [weak self] in
            await self?.loadTranscript(entryID, runID: runID, fetchOnMiss: fetchOnMiss)
            if self?.transcriptRuns[entryID]?.id == runID { self?.transcriptRuns[entryID] = nil }
        }
        transcriptRuns[entryID] = run
    }

    /// Stops a load in flight and forgets the transcript; called before its audio is removed.
    func cancelTranscript(entryID: ItemID) {
        transcriptRuns.removeValue(forKey: entryID)?.task?.cancel()
        transcripts[entryID] = nil
    }

    /// Waits for the load for `entryID` to finish. For tests.
    func waitForTranscript(entryID: ItemID) async {
        await transcriptRuns[entryID]?.task?.value
    }

    private func loadTranscript(_ entryID: ItemID, runID: UUID, fetchOnMiss: Bool) async {
        guard let cached = await mediaCache.cachedEntries()[entryID] else {
            if isCurrentTranscript(entryID, runID) { transcripts[entryID] = nil }
            return
        }
        guard isCurrentTranscript(entryID, runID) else { return }
        let revisionID = cached.revisionID
        if transcripts[entryID]?.revisionID == revisionID { return }
        transcripts[entryID] = nil
        if let stored = await mediaCache.cachedTranscript(entryID: entryID, revisionID: revisionID) {
            if isCurrentTranscript(entryID, runID) { transcripts[entryID] = stored }
            return
        }
        guard fetchOnMiss,
              let fetched = try? await transport.transcript(entryID: entryID, revisionID: revisionID),
              fetched.entryID == entryID, fetched.revisionID == revisionID,
              isCurrentTranscript(entryID, runID)
        else { return }
        await mediaCache.storeTranscript(fetched)
        if isCurrentTranscript(entryID, runID) { transcripts[entryID] = fetched }
    }

    private func isCurrentTranscript(_ entryID: ItemID, _ runID: UUID) -> Bool {
        !Task.isCancelled && transcriptRuns[entryID]?.id == runID
    }
}
