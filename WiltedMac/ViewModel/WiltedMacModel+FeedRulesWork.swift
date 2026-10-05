import Foundation
import WiltedDomain
import WiltedProducer

/// Taking back the download and preparation requests an Apply issued.
extension WiltedMacModel {
    /// True when the episode has a preparation request waiting: one this
    /// process holds, or a durable ticket that has not started.
    func holdsPreparationRequest(for id: ItemID, store: LocalLibraryStore) async -> Bool {
        if preparationRequestSequences[id.rawValue] != nil { return true }
        return await isWaiting(.podcastPreparation, id, store)
    }

    /// Withdraws the episode's preparation request and cancels its download if
    /// that has not started. A transfer already running, or finished, stays.
    func withdrawUnstartedKeepWork(for id: ItemID, store: LocalLibraryStore) async {
        let raw = id.rawValue
        if await holdsPreparationRequest(for: id, store: store) { withdrawPreparationRequest(for: raw) }
        guard await isWaiting(.podcastDownload, id, store) else { return }
        podcastDownloadTasks[raw]?.cancel()
        await recordWorkTicketTransition(kind: .podcastDownload, subjectID: raw, state: .cancelled)
        // Release the claim the admission took, unless a transfer has begun on it.
        if let claim = try? await store.downloads().first(where: { $0.episodeID == id }), claim.status == .queued,
           let released = try? PodcastDownload(episodeID: id, status: .cancelled, updatedAt: Timestamp(Date())) {
            try? await store.save(download: released)
        }
        updateEpisode(raw) { $0.downloadState = .cancelled }
    }

    private func isWaiting(_ kind: WorkTicketKind, _ id: ItemID, _ store: LocalLibraryStore) async -> Bool {
        guard let ticket = try? await store.workTicket(kind: kind, subjectID: id.rawValue) else { return false }
        return ticket.state == .pending || ticket.state == .deferred
    }
}
