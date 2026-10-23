import Foundation
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

/// A ready revision the Mac holds for an entry, with the file that carries its audio.
struct WiltedMacReadyAudio: Sendable, Equatable {
    var revisionID: RevisionID
    var contentHash: String
    var byteCount: Int64
    var mediaType: String
    var durationSeconds: Double
    var fileURL: URL
    var preparation: LibraryMediaPreparation
}

/// Read-only view of what the Mac has ready. It never starts or triggers preparation.
protocol WiltedMacReadyAudioSource: Sendable {
    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio?
    /// Ready audio for every entry on the Larder (queued and not retired), from one read.
    func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio]
    /// The compact transcript the Mac already holds for exactly this revision, or nil.
    func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript?
    /// The transcripts held for exactly these revisions, from one read; entries without one are absent.
    func transcripts(for revisions: [ItemID: RevisionID]) async throws -> [ItemID: LibraryTranscript]
}

extension WiltedMacReadyAudioSource {
    func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? { nil }

    func transcripts(for revisions: [ItemID: RevisionID]) async throws -> [ItemID: LibraryTranscript] {
        var found: [ItemID: LibraryTranscript] = [:]
        for (entryID, revisionID) in revisions {
            if let value = try await transcript(for: entryID, revisionID: revisionID) { found[entryID] = value }
        }
        return found
    }
}

#if canImport(WiltedProducer)
/// `WiltedMacReadyAudioSource` over the existing one-read library snapshot.
struct WiltedMacLocalReadyAudioSource: WiltedMacReadyAudioSource {
    let store: LocalLibraryStore

    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? {
        let snapshot = try await store.podcastLibrarySnapshot(profile: .publication)
        return Self.preparedAudio(in: snapshot)[entryID]
    }

    func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio] {
        let snapshot = try await store.podcastLibrarySnapshot(profile: .publication)
        return Self.preparedAudio(in: snapshot)
    }

    /// Generic ready revisions include raw downloads; only exact preparation proof authorizes export.
    private static func preparedAudio(in snapshot: LocalLibraryStore.PodcastLibrarySnapshot) -> [ItemID: WiltedMacReadyAudio] {
        let episodes = Set(snapshot.episodes.map(\.itemID))
        var prepared: [ItemID: WiltedMacReadyAudio] = [:]
        for id in snapshot.podcastQueue.episodeIDs {
            guard episodes.contains(id), snapshot.removalKindByEpisode[id] == nil,
                  snapshot.retiredAtByEpisode[id] == nil,
                  let stored = snapshot.readyRevisions[id], stored.mediaURL.isFileURL,
                  let download = snapshot.downloads[id], download.status == .completed,
                  download.localURL == stored.mediaURL,
                  download.contentHash == stored.revision.contentHash,
                  download.bytesReceived == stored.revision.byteCount,
                  let outcome = snapshot.preparationOutcomes["\(id.rawValue)|\(stored.revision.revisionID.rawValue)"],
                  outcome.episodeID == id, outcome.revisionID == stored.revision.revisionID,
                  outcome.eligibility != .invalid else { continue }
            prepared[id] = Self.audio(stored, preparedAt: outcome.producedAt)
        }
        return prepared
    }

    private static func audio(_ stored: StoredAudioRevision, preparedAt: Timestamp) -> WiltedMacReadyAudio {
        let revision = stored.revision
        return WiltedMacReadyAudio(
            revisionID: revision.revisionID, contentHash: revision.contentHash, byteCount: revision.byteCount,
            mediaType: revision.mediaType, durationSeconds: revision.durationSeconds, fileURL: stored.mediaURL,
            preparation: LibraryMediaPreparation(preparedAt: preparedAt)
        )
    }

    func transcript(for entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        let stored = try await store.podcastLibrarySnapshot().transcripts["\(entryID.rawValue)|\(revisionID.rawValue)"]
        guard let stored else { return nil }
        return LibraryTranscript.capped(entryID: entryID, from: stored, cuts: await cuts(for: entryID, revisionID: revisionID))
    }

    func transcripts(for revisions: [ItemID: RevisionID]) async throws -> [ItemID: LibraryTranscript] {
        let stored = try await store.podcastLibrarySnapshot().transcripts
        var found: [ItemID: LibraryTranscript] = [:]
        for (entryID, revisionID) in revisions {
            if let value = stored["\(entryID.rawValue)|\(revisionID.rawValue)"],
               let capped = LibraryTranscript.capped(
                entryID: entryID, from: value, cuts: await cuts(for: entryID, revisionID: revisionID)) {
                found[entryID] = capped
            }
        }
        return found
    }

    /// The revision's preparation cuts for the phone's feedback buttons; nil when the journal holds
    /// no timeline for it, so the phone falls back to offering every action.
    private func cuts(for entryID: ItemID, revisionID: RevisionID) async -> [AdCut]? {
        (try? await store.latestPreparationTimeline(for: entryID, revisionID: revisionID))?.adCuts
    }
}
#endif
