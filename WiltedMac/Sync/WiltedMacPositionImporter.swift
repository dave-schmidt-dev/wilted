import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer

private let importLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacPositionImport")

/// The Mac's ready audio for an entry it would adopt a position for.
struct WiltedMacImportTarget: Sendable, Equatable {
    var revision: RevisionID
    var durationSeconds: Double
}

/// All store-backed inputs needed to resolve a position, captured in one actor turn.
struct WiltedMacPositionImportProjection: Sendable, Equatable {
    var targets: [ItemID: WiltedMacImportTarget]
    var entries: [LibraryEntry]
    var offers: [ItemID: LibraryMediaOffer]
}

/// The Mac side of adopting positions a phone reported. It reads the store and asks the
/// playback controller to write, so the producer service stays the only writer (W-INV-005).
@MainActor
protocol WiltedMacPositionImportHost: AnyObject {
    /// Ready audio by entry, leaving out entries that are retired or finished; nil when the read failed.
    func associationImportIsCurrent(entryID: ItemID, entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer]) async -> Bool
    /// Targets, entries and offers from one coherent narrow identity read.
    func importProjection() async -> WiltedMacPositionImportProjection?
    /// Asks the playback controller to adopt the position; nil when it could not be asked or failed.
    func applyRemotePosition(_ request: RemotePositionRequest) async -> RemotePositionOutcome?
}

extension WiltedMacPositionImportHost {
    func associationImportIsCurrent(entryID: ItemID, entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer]) async -> Bool { true }
}

/// Pure choice of what to adopt: a candidate becomes a request only for an entry the Mac holds
/// ready audio for at exactly the candidate's revision. A position recorded against another
/// revision is never paired with this one.
enum WiltedMacPositionImport {
    /// Within this many seconds of the end an episode counts as finished (`RemotePositionRules`).
    static let endMargin: Double = 1

    struct ResolvedRequest {
        let source: ImportablePosition
        let request: RemotePositionRequest
    }

    /// The newest epoch/date candidate per raw entry or associated display group.
    /// Selection happens before local eligibility so an unresolved newest alias cannot fall back
    /// to an older record for the same logical episode.
    static func selectedCandidates(
        _ candidates: [ImportablePosition], entries: [LibraryEntry]
    ) -> [ImportablePosition] {
        let associationByMember = Dictionary(uniqueKeysWithValues:
            LibraryEpisodeAssociation.coherentGroups(in: entries).flatMap { association in
                association.memberIDs.map { ($0, association) }
            })
        var seen = Set<ItemID>()
        return candidates.sorted { ($0.epoch, $0.observedAt) > ($1.epoch, $1.observedAt) }.filter { candidate in
            let group = associationByMember[candidate.entryID]
            return seen.insert(group?.representativeID ?? candidate.entryID).inserted
        }
    }

    static func requests(
        candidates: [ImportablePosition], targets: [ItemID: WiltedMacImportTarget],
        entries: [LibraryEntry] = [], offers: [ItemID: LibraryMediaOffer] = [:]
    ) -> [RemotePositionRequest] {
        resolvedRequests(candidates: candidates, targets: targets, entries: entries, offers: offers).map(\.request)
    }

    /// Keep the selected source attached through alias translation and outcome settlement.
    static func resolvedRequests(
        candidates: [ImportablePosition], targets: [ItemID: WiltedMacImportTarget],
        entries: [LibraryEntry] = [], offers: [ItemID: LibraryMediaOffer] = [:]
    ) -> [ResolvedRequest] {
        selectedCandidates(candidates, entries: entries).compactMap {
            resolvedRequest(for: $0, targets: targets, entries: entries, offers: offers)
        }
    }

    static func resolvedRequest(
        for candidate: ImportablePosition, targets: [ItemID: WiltedMacImportTarget],
        entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer]
    ) -> ResolvedRequest? {
        guard let record = try? DevicePlaybackPosition(deviceID: candidate.sourceDeviceID,
                entryID: candidate.entryID, revision: candidate.revision, positionSeconds: candidate.resumeSeconds,
                isPlaying: false, epoch: candidate.epoch) else { return nil }
        let observed = ObservedPlayback(record: record, serverModifiedAt: candidate.observedAt)
        let resolved = HandoffResolver.resumeTarget(observed: [observed], localDeviceID: "mac-position-import",
            entries: entries, localRevision: { targets[$0]?.revision }, mediaOffer: { offers[$0] },
            now: candidate.observedAt, durationSeconds: { targets[$0]?.durationSeconds })
        guard case let .resume(resume) = resolved, let target = targets[resume.entryID] else { return nil }
        let request = RemotePositionRequest(itemID: resume.entryID, revisionID: target.revision,
            positionSeconds: resumeSeconds(candidate, duration: target.durationSeconds),
            durationSeconds: target.durationSeconds, observedAt: candidate.observedAt)
        return ResolvedRequest(source: candidate, request: request)
    }

    /// The recorded position plus what was played since, unless that runs past the end while the
    /// recorded position does not: then the recorded position, so the last stretch is still resumable.
    static func resumeSeconds(_ candidate: ImportablePosition, duration: Double) -> Double {
        let limit = duration - endMargin
        guard duration > 0, candidate.resumeSeconds >= limit, candidate.positionSeconds < limit else {
            return candidate.resumeSeconds
        }
        return candidate.positionSeconds
    }
}

/// Adopts the phone's playback positions into the Mac's stored playback state, so playing an
/// episode on the Mac that was last listened to on the phone starts where the phone stopped.
///
/// Called with every fetch of the device records, which is each of the poller's cycles (the
/// first at sync start). The rules that keep it safe:
/// - Only other devices' records, only for the revision the Mac offers, never a stale epoch
///   (`HandoffPositionImport`), never one that is not newer than the Mac's stored position,
///   never a finished episode, never an episode playing on the Mac (the controller decides).
/// - A record that says the phone is playing resumes ahead of its recorded position by the time
///   since it was saved (bounded), stamped as of now, so each later read of a playing phone is newer.
/// - Idempotent: an adopted position is stored with the time it is valid for, so the same record
///   is `.notNewer` next time, and the importer remembers what it already settled.
/// - A record skipped only because the Mac was playing is tried again on the next cycle.
/// - What was adopted is remembered (`adopted`), so the Mac does not publish the phone's own
///   position back as if it were the Mac's.
/// - Every decision that changes is logged once per entry, because a silent skip was what made
///   "the Mac did not follow the phone" impossible to explain from the log.
@MainActor
final class WiltedMacPositionImporter {
    private struct RejectionInput: Equatable {
        var candidate: ImportablePosition
        var targets: [ItemID: WiltedMacImportTarget]
        var entries: [LibraryEntry]
        var offers: [ItemID: LibraryMediaOffer]
    }

    /// A position stored from another device: what it was and the stamp it was stored with.
    struct Adoption: Equatable {
        let positionSeconds: Double
        let stampedAt: Date
    }

    private let host: any WiltedMacPositionImportHost
    private let deviceID: String
    private let now: @Sendable () -> Date
    private var settled: [ItemID: Date] = [:]
    /// Repeated remote candidates skip resolution only while their typed local proof is unchanged.
    private var rejected: [ItemID: RejectionInput] = [:]
    private var lastNote: [ItemID: String] = [:]
    private var running = false
    private var pending: LibraryDeviceRecords?
    private(set) var appliedCount = 0
    private(set) var resolutionCountForTesting = 0
    private(set) var adopted: [ItemID: Adoption] = [:]

    init(host: any WiltedMacPositionImportHost, deviceID: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.deviceID = deviceID
        self.now = now
    }

    /// Adopts what `records` justify. A call made during a pass runs one more pass afterwards
    /// with the newest records.
    func handle(_ records: LibraryDeviceRecords) async {
        if running {
            pending = records
            return
        }
        running = true
        var next: LibraryDeviceRecords? = records
        while let current = next {
            pending = nil
            await pass(current)
            next = pending
        }
        running = false
    }

    private func pass(_ records: LibraryDeviceRecords) async {
        let candidates = HandoffPositionImport.candidates(records: records, localDeviceID: deviceID, now: now())
        let fresh = candidates.filter { candidate in settled[candidate.entryID].map { candidate.observedAt > $0 } ?? true }
        guard !fresh.isEmpty, let projection = await host.importProjection() else { return }
        let selected = WiltedMacPositionImport.selectedCandidates(fresh, entries: projection.entries)
        var requests: [WiltedMacPositionImport.ResolvedRequest] = []
        for candidate in selected {
            let input = Self.rejectionInput(for: candidate, projection: projection)
            if rejected[candidate.entryID] == input { continue }
            resolutionCountForTesting += 1
            guard let resolved = WiltedMacPositionImport.resolvedRequest(for: candidate, targets: projection.targets,
                entries: projection.entries, offers: projection.offers) else {
                rejected[candidate.entryID] = input
                continue
            }
            rejected[candidate.entryID] = nil
            requests.append(resolved)
        }
        let requested = Set(requests.map { $0.source.entryID })
        for candidate in fresh where !requested.contains(candidate.entryID) {
            note(candidate.entryID, projection.targets[candidate.entryID] == nil
                 ? "not adopted: the Mac has no ready, unfinished audio for it"
                 : "not adopted: the phone's revision is not the one the Mac offers")
        }
        for resolved in requests {
            let request = resolved.request
            let source = resolved.source
            if source.entryID != request.itemID {
                guard await host.associationImportIsCurrent(entryID: request.itemID,
                    entries: projection.entries, offers: projection.offers) else { continue }
            }
            guard let outcome = await host.applyRemotePosition(request) else { continue }
            let detail = "\(Int(request.positionSeconds)) s from \(source.sourceDeviceID)"
                + " (epoch \(source.epoch)\(source.isPlaying ? ", playing" : ""))"
            switch outcome {
            case .applied:
                appliedCount += 1
                settled[source.entryID] = request.observedAt
                adopted[request.itemID] = Adoption(
                    positionSeconds: request.positionSeconds, stampedAt: min(request.observedAt, now()))
                note(request.itemID, "adopted \(detail)", level: .default)
            case .notNewer, .completed, .unusable:
                settled[source.entryID] = request.observedAt
                note(request.itemID, "kept the Mac's stored position (\(outcome)); phone had \(detail)")
            case .playing:
                note(request.itemID, "deferred, the Mac is playing it; phone has \(detail)")
            }
        }
    }

    private static func rejectionInput(
        for candidate: ImportablePosition, projection: WiltedMacPositionImportProjection
    ) -> RejectionInput {
        let rawAssociations = projection.entries.filter { $0.id == candidate.entryID }.compactMap(\.episodeAssociation)
        let relevantIDs = Set([candidate.entryID] + rawAssociations.flatMap(\.memberIDs))
        let groupIDs = Set(rawAssociations.map(\.groupID))
        let relevantEntries = projection.entries.filter { entry in
            relevantIDs.contains(entry.id)
                || entry.episodeAssociation.map { groupIDs.contains($0.groupID) } == true
        }.sorted { $0.id.rawValue < $1.id.rawValue }
        return RejectionInput(
            candidate: candidate,
            targets: Dictionary(uniqueKeysWithValues: projection.targets.filter { relevantIDs.contains($0.key) }),
            entries: relevantEntries,
            offers: Dictionary(uniqueKeysWithValues: projection.offers.filter { relevantIDs.contains($0.key) })
        )
    }

    /// Logs a decision the first time it is made for an entry, and again only when it changes.
    private func note(_ entryID: ItemID, _ message: String, level: OSLogType = .info) {
        guard lastNote[entryID] != message else { return }
        lastNote[entryID] = message
        importLog.log(level: level, "\(entryID.rawValue, privacy: .public): \(message, privacy: .public)")
    }
}

/// `WiltedMacPositionImportHost` over the model: store reads for the targets, the model's
/// playback controller for the writes.
@MainActor
final class WiltedMacModelPositionImportHost: WiltedMacPositionImportHost {
    weak var model: WiltedMacModel?

    init(model: WiltedMacModel) { self.model = model }

    func associationImportIsCurrent(entryID: ItemID, entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer]) async -> Bool {
        guard let store = model?.store, let offer = offers[entryID], model?.store === store,
              let identity = try? await store.podcastLibraryIdentitySnapshot(profile: .publication),
              model?.store === store,
              let current = try? importProjection(from: identity),
              current.entries == entries, current.offers == offers,
              let stored = identity.library.readyRevisions[entryID], stored.revisionID == offer.revisionID,
              stored.revision.contentHash == offer.contentHash, stored.revision.byteCount == offer.byteCount,
              await MediaFetcher.verifies(stored.mediaURL, byteCount: offer.byteCount, contentHash: offer.contentHash),
              model?.store === store,
              let finalIdentity = try? await store.podcastLibraryIdentitySnapshot(profile: .publication),
              model?.store === store,
              let final = try? importProjection(from: finalIdentity) else { return false }
        return final.entries == entries && final.offers == offers
    }

    func importProjection() async -> WiltedMacPositionImportProjection? {
        guard let store = model?.store,
              let identity = try? await store.podcastLibraryIdentitySnapshot(profile: .publication),
              model?.store === store else { return nil }
        return try? importProjection(from: identity)
    }

    private func importProjection(from identity: (
        library: LocalLibraryStore.PodcastLibrarySnapshot,
        associations: [PodcastEpisodeAssociation], states: [ItemID: PodcastEpisodeLogicalState]
    )) throws -> WiltedMacPositionImportProjection {
        let snapshot = identity.library
        let metadata = WiltedMacLocalLibraryStateSource.associationMetadata(
            associations: identity.associations, states: identity.states)
        let state = try WiltedMacLocalLibraryStateSource.state(from: snapshot,
            queue: snapshot.podcastQueue.episodeIDs, playback: nil, deviceID: "mac-position-import", associations: metadata)
        var targets: [ItemID: WiltedMacImportTarget] = [:]
        var offers: [ItemID: LibraryMediaOffer] = [:]
        for (id, stored) in snapshot.readyRevisions {
            if snapshot.retiredAtByEpisode[id] == nil && snapshot.listeningStates[id]?.completedAt == nil {
                targets[id] = WiltedMacImportTarget(
                    revision: stored.revision.revisionID, durationSeconds: stored.revision.durationSeconds)
            }
            guard let download = snapshot.downloads[id], download.status == .completed,
                  download.localURL == stored.mediaURL, download.contentHash == stored.revision.contentHash,
                  download.bytesReceived == stored.revision.byteCount,
                  let proof = snapshot.preparationOutcomes["\(id.rawValue)|\(stored.revisionID.rawValue)"],
                  proof.eligibility != .invalid, proof.episodeID == id, proof.revisionID == stored.revisionID else { continue }
            offers[id] = try? LibraryMediaOffer(entryID: id, revisionID: stored.revisionID,
                contentHash: stored.revision.contentHash, byteCount: stored.revision.byteCount,
                mediaType: stored.revision.mediaType, durationSeconds: stored.revision.durationSeconds,
                preparation: LibraryMediaPreparation(preparedAt: proof.producedAt))
        }
        return WiltedMacPositionImportProjection(targets: targets, entries: state.episodes, offers: offers)
    }

    func applyRemotePosition(_ request: RemotePositionRequest) async -> RemotePositionOutcome? {
        guard let model, let playback = model.playback else { return nil }
        do {
            let outcome = try await playback.applyRemotePosition(request)
            if outcome == .applied {
                if playback.itemID == request.itemID && playback.revisionID == request.revisionID {
                    model.refreshPlaybackReadout(shouldPublishNowPlaying: false)
                }
                model.applyImportedPlaybackPosition(request)
            }
            return outcome
        } catch {
            importLog.error("Position import failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
#endif
