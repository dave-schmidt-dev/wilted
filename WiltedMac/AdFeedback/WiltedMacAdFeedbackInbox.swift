import Foundation
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

        var title: String {
            switch self {
            case .mustCut: "Must cut"
            case .mustKeep: "Must keep"
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
            review: .accepted, label: nil, reviewedAt: nil)
    }
}

/// The ad feedback's durable file: `ad-feedback.json` in the app's state directory, one
/// versioned JSON document replaced atomically on every change. A file this build cannot read is
/// set aside next to it, never overwritten. `ad_feedback_export.py` reads the same file.
actor WiltedMacAdFeedbackInbox {
    static let fileName = "ad-feedback.json"
    static let version = 1

    /// Writes the file's bytes and reports whether the folder sync is certain.
    typealias Writer = @Sendable (Data, URL) throws -> Bool

    private struct Stored: Codable {
        var version: Int
        var entries: [WiltedMacAdFeedbackEntry]
    }

    private let fileURL: URL?
    private let writeBytes: Writer
    private var entries: [WiltedMacAdFeedbackEntry] = []

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
    init(fileURL: URL?, write: Writer? = nil) {
        self.fileURL = fileURL
        self.writeBytes = write ?? Self.durableWrite
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        if let stored = try? Self.decoder.decode(Stored.self, from: data), stored.version == Self.version {
            entries = stored.entries.map { entry in
                var entry = entry
                if entry.review == .pending { entry.review = .accepted }
                return entry
            }
        } else {
            let aside = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            inboxLog.error("The ad feedback inbox was unreadable and was set aside")
        }
    }

    /// Newest first.
    func all() -> [WiltedMacAdFeedbackEntry] { entries.sorted { $0.createdAt > $1.createdAt } }

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

    private func persist(_ next: [WiltedMacAdFeedbackEntry]) throws {
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(Stored(version: Self.version, entries: next))
            if try !writeBytes(data, fileURL) {
                inboxLog.warning("The ad feedback inbox landed but its folder sync is uncertain")
            }
        }
        entries = next
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
