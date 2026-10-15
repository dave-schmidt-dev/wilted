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

/// The Mac side of adopting positions a phone reported. It reads the store and asks the
/// playback controller to write, so the producer service stays the only writer (W-INV-005).
@MainActor
protocol WiltedMacPositionImportHost: AnyObject {
    /// Ready audio by entry, leaving out entries that are retired or finished; nil when the read failed.
    func associationImportIsCurrent(entryID: ItemID, entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer]) async -> Bool
    func importAssociationContext() async -> (entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer])
    func importTargets() async -> [ItemID: WiltedMacImportTarget]?
    /// Asks the playback controller to adopt the position; nil when it could not be asked or failed.
    func applyRemotePosition(_ request: RemotePositionRequest) async -> RemotePositionOutcome?
}

extension WiltedMacPositionImportHost {
    func associationImportIsCurrent(entryID: ItemID, entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer]) async -> Bool { true }
    func importAssociationContext() async -> (entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer]) { ([], [:]) }
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
        var seen = Set<ItemID>()
        return candidates.sorted { ($0.epoch, $0.observedAt) > ($1.epoch, $1.observedAt) }.compactMap { candidate in
            let group = LibraryEpisodeAssociation.group(for: candidate.entryID, in: entries)
            let key = group?.representativeID ?? candidate.entryID
            guard seen.insert(key).inserted,
                  let record = try? DevicePlaybackPosition(deviceID: candidate.sourceDeviceID,
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
    /// A position stored from another device: what it was and the stamp it was stored with.
    struct Adoption: Equatable {
        let positionSeconds: Double
        let stampedAt: Date
    }

    private let host: any WiltedMacPositionImportHost
    private let deviceID: String
    private let now: @Sendable () -> Date
    private var settled: [ItemID: Date] = [:]
    private var lastNote: [ItemID: String] = [:]
    private var running = false
    private var pending: LibraryDeviceRecords?
    private(set) var appliedCount = 0
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
        guard !fresh.isEmpty, let targets = await host.importTargets() else { return }
        let association = await host.importAssociationContext()
        let requests = WiltedMacPositionImport.resolvedRequests(candidates: fresh, targets: targets,
            entries: association.entries, offers: association.offers)
        let requested = Set(requests.map { $0.source.entryID })
        for candidate in fresh where !requested.contains(candidate.entryID) {
            note(candidate.entryID, targets[candidate.entryID] == nil
                 ? "not adopted: the Mac has no ready, unfinished audio for it"
                 : "not adopted: the phone's revision is not the one the Mac offers")
        }
        for resolved in requests {
            let request = resolved.request
            let source = resolved.source
            if source.entryID != request.itemID {
                guard await host.associationImportIsCurrent(entryID: request.itemID,
                    entries: association.entries, offers: association.offers) else { continue }
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
        guard let store = model?.store, let offer = offers[entryID],
              let snapshot = try? await store.podcastLibrarySnapshot(), let stored = snapshot.readyRevisions[entryID],
              stored.revisionID == offer.revisionID,
              await MediaFetcher.verifies(stored.mediaURL, byteCount: offer.byteCount, contentHash: offer.contentHash),
              model?.store === store else { return false }
        let current = await importAssociationContext()
        return current.entries == entries && current.offers == offers
    }

    func importAssociationContext() async -> (entries: [LibraryEntry], offers: [ItemID: LibraryMediaOffer]) {
        guard let store = model?.store, let snapshot = try? await store.podcastLibrarySnapshot(),
              let metadata = try? await WiltedMacLocalLibraryStateSource.associationMetadata(from: store),
              let state = try? WiltedMacLocalLibraryStateSource.state(from: snapshot,
                queue: snapshot.podcastQueue.episodeIDs, playback: nil, deviceID: "mac-position-import", associations: metadata) else { return ([], [:]) }
        var offers: [ItemID: LibraryMediaOffer] = [:]
        for (id, stored) in snapshot.readyRevisions {
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
        return (state.episodes, offers)
    }

    func importTargets() async -> [ItemID: WiltedMacImportTarget]? {
        guard let store = model?.store, let snapshot = try? await store.podcastLibrarySnapshot() else { return nil }
        var targets: [ItemID: WiltedMacImportTarget] = [:]
        for (id, stored) in snapshot.readyRevisions
        where snapshot.retiredAtByEpisode[id] == nil && snapshot.listeningStates[id]?.completedAt == nil {
            targets[id] = WiltedMacImportTarget(
                revision: stored.revision.revisionID, durationSeconds: stored.revision.durationSeconds)
        }
        return targets
    }

    func applyRemotePosition(_ request: RemotePositionRequest) async -> RemotePositionOutcome? {
        guard let model, let playback = model.playback else { return nil }
        do {
            let outcome = try await playback.applyRemotePosition(request)
            if outcome == .applied {
                if playback.itemID == request.itemID { model.refreshPlaybackReadout(shouldPublishNowPlaying: false) }
                await model.reloadLibraryRows()
            }
            return outcome
        } catch {
            importLog.error("Position import failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
#endif
