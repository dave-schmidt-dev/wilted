import Foundation
import OSLog
import WiltedLibrary
import WiltedProducer

private let headlineCatalogLog = Logger(subsystem: "com.zerodelta.wilted", category: "HeadlineCatalog")

enum LibraryHeadlineCommandResult: Equatable, Sendable {
    case applied
    case staleRevision
    case rejected(String)
}

/// The Mac's durable owner for Recent, Saved and publisher mute state.
///
/// Projection changes and command receipts share one atomic file replacement. A retried
/// command therefore returns its original result even if the process stopped after applying it.
@MainActor
final class WiltedMacHeadlineCatalogStore {
    static let maximumReceipts = 4_096
    static let reasonUnknownStory = "unknownStory"
    static let reasonUnknownPublisher = "unknownPublisher"
    static let reasonStoryIdentityMismatch = "storyIdentityMismatch"
    static let reasonCommandIDReuse = "commandIDReuse"

    typealias Writer = @Sendable (Data, URL) throws -> DurableFile.ReplacementResult

    private struct Fingerprint: Codable, Equatable {
        var action: String
        var identity: String
        var relatedIdentity: String?
        var link: String?
        var desiredState: Bool
        var basedOnRevision: Int64
    }

    private enum StoredResult: Codable, Equatable {
        case applied
        case staleRevision
        case rejected(String)

        var commandResult: LibraryHeadlineCommandResult {
            switch self {
            case .applied: .applied
            case .staleRevision: .staleRevision
            case let .rejected(reason): .rejected(reason)
            }
        }
    }

    private struct Receipt: Codable, Equatable {
        var fingerprint: Fingerprint
        var result: StoredResult
        var recordedAt: Date
    }

    private struct Stored: Codable {
        var version = 1
        var projection: LibraryHeadlineProjection
        var receipts: [String: Receipt]
        /// Local ordering metadata; old version 1 files decode without it.
        var expiredIdentityAnchors: [String: Date]?
        /// Sports classifications learned from feed categories; this stays local to Mac.
        var sportsStoryIDs: [String]?
    }

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let writeBytes: Writer
    private var current: LibraryHeadlineProjection
    private var receipts: [String: Receipt] = [:]
    /// Keeps bounded expired identities ranked across restarts without changing the CloudKit shape.
    private var expiredIdentityAnchors: [String: Date] = [:]
    /// Category-only sports markers stay beside the local catalog, not in the shared projection.
    private var sportsStoryIDs: Set<String> = []
    private var loadFailed = false

    init(
        fileURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() },
        write: @escaping Writer = { try DurableFile.replace($0, to: $1) }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.writeBytes = write
        let initialDate = now()
        current = try! LibraryHeadlineProjection(
            revision: 0, updatedAt: initialDate, recent: [], saved: [], publishers: [])

        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            guard stored.version == 1, Self.isWithinBounds(stored.projection),
                  stored.receipts.count <= Self.maximumReceipts,
                  (stored.expiredIdentityAnchors?.count ?? 0) <= Self.maximumExpiredIdentityCount,
                  (stored.sportsStoryIDs?.count ?? 0) <= Self.maximumSportsStoryCount,
                  Set(stored.sportsStoryIDs ?? []).count == (stored.sportsStoryIDs ?? []).count else {
                throw LibraryTransportError.transport("headline catalog file exceeds its supported format")
            }
            current = stored.projection
            receipts = stored.receipts
            let storedAnchors = stored.expiredIdentityAnchors ?? [:]
            expiredIdentityAnchors = Dictionary(uniqueKeysWithValues: stored.projection.expiredIdentities.map {
                ($0.id, storedAnchors[$0.id] ?? .distantPast)
            })
            let storyIDs = Set((stored.sportsStoryIDs ?? []).filter { !$0.isEmpty && $0.count <= 1_024 })
            let currentStoryIDs = Set((stored.projection.recent + stored.projection.saved).map(\.id))
            sportsStoryIDs = storyIDs.intersection(currentStoryIDs)
        } catch {
            loadFailed = true
            headlineCatalogLog.error("Headline catalog was unreadable; writes are disabled until repaired: \(String(describing: error), privacy: .public)")
        }
    }

    /// Returns the current projection and durably removes stories outside the 24-hour window.
    func projection(at date: Date) throws -> LibraryHeadlineProjection {
        try ensureWritable()
        try pruneRecent(at: date)
        return current
    }

    /// Merges a Mac feed refresh while retaining saved cards and per-field revisions.
    func mergeRecent(
        _ stories: [LibraryHeadlineStory],
        classifiedSportsStoryIDs: Set<String> = [],
        at date: Date
    ) throws -> LibraryHeadlineProjection {
        try ensureWritable()
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryTransportError.transport("headline catalog date is invalid")
        }
        guard stories.count <= Self.maximumStoryCount else {
            throw LibraryTransportError.transport("headline catalog has too many recent stories")
        }

        var oldByID = Dictionary(uniqueKeysWithValues: current.saved.map { ($0.id, $0) })
        for story in current.recent { oldByID[story.id] = story }
        let cutoff = date.addingTimeInterval(-LibraryHeadlineProjection.recentRetention)
        var expiredByID = Dictionary(uniqueKeysWithValues: current.expiredIdentities.map { ($0.id, $0) })
        var expiredAnchors = expiredIdentityAnchors
        var mergedByID = Dictionary(uniqueKeysWithValues: current.recent
            .filter { $0.recentAnchorAt >= cutoff }
            .map { ($0.id, $0) })
        for incoming in stories {
            let previous = oldByID[incoming.id]
            let expired = expiredByID[incoming.id]
            if let previous,
               (previous.publisherID != incoming.publisherID || previous.link != incoming.link) {
                throw LibraryTransportError.transport("headline story identity changed its publisher or link")
            }
            if let expired,
               (expired.publisherID != incoming.publisherID || expired.link != incoming.link) {
                throw LibraryTransportError.transport("expired headline identity changed its publisher or link")
            }
            expiredByID[incoming.id] = nil
            expiredAnchors[incoming.id] = nil
            let contentChanged = previous.map {
                $0.title != incoming.title || $0.publisherName != incoming.publisherName
                    || $0.publishedAt != incoming.publishedAt
            } ?? true
            mergedByID[incoming.id] = try LibraryHeadlineStory(
                id: incoming.id,
                title: incoming.title,
                publisherID: incoming.publisherID,
                publisherName: incoming.publisherName,
                link: incoming.link,
                publishedAt: incoming.publishedAt,
                firstSeenAt: previous?.firstSeenAt ?? incoming.firstSeenAt,
                lastSeenAt: contentChanged
                    ? max(max(date, incoming.lastSeenAt), previous?.lastSeenAt ?? .distantPast)
                    : (previous?.lastSeenAt ?? incoming.lastSeenAt),
                savedAt: previous?.savedAt,
                savedRevision: previous?.savedRevision ?? expired?.savedRevision ?? incoming.savedRevision)
        }

        let recent = Array(mergedByID.values.filter { $0.recentAnchorAt >= cutoff }
            .sorted { ($0.recentAnchorAt, $0.id) > ($1.recentAnchorAt, $1.id) }
            .prefix(Self.maximumStoryCount))
        var savedByID = Dictionary(uniqueKeysWithValues: current.saved.map { ($0.id, $0) })
        for story in mergedByID.values where story.isSaved { savedByID[story.id] = story }
        let saved = savedByID.values.sorted {
            (($0.savedAt ?? .distantPast), $0.id) > (($1.savedAt ?? .distantPast), $1.id)
        }
        let recentIDs = Set(recent.map(\.id))
        let savedIDs = Set(saved.map(\.id))
        for story in current.recent where story.recentAnchorAt < cutoff && !savedIDs.contains(story.id) {
            expiredByID[story.id] = try LibraryHeadlineStoryIdentity(
                id: story.id, publisherID: story.publisherID, link: story.link, savedRevision: story.savedRevision)
            expiredAnchors[story.id] = story.recentAnchorAt
        }
        for story in mergedByID.values where !recentIDs.contains(story.id) && !savedIDs.contains(story.id) {
            expiredByID[story.id] = try LibraryHeadlineStoryIdentity(
                id: story.id, publisherID: story.publisherID, link: story.link, savedRevision: story.savedRevision)
            expiredAnchors[story.id] = story.recentAnchorAt
        }

        Self.retainNewestExpiredIdentities(&expiredByID, anchors: &expiredAnchors)

        var publishersByID = Dictionary(uniqueKeysWithValues: current.publishers.map { ($0.id, $0) })
        for story in mergedByID.values {
            if let existing = publishersByID[story.publisherID] {
                if existing.name != story.publisherName {
                    publishersByID[story.publisherID] = try LibraryHeadlinePublisher(
                        id: existing.id, name: story.publisherName, isMuted: existing.isMuted, revision: existing.revision)
                }
            } else {
                publishersByID[story.publisherID] = try LibraryHeadlinePublisher(
                    id: story.publisherID, name: story.publisherName, isMuted: false, revision: 0)
            }
        }

        guard recent.count <= Self.maximumStoryCount,
              saved.count <= Self.maximumStoryCount,
              publishersByID.count <= Self.maximumPublisherCount else {
            throw LibraryTransportError.transport("headline catalog exceeds its bounded storage")
        }
        let next = try changedProjection(
            recent: recent,
            saved: saved,
            publishers: publishersByID.values.sorted { $0.id < $1.id },
            expiredIdentities: expiredByID.values.sorted { $0.id < $1.id },
            at: date)
        let retainedSportsStoryIDs = sportsStoryIDs
            .union(classifiedSportsStoryIDs)
            .intersection(Set((recent + saved).map(\.id)))
        guard next != current || retainedSportsStoryIDs != sportsStoryIDs else { return current }
        try save(
            projection: next, receipts: receipts, expiredIdentityAnchors: expiredAnchors,
            sportsStoryIDs: retainedSportsStoryIDs)
        current = next
        expiredIdentityAnchors = expiredAnchors
        sportsStoryIDs = retainedSportsStoryIDs
        return current
    }

    /// Removes topic-filtered stories from Recent while retaining Notebook and sync identities.
    /// Category markers and source IDs let the Mac clean cached stories without changing the shared schema.
    func pruneRecent(
        matching isExcluded: (LibraryHeadlineStory) -> Bool,
        classifiedSportsStoryIDs: Set<String> = [],
        excludedPublisherIDs: Set<String> = [],
        skipKnownSports: Bool = true,
        at date: Date
    ) throws -> LibraryHeadlineProjection {
        try ensureWritable()
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryTransportError.transport("headline catalog date is invalid")
        }

        let cutoff = date.addingTimeInterval(-LibraryHeadlineProjection.recentRetention)
        let savedIDs = Set(current.saved.map(\.id))
        let observedSports = classifiedSportsStoryIDs
        let knownSports = sportsStoryIDs.union(observedSports)
        var expiredByID = Dictionary(uniqueKeysWithValues: current.expiredIdentities.map { ($0.id, $0) })
        var expiredAnchors = expiredIdentityAnchors
        let filteredRecent = try current.recent.filter { story in
            let isExpired = story.recentAnchorAt < cutoff
            let isTopicExcluded = (skipKnownSports
                && (knownSports.contains(story.id) || excludedPublisherIDs.contains(story.publisherID)))
                || isExcluded(story)
            guard isExpired || isTopicExcluded else { return true }
            if !savedIDs.contains(story.id) {
                expiredByID[story.id] = try LibraryHeadlineStoryIdentity(
                    id: story.id, publisherID: story.publisherID, link: story.link,
                    savedRevision: story.savedRevision)
                expiredAnchors[story.id] = story.recentAnchorAt
            }
            return false
        }
        Self.retainNewestExpiredIdentities(&expiredByID, anchors: &expiredAnchors)
        let expired = expiredByID.values.sorted { $0.id < $1.id }
        let retainedSportsStoryIDs = sportsStoryIDs.union(observedSports)
            .intersection(Set((filteredRecent + current.saved).map(\.id)))
        let next = try changedProjection(
            recent: filteredRecent, saved: current.saved, publishers: current.publishers,
            expiredIdentities: expired, at: date)
        guard next != current || expiredAnchors != expiredIdentityAnchors
                || retainedSportsStoryIDs != sportsStoryIDs else { return current }
        try save(
            projection: next, receipts: receipts, expiredIdentityAnchors: expiredAnchors,
            sportsStoryIDs: retainedSportsStoryIDs)
        current = next
        expiredIdentityAnchors = expiredAnchors
        sportsStoryIDs = retainedSportsStoryIDs
        return current
    }

    /// Applies a save command after checking its story identity and saved-state revision.
    func setSaved(
        story: LibraryHeadlineStory,
        isSaved: Bool,
        basedOnRevision: Int64,
        commandID: String,
        at date: Date
    ) throws -> LibraryHeadlineCommandResult {
        try ensureWritable()
        try pruneRecent(at: date)
        let fingerprint = Fingerprint(
            action: "setHeadlineSaved", identity: story.id, relatedIdentity: story.publisherID,
            link: story.link?.absoluteString, desiredState: isSaved, basedOnRevision: basedOnRevision)
        return try apply(commandID: commandID, fingerprint: fingerprint, at: date) { [self] in
            let canonical = current.saved.first(where: { $0.id == story.id })
                ?? current.recent.first(where: { $0.id == story.id })
            let expired = current.expiredIdentities.first(where: { $0.id == story.id })
            guard canonical != nil || expired != nil else {
                return .rejected(Self.reasonUnknownStory)
            }
            let canonicalPublisherID = canonical?.publisherID ?? expired?.publisherID
            let canonicalLink = canonical?.link ?? expired?.link
            guard canonicalPublisherID == story.publisherID, canonicalLink == story.link else {
                return .rejected(Self.reasonStoryIdentityMismatch)
            }
            let savedRevision = canonical?.savedRevision ?? expired?.savedRevision ?? 0
            guard basedOnRevision == savedRevision else { return .staleRevision }
            guard savedRevision < Int64.max else { return .rejected("revisionExhausted") }
            guard (canonical?.isSaved ?? false) != isSaved else { return .applied }

            let publisherName = canonical?.publisherName
                ?? current.publishers.first(where: { $0.id == story.publisherID })?.name
            guard let publisherName else { return .rejected(Self.reasonUnknownPublisher) }

            let replacement = try LibraryHeadlineStory(
                id: canonical?.id ?? story.id,
                title: canonical?.title ?? story.title,
                publisherID: canonicalPublisherID ?? story.publisherID,
                publisherName: publisherName,
                link: canonicalLink,
                publishedAt: canonical?.publishedAt ?? story.publishedAt,
                firstSeenAt: canonical?.firstSeenAt ?? story.firstSeenAt,
                lastSeenAt: canonical?.lastSeenAt ?? story.lastSeenAt,
                savedAt: isSaved ? date : nil, savedRevision: savedRevision + 1)
            return try changeStory(replacement, at: date)
        }
    }

    /// Applies a publisher mute command against that publisher's own revision.
    func setPublisherMuted(
        id: String,
        name: String,
        isMuted: Bool,
        basedOnRevision: Int64,
        commandID: String,
        at date: Date
    ) throws -> LibraryHeadlineCommandResult {
        let fingerprint = Fingerprint(
            action: "setHeadlinePublisherMuted", identity: id, relatedIdentity: nil, link: nil,
            desiredState: isMuted, basedOnRevision: basedOnRevision)
        return try apply(commandID: commandID, fingerprint: fingerprint, at: date) { [self] in
            guard let canonical = current.publishers.first(where: { $0.id == id }) else {
                return .rejected(Self.reasonUnknownPublisher)
            }
            guard basedOnRevision == canonical.revision else { return .staleRevision }
            guard canonical.revision < Int64.max else { return .rejected("revisionExhausted") }
            guard canonical.isMuted != isMuted else { return .applied }
            let replacement = try LibraryHeadlinePublisher(
                id: canonical.id, name: canonical.name, isMuted: isMuted, revision: canonical.revision + 1)
            let publishers = current.publishers.map { $0.id == id ? replacement : $0 }
            try replaceProjection(
                recent: current.recent, saved: current.saved, publishers: publishers,
                expiredIdentities: current.expiredIdentities, at: date)
            return .applied
        }
    }

    /// Dispatches only the two catalog commands. Other intent families remain with their owners.
    func apply(_ intent: LibraryIntent, at date: Date) throws -> LibraryHeadlineCommandResult? {
        switch intent.action {
        case let .setHeadlineSaved(story, isSaved, basedOnRevision):
            return try setSaved(
                story: story, isSaved: isSaved, basedOnRevision: basedOnRevision, commandID: intent.id, at: date)
        case let .setHeadlinePublisherMuted(publisherID, isMuted, basedOnRevision):
            return try setPublisherMuted(
                id: publisherID, name: "", isMuted: isMuted,
                basedOnRevision: basedOnRevision, commandID: intent.id, at: date)
        default:
            return nil
        }
    }

    private func apply(
        commandID: String,
        fingerprint: Fingerprint,
        at date: Date,
        operation: () throws -> LibraryHeadlineCommandResult
    ) throws -> LibraryHeadlineCommandResult {
        try ensureWritable()
        guard !commandID.isEmpty, commandID.count <= 256,
              date.timeIntervalSinceReferenceDate.isFinite, fingerprint.basedOnRevision >= 0 else {
            return .rejected("invalidCommand")
        }
        if let previous = receipts[commandID] {
            return previous.fingerprint == fingerprint ? previous.result.commandResult : .rejected(Self.reasonCommandIDReuse)
        }

        let before = current
        let expiredAnchorsBefore = expiredIdentityAnchors
        let result: LibraryHeadlineCommandResult
        do { result = try operation() }
        catch {
            current = before
            expiredIdentityAnchors = expiredAnchorsBefore
            throw error
        }
        let storedResult: StoredResult
        switch result {
        case .applied: storedResult = .applied
        case .staleRevision: storedResult = .staleRevision
        case let .rejected(reason): storedResult = .rejected(reason)
        }
        var nextReceipts = receipts
        nextReceipts[commandID] = Receipt(fingerprint: fingerprint, result: storedResult, recordedAt: date)
        nextReceipts = Self.boundedReceipts(nextReceipts)
        do { try save(projection: current, receipts: nextReceipts) }
        catch {
            current = before
            expiredIdentityAnchors = expiredAnchorsBefore
            throw error
        }
        receipts = nextReceipts
        return result
    }

    private func changeStory(_ replacement: LibraryHeadlineStory, at date: Date) throws -> LibraryHeadlineCommandResult {
        let recent = current.recent.map { $0.id == replacement.id ? replacement : $0 }
        var saved = current.saved.filter { $0.id != replacement.id }
        if replacement.isSaved { saved.append(replacement) }
        var expired = current.expiredIdentities.filter { $0.id != replacement.id }
        var expiredAnchors = expiredIdentityAnchors
        expiredAnchors[replacement.id] = nil
        if !replacement.isSaved, !recent.contains(where: { $0.id == replacement.id }), !replacement.isRecent(at: date) {
            expired.append(try LibraryHeadlineStoryIdentity(
                id: replacement.id, publisherID: replacement.publisherID, link: replacement.link,
                savedRevision: replacement.savedRevision))
            expiredAnchors[replacement.id] = replacement.recentAnchorAt
        }
        var expiredByID = Dictionary(uniqueKeysWithValues: expired.map { ($0.id, $0) })
        Self.retainNewestExpiredIdentities(&expiredByID, anchors: &expiredAnchors)
        expired = expiredByID.values.sorted { $0.id < $1.id }
        self.expiredIdentityAnchors = expiredAnchors
        try replaceProjection(
            recent: recent, saved: saved, publishers: current.publishers,
            expiredIdentities: expired.sorted { $0.id < $1.id }, at: date)
        return .applied
    }

    private func pruneRecent(at date: Date) throws {
        _ = try pruneRecent(matching: { _ in false }, skipKnownSports: false, at: date)
    }

    private func replaceProjection(
        recent: [LibraryHeadlineStory],
        saved: [LibraryHeadlineStory],
        publishers: [LibraryHeadlinePublisher],
        expiredIdentities: [LibraryHeadlineStoryIdentity],
        at date: Date
    ) throws {
        current = try changedProjection(
            recent: recent, saved: saved, publishers: publishers, expiredIdentities: expiredIdentities, at: date)
    }

    private func changedProjection(
        recent: [LibraryHeadlineStory],
        saved: [LibraryHeadlineStory],
        publishers: [LibraryHeadlinePublisher],
        expiredIdentities: [LibraryHeadlineStoryIdentity],
        at date: Date
    ) throws -> LibraryHeadlineProjection {
        guard recent != current.recent || saved != current.saved || publishers != current.publishers
                || expiredIdentities != current.expiredIdentities else {
            return current
        }
        guard current.revision < Int64.max else {
            throw LibraryTransportError.transport("headline projection revision is exhausted")
        }
        return try LibraryHeadlineProjection(
            generationID: UUID().uuidString,
            revision: current.revision + 1,
            updatedAt: date,
            recent: recent,
            saved: saved,
            publishers: publishers,
            expiredIdentities: expiredIdentities)
    }

    private func save(
        projection: LibraryHeadlineProjection,
        receipts: [String: Receipt],
        expiredIdentityAnchors: [String: Date]? = nil,
        sportsStoryIDs: Set<String>? = nil
    ) throws {
        let sportsIDs = sportsStoryIDs ?? self.sportsStoryIDs
        guard Self.isWithinBounds(projection), receipts.count <= Self.maximumReceipts,
              sportsIDs.count <= Self.maximumSportsStoryCount else {
            throw LibraryTransportError.transport("headline catalog exceeds its bounded storage")
        }
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(
            projection: projection, receipts: receipts,
            expiredIdentityAnchors: expiredIdentityAnchors ?? self.expiredIdentityAnchors,
            sportsStoryIDs: sportsIDs.sorted()))
        let result = try writeBytes(data, fileURL)
        if case let .replacedDirectorySyncUncertain(failure) = result {
            headlineCatalogLog.warning("Headline catalog landed but its folder sync is uncertain: \(failure.description, privacy: .public)")
        }
    }

    private func ensureWritable() throws {
        guard !loadFailed else {
            throw LibraryTransportError.transport("headline catalog is unreadable and requires repair")
        }
    }

    private static let maximumStoryCount = LibraryHeadlineProjectionPage.maximumStories
        * LibraryHeadlineProjectionIndex.maximumPagesPerSection
    private static let maximumPublisherCount = LibraryHeadlineProjectionPage.maximumPublishers
        * LibraryHeadlineProjectionIndex.maximumPagesPerSection
    private static let maximumSportsStoryCount = maximumStoryCount * 2
    static let maximumExpiredIdentityCount = LibraryHeadlineProjectionPage.maximumExpiredIdentities
        * LibraryHeadlineProjectionIndex.maximumPagesPerSection

    private static func retainNewestExpiredIdentities(
        _ identities: inout [String: LibraryHeadlineStoryIdentity],
        anchors: inout [String: Date]
    ) {
        guard identities.count > maximumExpiredIdentityCount else {
            anchors = anchors.filter { identities[$0.key] != nil }
            return
        }
        let retainedIDs = Set(identities.values.sorted {
            let left = anchors[$0.id] ?? .distantPast
            let right = anchors[$1.id] ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }.prefix(maximumExpiredIdentityCount).map(\.id))
        identities = identities.filter { retainedIDs.contains($0.key) }
        anchors = anchors.filter { retainedIDs.contains($0.key) }
    }

    private static func isWithinBounds(_ projection: LibraryHeadlineProjection) -> Bool {
        projection.recent.count <= maximumStoryCount && projection.saved.count <= maximumStoryCount
            && projection.publishers.count <= maximumPublisherCount
            && projection.expiredIdentities.count <= maximumExpiredIdentityCount
    }

    private static func boundedReceipts(_ input: [String: Receipt]) -> [String: Receipt] {
        guard input.count > maximumReceipts else { return input }
        let keep = input.sorted { $0.value.recordedAt > $1.value.recordedAt }.prefix(maximumReceipts)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}
