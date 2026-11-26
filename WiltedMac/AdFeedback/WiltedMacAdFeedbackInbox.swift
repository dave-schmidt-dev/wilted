import Foundation
import CryptoKit
import Darwin
import OSLog
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

private let inboxLog = Logger(subsystem: "com.zerodelta.wilted", category: "AdFeedbackInbox")

/// One listener verdict on ad removal, as the review inbox keeps it.
///
/// Positions only: nothing here holds transcript or audio, so `ad_feedback_export.py` can turn
/// accepted entries into corpus labels without copying podcast prose into the repository.
struct WiltedMacAdFeedbackEntry: Codable, Equatable, Identifiable, Sendable {
    /// How `originalSeconds` was found.
    enum Mapping: String, Codable, Sendable {
        case mapped
        /// Past the last kept audio, pinned to its end.
        case clamped
        /// The journal held no timeline for the revision, so the original time is unknown.
        case unmapped
    }

    enum Source: String, Codable, Sendable { case mac, phone }

    /// A press counts for the corpus as soon as it is filed (`accepted`); removing it in Settings
    /// sets `dismissed`. `pending` is only read from files written before presses counted at once,
    /// and is treated as `accepted`.
    enum Review: String, Codable, Sendable { case pending, accepted, dismissed }

    /// The ad corpus's label vocabulary (`Producer/Workers/adcorpus/manifest.json`).
    enum CorpusLabel: String, Codable, Sendable, CaseIterable, Identifiable {
        case mustCut = "must-cut"
        case mustKeep = "must-keep"
        case acceptableCut = "acceptable-cut"

        var id: String { rawValue }

        /// In the player's words, so Settings and the Now Playing buttons agree.
        var title: String {
            switch self {
            case .mustCut: "Ad"
            case .mustKeep: AdFeedbackKind.notAnAd.title
            case .acceptableCut: "Either is fine"
            }
        }

        /// What a press means for the corpus unless the listener relabels it.
        static func suggested(for kind: AdFeedbackKind) -> CorpusLabel {
            kind == .notAnAd ? .mustKeep : .mustCut
        }
    }

    /// The removed span the press was about: the nearest seam inside `AdFeedbackWindow`.
    struct NearestCut: Codable, Equatable, Sendable {
        let originalStartSeconds: Double
        let originalEndSeconds: Double
        let preparedSeconds: Double
        let label: String
        /// Signed: positive when the press came after the seam.
        let distanceSeconds: Double
    }

    let id: String
    let kind: AdFeedbackKind
    let itemID: String
    let revisionID: String
    /// Where the listener was in the prepared audio they were hearing.
    let playedSeconds: Double
    /// The same moment in the original episode, the clock corpus labels use.
    let originalSeconds: Double?
    let mapping: Mapping
    let nearestCut: NearestCut?
    /// The preparation that produced `revisionID`, not the pipeline running now.
    let engineVersion: String?
    let pipelineFingerprint: String?
    let createdAt: Date
    let deviceID: String
    let source: Source
    let showTitle: String?
    /// For the inbox only; the export never copies it.
    let episodeTitle: String?
    var review: Review
    var label: CorpusLabel?
    var reviewedAt: Date?
    var handledAt: Date?

    /// The label the export will use: the listener's, else the one the press suggests.
    var effectiveLabel: CorpusLabel { label ?? .suggested(for: kind) }

    /// True unless the listener removed it in Settings.
    var counts: Bool { review != .dismissed }

    /// Builds an entry, mapping the press onto the original episode with `timeline`, the
    /// preparation timeline of exactly `revisionID`.
    static func make(
        id: String, kind: AdFeedbackKind, itemID: ItemID, revisionID: RevisionID, playedSeconds: Double,
        timeline: PreparationStatus.PreparationTimeline?, engineVersion: String?, pipelineFingerprint: String?,
        createdAt: Date, deviceID: String, source: Source, showTitle: String?, episodeTitle: String?
    ) -> WiltedMacAdFeedbackEntry {
        let original = timeline?.originalPosition(forPrepared: playedSeconds)
        let nearest = timeline.flatMap { AdCut.nearest(to: playedSeconds, in: $0.adCuts) }
        return WiltedMacAdFeedbackEntry(
            id: id, kind: kind, itemID: itemID.rawValue, revisionID: revisionID.rawValue, playedSeconds: playedSeconds,
            originalSeconds: original?.seconds,
            mapping: original.map { $0.clamped ? .clamped : .mapped } ?? .unmapped,
            nearestCut: nearest.map {
                NearestCut(originalStartSeconds: $0.originalStartSeconds, originalEndSeconds: $0.originalEndSeconds,
                           preparedSeconds: $0.preparedSeconds, label: $0.label,
                           distanceSeconds: playedSeconds - $0.preparedSeconds)
            },
            engineVersion: engineVersion, pipelineFingerprint: pipelineFingerprint, createdAt: createdAt,
            deviceID: deviceID, source: source, showTitle: showTitle, episodeTitle: episodeTitle,
            review: .accepted, label: nil, reviewedAt: nil, handledAt: nil)
    }
}

/// The ad feedback's durable file: `ad-feedback.json` in the app's state directory, one
/// versioned JSON document replaced atomically on every change. A file this build cannot read is
/// set aside next to it, never overwritten. `ad_feedback_export.py` reads the same file.
actor WiltedMacAdFeedbackInbox {
    static let fileName = "ad-feedback.json"
    static let version = 2

    /// Writes the file's bytes and reports whether the folder sync is certain.
    typealias Writer = @Sendable (Data, URL) throws -> Bool

    private let fileURL: URL?
    private let actionDirectory: URL?
    private let writeBytes: Writer
    private var entries: [WiltedMacAdFeedbackEntry] = []
    private var handledActions: [WiltedMacAdFeedbackActionReceipt] = []
    private var recoveryFailure: String?

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// `fileURL` nil keeps the inbox in memory only (tests and fixtures).
    init(fileURL: URL?, actionDirectory: URL? = nil, write: Writer? = nil) {
        self.fileURL = fileURL
        self.actionDirectory = actionDirectory
        self.writeBytes = write ?? Self.durableWrite
        if let fileURL {
            let recovered = WiltedMacAdFeedbackStoredState.recover(from: fileURL)
            entries = recovered.entries
            handledActions = recovered.handledActions
            recoveryFailure = recovered.failure
            if recovered.failure != nil {
                inboxLog.error("The ad feedback inbox recovery needs attention")
            }
        }
    }

    init(libraryURL: URL, write: Writer? = nil) {
        let directory = libraryURL.deletingLastPathComponent()
        self.init(fileURL: directory.appendingPathComponent(Self.fileName),
                  actionDirectory: directory.appendingPathComponent("ad-feedback-actions", isDirectory: true)
                    .appendingPathComponent("pending", isDirectory: true), write: write)
    }

    /// Newest first.
    func all() -> [WiltedMacAdFeedbackEntry] { entries.sorted { $0.createdAt > $1.createdAt } }

    func recoveryFailureMessage() -> String? { recoveryFailure }

    /// Saves `entry` unless one with its id is already filed (a resent phone intent).
    func add(_ entry: WiltedMacAdFeedbackEntry) throws {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        try persist(entries + [entry])
    }

    /// Undo: forgets the entry entirely.
    func remove(id: String) throws {
        guard entries.contains(where: { $0.id == id }) else { return }
        try persist(entries.filter { $0.id != id })
    }

    func review(id: String, as review: WiltedMacAdFeedbackEntry.Review,
                label: WiltedMacAdFeedbackEntry.CorpusLabel?, at date: Date) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var next = entries
        next[index].review = review
        next[index].label = review == .pending ? nil : label
        next[index].reviewedAt = review == .pending ? nil : date
        try persist(next)
    }

    /// Marks a filed press handled without changing whether it counts or its label.
    func markHandled(id: String, at date: Date) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].counts,
              entries[index].handledAt == nil else { return }
        var next = entries
        next[index].handledAt = date
        try persist(next)
    }

    /// Processes the app-owned local queue. A persisted receipt and handled timestamps share one
    /// atomic replacement, so a crash before queue cleanup cannot repeat the action.
    func processPendingHandledActions(
        at date: Date = Date()
    ) -> WiltedMacAdFeedbackActionProcessingResult {
        if let recoveryFailure { return .init(receipts: [], failure: recoveryFailure) }
        guard let actionDirectory else { return .init(receipts: [], failure: nil) }
        guard Self.isOwnerOnlyDirectory(actionDirectory.deletingLastPathComponent()),
              Self.isOwnerOnlyDirectory(actionDirectory) else {
            return .init(receipts: [], failure: "The private ad-feedback action queue is unavailable.")
        }
        let manager = FileManager.default
        let names: [String]
        do {
            names = try manager.contentsOfDirectory(atPath: actionDirectory.path).sorted()
        } catch {
            return .init(receipts: [], failure: "The private ad-feedback action queue could not be read.")
        }
        var receipts: [WiltedMacAdFeedbackActionReceipt] = []
        var firstFailure: String?
        for name in names where name.hasSuffix(".json") {
            let requestURL = actionDirectory.appendingPathComponent(name)
            guard Self.isOwnerOnlyRegularFile(requestURL) else { continue }
            do {
                let data = try Data(contentsOf: requestURL)
                let envelope: WiltedMacAdFeedbackActionEnvelope
                do {
                    envelope = try Self.decoder.decode(WiltedMacAdFeedbackActionEnvelope.self, from: data)
                } catch {
                    Self.quarantine(requestURL)
                    if firstFailure == nil { firstFailure = "An invalid ad-feedback action was set aside." }
                    continue
                }
                let receipt = try apply(envelope, at: date)
                receipts.append(receipt)
                do {
                    try manager.removeItem(at: requestURL)
                } catch {
                    if firstFailure == nil {
                        firstFailure = "A saved action receipt is waiting for queue cleanup."
                    }
                }
            } catch let error as WiltedMacAdFeedbackActionValidationError {
                Self.quarantine(requestURL)
                if firstFailure == nil { firstFailure = error.localizedDescription }
            } catch let error as WiltedMacAdFeedbackStoreRecoveryError {
                if firstFailure == nil { firstFailure = error.localizedDescription }
            } catch {
                // A failed inbox write leaves the request in place for a safe retry. If its atomic
                // replacement landed with uncertain folder sync, the durable receipt makes retry a no-op.
                if firstFailure == nil { firstFailure = "A handled action could not be saved." }
            }
        }
        return .init(receipts: receipts, failure: firstFailure)
    }

    private func apply(
        _ envelope: WiltedMacAdFeedbackActionEnvelope, at date: Date
    ) throws -> WiltedMacAdFeedbackActionReceipt {
        let digest = envelope.computedPayloadSHA256
        guard Self.isDigest(digest), envelope.actionID == digest, envelope.payloadSHA256 == digest else {
            throw WiltedMacAdFeedbackActionValidationError.invalidEnvelope
        }
        let payload: WiltedMacAdFeedbackActionPayload
        do {
            payload = try Self.decoder.decode(WiltedMacAdFeedbackActionPayload.self, from: envelope.payload)
        } catch {
            throw WiltedMacAdFeedbackActionValidationError.invalidPayload
        }
        try Self.validate(payload)
        if let prior = handledActions.first(where: { $0.actionID == envelope.actionID }) {
            guard prior.payloadSHA256 == digest else {
                throw WiltedMacAdFeedbackActionValidationError.conflictingReplay
            }
            try persist(entries, handledActions: handledActions, requireDurability: true)
            return prior
        }

        let stale = payload.entries.contains { item in
            guard entries.filter({ $0.id == item.identity.id }).count == 1,
                  let current = entries.first(where: { $0.id == item.identity.id }) else { return true }
            return !current.counts || !item.identity.matches(current)
        }
        let links = payload.entries.map { item in
            WiltedMacAdFeedbackActionReceipt.EvidenceLink(
                feedbackID: item.identity.id, itemID: item.identity.itemID,
                revisionID: item.identity.revisionID, caseID: item.caseID,
                sourceHash: item.sourceHash, fixtureID: item.replay.fixtureID,
                replayCommand: item.replay.replayCommand,
                reviewedLabel: item.replay.localEvidence.label,
                reviewedStartSeconds: item.replay.localEvidence.startSeconds,
                reviewedEndSeconds: item.replay.localEvidence.endSeconds,
                reportedPositionSeconds: item.replay.localEvidence.reportedPositionSeconds,
                localVerdictPassed: item.replay.localEvidence.localVerdictPassed,
                reportedPositionWasCut: item.replay.localEvidence.reportedPositionWasCut,
                nearestCutFullyCut: item.replay.localEvidence.nearestCutFullyCut,
                nearestCutAnyCut: item.replay.localEvidence.nearestCutAnyCut)
        }
        if stale {
            let receipt = WiltedMacAdFeedbackActionReceipt(
                actionID: envelope.actionID, payloadSHA256: digest, candidateCommit: payload.candidateCommit,
                replayReportSHA256: payload.replayReportSHA256, outcome: .rejectedStale,
                links: links,
                reason: "A report is missing, dismissed, or no longer matches its replay.", processedAt: date)
            try persist(entries, handledActions: handledActions + [receipt], requireDurability: true)
            return receipt
        }

        var next = entries
        var changed = false
        for item in payload.entries {
            guard let index = next.firstIndex(where: { $0.id == item.identity.id }) else { continue }
            if next[index].handledAt == nil {
                next[index].handledAt = date
                changed = true
            }
        }
        let receipt = WiltedMacAdFeedbackActionReceipt(
            actionID: envelope.actionID, payloadSHA256: digest, candidateCommit: payload.candidateCommit,
            replayReportSHA256: payload.replayReportSHA256,
            outcome: changed ? .applied : .alreadyHandled, links: links,
            reason: nil, processedAt: date)
        try persist(next, handledActions: handledActions + [receipt], requireDurability: true)
        return receipt
    }

    @discardableResult
    private func persist(
        _ next: [WiltedMacAdFeedbackEntry],
        handledActions nextHandledActions: [WiltedMacAdFeedbackActionReceipt]? = nil,
        requireDurability: Bool = false
    ) throws -> Bool {
        if let recoveryFailure {
            throw WiltedMacAdFeedbackStoreRecoveryError.writesPaused(recoveryFailure)
        }
        let savedActions = nextHandledActions ?? handledActions
        var durable = true
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(WiltedMacAdFeedbackStoredState(
                entries: next, handledActions: savedActions))
            durable = try writeBytes(data, fileURL)
            if !durable {
                inboxLog.warning("The ad feedback inbox landed but its folder sync is uncertain")
                if requireDurability { throw WiltedMacAdFeedbackStoreRecoveryError.durabilityUnconfirmed }
            }
        }
        entries = next
        handledActions = savedActions
        return durable
    }

    private static func validate(_ payload: WiltedMacAdFeedbackActionPayload) throws {
        guard payload.schemaVersion == 1,
              payload.candidateBranch == "main" || payload.candidateBranch.hasPrefix("ad-tuning/"),
              isCommit(payload.candidateCommit), isDigest(payload.intakeSnapshotSHA256),
              isDigest(payload.replayReportSHA256), !payload.entries.isEmpty,
              payload.entries.count <= 200 else {
            throw WiltedMacAdFeedbackActionValidationError.invalidPayload
        }
        var ids: Set<String> = []
        for item in payload.entries {
            guard !item.identity.id.isEmpty, !item.identity.itemID.isEmpty, !item.identity.revisionID.isEmpty,
                  !item.caseID.isEmpty, item.sourceHash.hasPrefix("sha256:"),
                  isDigest(String(item.sourceHash.dropFirst("sha256:".count))),
                  ids.insert(item.identity.id).inserted,
                  item.replay.candidateCommit == payload.candidateCommit,
                  item.replay.reportSHA256 == payload.replayReportSHA256,
                  !item.replay.fixtureID.isEmpty, !item.replay.replayCommand.isEmpty,
                  item.replay.replayCommand.count <= 4096, item.replay.isClean,
                  hasExactLocalEvidence(item) else {
                throw WiltedMacAdFeedbackActionValidationError.invalidPayload
            }
        }
    }

    private static func hasExactLocalEvidence(_ item: WiltedMacAdFeedbackActionPayload.Entry) -> Bool {
        let local = item.replay.localEvidence
        let identity = item.identity
        guard local.startSeconds.isFinite, local.endSeconds.isFinite,
              local.reportedPositionSeconds.isFinite, local.startSeconds < local.endSeconds,
              local.reportedPositionSeconds == identity.originalSeconds,
              local.localVerdictPassed else { return false }
        switch identity.kind {
        case .adHere:
            guard let point = identity.originalSeconds else { return false }
            return local.label == "must-cut" && local.startSeconds <= point && point < local.endSeconds
                && local.reportedPositionWasCut
        case .notAnAd:
            guard let point = identity.originalSeconds, let nearestCut = identity.nearestCut else { return false }
            return local.label == "must-keep" && local.startSeconds <= point && point < local.endSeconds
                && local.startSeconds <= nearestCut.originalStartSeconds
                && nearestCut.originalEndSeconds <= local.endSeconds
                && local.nearestCutFullyCut == false && local.nearestCutAnyCut == false
                && !local.reportedPositionWasCut
        case .goodCut:
            guard let nearestCut = identity.nearestCut else { return false }
            return local.label == "must-cut" && local.startSeconds <= nearestCut.originalStartSeconds
                && nearestCut.originalEndSeconds <= local.endSeconds && local.nearestCutFullyCut == true
                && local.nearestCutAnyCut == true
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        isLowercaseHex(value, count: 64)
    }

    private static func isCommit(_ value: String) -> Bool {
        isLowercaseHex(value, count: 40)
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isOwnerOnlyDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid() && (info.st_mode & 0o077) == 0
    }

    private static func isOwnerOnlyRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == getuid() && (info.st_mode & 0o077) == 0
    }

    private static func quarantine(_ url: URL) {
        let aside = url.appendingPathExtension("invalid")
        guard !FileManager.default.fileExists(atPath: aside.path) else { return }
        do { try FileManager.default.moveItem(at: url, to: aside) }
        catch { inboxLog.warning("An invalid ad-feedback action could not be set aside") }
    }

    private static let durableWrite: Writer = { data, url in
#if canImport(WiltedProducer)
        if case .durable = try DurableFile.replace(data, to: url) { return true }
        return false
#else
        try data.write(to: url, options: .atomic)
        return true
#endif
    }
}
