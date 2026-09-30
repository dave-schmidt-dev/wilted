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
    func importTargets() async -> [ItemID: WiltedMacImportTarget]?
    /// Asks the playback controller to adopt the position; nil when it could not be asked or failed.
    func applyRemotePosition(_ request: RemotePositionRequest) async -> RemotePositionOutcome?
}

/// Pure choice of what to adopt: a candidate becomes a request only for an entry the Mac holds
/// ready audio for at exactly the candidate's revision. A position recorded against another
/// revision is never paired with this one.
enum WiltedMacPositionImport {
    /// Within this many seconds of the end an episode counts as finished (`RemotePositionRules`).
    static let endMargin: Double = 1

    static func requests(
        candidates: [ImportablePosition], targets: [ItemID: WiltedMacImportTarget]
    ) -> [RemotePositionRequest] {
        candidates.compactMap { candidate in
            guard let target = targets[candidate.entryID], target.revision == candidate.revision else { return nil }
            return RemotePositionRequest(
                itemID: candidate.entryID, revisionID: target.revision,
                positionSeconds: resumeSeconds(candidate, duration: target.durationSeconds),
                durationSeconds: target.durationSeconds, observedAt: candidate.observedAt)
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
/// Called with every fetch of the device records: the poller's cycles (first at sync start) and
/// the fresh read a Mac Play press makes. The rules that keep it safe:
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
    private var waiters: [CheckedContinuation<Void, Never>] = []
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
        let finished = waiters
        waiters = []
        for waiter in finished { waiter.resume() }
    }

    /// Like `handle`, but returns only once `records` have been acted on, including when a pass
    /// was already running. For a Mac Play press, which must not start the audio before the
    /// phone's position is stored.
    func handleAwaiting(_ records: LibraryDeviceRecords) async {
        guard running else { return await handle(records) }
        pending = records
        await withCheckedContinuation { waiters.append($0) }
    }

    private func pass(_ records: LibraryDeviceRecords) async {
        let candidates = HandoffPositionImport.candidates(records: records, localDeviceID: deviceID, now: now())
        let fresh = candidates.filter { candidate in settled[candidate.entryID].map { candidate.observedAt > $0 } ?? true }
        guard !fresh.isEmpty, let targets = await host.importTargets() else { return }
        let requests = WiltedMacPositionImport.requests(candidates: fresh, targets: targets)
        let requested = Set(requests.map(\.itemID))
        for candidate in fresh where !requested.contains(candidate.entryID) {
            note(candidate.entryID, targets[candidate.entryID] == nil
                 ? "not adopted: the Mac has no ready, unfinished audio for it"
                 : "not adopted: the phone's revision is not the one the Mac offers")
        }
        for request in requests {
            guard let outcome = await host.applyRemotePosition(request) else { continue }
            let source = candidates.first { $0.entryID == request.itemID }
            let detail = "\(Int(request.positionSeconds)) s from \(source?.sourceDeviceID ?? "another device")"
                + " (epoch \(source?.epoch ?? 0)\(source?.isPlaying == true ? ", playing" : ""))"
            switch outcome {
            case .applied:
                appliedCount += 1
                settled[request.itemID] = request.observedAt
                adopted[request.itemID] = Adoption(
                    positionSeconds: request.positionSeconds, stampedAt: min(request.observedAt, now()))
                note(request.itemID, "adopted \(detail)", level: .default)
            case .notNewer, .completed, .unusable:
                settled[request.itemID] = request.observedAt
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
