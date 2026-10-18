import CryptoKit
import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    public func save(article: Article) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.ArticleRecord>())
        if let existing = records.first(where: { $0.id == article.itemID.rawValue }) {
            existing.canonicalURL = article.canonicalURL.absoluteString; existing.title = article.title
            existing.source = article.source; existing.author = article.author
            existing.publishedTime = article.publishedTime?.date; existing.createdAt = article.createdAt.date
            existing.isRemoved = article.isDeleted; existing.schemaVersion = LocalLibrarySchemaVersion.current.rawValue
        } else { context.insert(LocalLibrarySchemaV17Models.ArticleRecord(article)) }
        try context.save()
    }

    public func article(for itemID: ItemID) throws -> Article? {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.ArticleRecord>()).first(where: { $0.id == itemID.rawValue }) else { return nil }
        return try Article(itemID: try ItemID(rawValue: record.id), canonicalURL: URL(string: record.canonicalURL)!,
                           title: record.title, source: record.source, author: record.author,
                           publishedTime: record.publishedTime.map(Timestamp.init), createdAt: Timestamp(record.createdAt), isDeleted: record.isRemoved)
    }

    /// Marks an article as saved from `feedID`'s feed. An article that already
    /// has a feed keeps it, so a second feed listing the same page never takes
    /// it over. Returns false when the article does not exist.
    @discardableResult
    public func assign(articleID: ItemID, toFeed feedID: ItemID) throws -> Bool {
        let context = ModelContext(container)
        guard let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.ArticleRecord>())
            .first(where: { $0.id == articleID.rawValue }) else { return false }
        if record.feedID == nil {
            record.feedID = feedID.rawValue
            try context.save()
        }
        return true
    }

    /// The feed an article was saved from; nil for one added by hand.
    public func feedID(forArticle articleID: ItemID) throws -> ItemID? {
        let context = ModelContext(container)
        let record = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.ArticleRecord>())
            .first(where: { $0.id == articleID.rawValue })
        return try record?.feedID.map { try ItemID(rawValue: $0) }
    }

    /// The live (not removed) articles saved from `feedID`'s feed.
    public func articleIDs(forFeed feedID: ItemID) throws -> [ItemID] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.ArticleRecord>())
            .filter { $0.feedID == feedID.rawValue && !$0.isRemoved }
            .map { try ItemID(rawValue: $0.id) }
    }

    public func articles() throws -> [Article] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.ArticleRecord>())
            .sorted { $0.createdAt > $1.createdAt }
            .compactMap { record in
                guard let itemID = try? ItemID(rawValue: record.id),
                      let canonicalURL = URL(string: record.canonicalURL) else { return nil }
                return try? Article(
                    itemID: itemID, canonicalURL: canonicalURL, title: record.title, source: record.source,
                    author: record.author, publishedTime: record.publishedTime.map(Timestamp.init),
                    createdAt: Timestamp(record.createdAt), isDeleted: record.isRemoved
                )
            }
    }

    public func saveReadyRevision(_ revision: AudioRevision, mediaURL: URL) throws {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = records.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .readyRevision)
            }
            return
        }
        context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        try context.save()
    }

    public func save(revision: AudioRevision, mediaURL: URL) throws { try saveReadyRevision(revision, mediaURL: mediaURL) }

    /// Atomically saves immutable audio metadata and the transcript produced from the
    /// same extracted text. Identity mismatch fails before either value is committed.
    public func saveReadyRevision(
        _ revision: AudioRevision,
        mediaURL: URL,
        transcript: Transcript,
        lifetimeStatistics: [LifetimeStatisticContribution] = []
    ) throws {
        guard transcript.itemID == revision.itemID, transcript.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        let context = ModelContext(container)
        let revisionRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisionRecords.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .readyRevisionWithTranscript)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        }
        try upsert(transcript, in: context)
        try appendLifetimeStatistics(lifetimeStatistics, in: context)
        try context.save()
    }

    /// The no-audio-change preparation success path: the ready revision and
    /// its outcome are inserted in the same save, so nothing can observe one
    /// durable without the other.
    public func saveReadyRevision(
        _ revision: AudioRevision,
        mediaURL: URL,
        transcript: Transcript,
        outcome: PodcastPreparationOutcome,
        lifetimeStatistics: [LifetimeStatisticContribution] = []
    ) throws {
        guard transcript.itemID == revision.itemID, transcript.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        guard outcome.episodeID == revision.itemID, outcome.revisionID == revision.revisionID else {
            throw LocalLibraryStoreError.revisionBelongsToDifferentItem
        }
        let context = ModelContext(container)
        let revisionRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        if let existing = revisionRecords.first(where: { $0.id == revision.revisionID.rawValue }) {
            guard existing.itemID == revision.itemID.rawValue,
                  existing.contentHash == revision.contentHash,
                  existing.mediaURL == mediaURL.absoluteString else {
                throw LocalLibraryStoreError.immutableRevision(revision.revisionID, site: .readyRevisionWithOutcome)
            }
        } else {
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: mediaURL))
        }
        try upsert(transcript, in: context)
        try upsertPreparationOutcome(outcome, in: context)
        try appendLifetimeStatistics(lifetimeStatistics, in: context)
        try context.save()
    }

    /// Saves one versioned transcript without changing its item or revision identity.
    public func save(transcript: Transcript) throws {
        let context = ModelContext(container)
        try upsert(transcript, in: context)
        try context.save()
    }

    /// Returns the transcript belonging to the newest revision for an item.
    ///
    /// Retired episodes keep their transcript records after their media
    /// revisions are removed, so an item without a revision falls back to the
    /// newest transcript by update time. A record with unavailable content is
    /// still meaningful and is returned rather than replaced by older text.
    public func latestTranscript(for itemID: ItemID) throws -> Transcript? {
        let context = ModelContext(container)
        let rawItemID = itemID.rawValue
        let transcripts = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>(
                predicate: #Predicate { $0.itemID == rawItemID }
            )
        )
        guard !transcripts.isEmpty else { return nil }

        let revisions = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>(
                predicate: #Predicate { $0.itemID == rawItemID }
            )
        )
        let selected: LocalLibrarySchemaV7Models.TranscriptRecord?
        if let newestRevision = revisions.max(by: {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }) {
            selected = transcripts.first(where: { $0.revisionID == newestRevision.id })
        } else {
            selected = transcripts.max {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.revisionID < $1.revisionID
            }
        }
        guard let selected else { return nil }
        return try decodeTranscript(selected)
    }

    /// Item identifiers whose current transcript contains `query`.
    ///
    /// The search runs here rather than in a presentation layer because a
    /// transcript is tens of kilobytes of text the library list deliberately
    /// does not carry. Asking the store "which items say this" costs one
    /// query; loading every transcript into a view model to ask the same
    /// question does not survive a library of any size.
    ///
    /// Only an item's newest revision is consulted. Revisions accumulate -- a
    /// re-prepared episode keeps the transcript of the audio it replaced --
    /// and that older text still holds the advertising the cut removed. So
    /// matching every revision would hand the reader an episode whose
    /// transcript no longer contains the words they searched for, which reads
    /// as the search being broken rather than as history being kept.
    public func itemIDsWithTranscript(matching query: String) throws -> Set<ItemID> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let context = ModelContext(container)
        let matched = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>(
                predicate: #Predicate { ($0.text?.localizedStandardContains(needle)) == true }
            )
        )
        guard !matched.isEmpty else { return [] }

        var newestRevision: [String: (id: String, createdAt: Date)] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()) {
            if let held = newestRevision[record.itemID], held.createdAt >= record.createdAt { continue }
            newestRevision[record.itemID] = (record.id, record.createdAt)
        }

        var found: Set<ItemID> = []
        for record in matched where newestRevision[record.itemID]?.id == record.revisionID {
            guard let id = try? ItemID(rawValue: record.itemID) else { continue }
            found.insert(id)
        }
        return found
    }

    func upsert(_ transcript: Transcript, in context: ModelContext) throws {
        let id = "\(transcript.itemID.rawValue)|\(transcript.revisionID.rawValue)"
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>())
        if let existing = records.first(where: { $0.id == id }) {
            existing.availability = transcript.availability.rawValue
            existing.text = transcript.text
            existing.format = transcript.format.rawValue
            existing.languageCode = transcript.languageCode
            existing.updatedAt = transcript.updatedAt.date
            existing.schemaVersion = transcript.schemaVersion
            existing.timing = transcript.timing.rawValue
            existing.cues = try transcript.cues.map(TranscriptCueCodec.encode)
        } else {
            context.insert(try LocalLibrarySchemaV7Models.TranscriptRecord(transcript))
        }
    }

    func decodeTranscript(_ record: LocalLibrarySchemaV7Models.TranscriptRecord) throws -> Transcript {
        guard let availability = TranscriptAvailability(rawValue: record.availability),
              let format = TranscriptFormat(rawValue: record.format) else {
            throw LocalLibraryStoreError.invalidPreparationStatus("transcript")
        }
        // A row written before store version 7 has a null `timing`, which is
        // exactly "untimed". A row with a value the running build does not
        // recognise is a different matter: reading it as untimed would drop
        // cues a newer build meant to keep, so it fails instead.
        let timing: TranscriptTiming
        if let raw = record.timing {
            guard let parsed = TranscriptTiming(rawValue: raw) else {
                throw LocalLibraryStoreError.invalidPreparationStatus("transcript.timing")
            }
            timing = parsed
        } else {
            timing = .none
        }
        let cues = try record.cues.map(TranscriptCueCodec.decode)
        return try Transcript(itemID: ItemID(rawValue: record.itemID),
                              revisionID: RevisionID(rawValue: record.revisionID),
                              availability: availability, text: record.text, format: format,
                              languageCode: record.languageCode, timing: timing, cues: cues,
                              updatedAt: Timestamp(record.updatedAt),
                              schemaVersion: record.schemaVersion)
    }

    public func readyRevision(for itemID: ItemID, revisionID: RevisionID? = nil) throws -> StoredAudioRevision? {
        let trace = LocalLibraryStoreStageTrace.start()
        defer { if let trace { LocalLibraryStoreStageTrace.record(.revisionFetch, since: trace) } }
        let context = ModelContext(container)
        let rawItemID = itemID.rawValue
        let predicate: Predicate<LocalLibrarySchemaV3Models.RevisionRecord>
        if let rawRevisionID = revisionID?.rawValue {
            predicate = #Predicate { $0.itemID == rawItemID && $0.id == rawRevisionID }
        } else {
            predicate = #Predicate { $0.itemID == rawItemID }
        }
        var descriptor = FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>(
            predicate: predicate, sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let records = try context.fetch(descriptor)
        guard let record = records.first, let mediaURLString = record.mediaURL, let mediaURL = URL(string: mediaURLString) else { return nil }
        let revision = try AudioRevision(itemID: itemID, revisionID: RevisionID(rawValue: record.id), durationSeconds: record.durationSeconds,
                                         byteCount: record.byteCount, contentHash: record.contentHash, mediaType: record.mediaType,
                                         createdAt: Timestamp(record.createdAt), schemaVersion: record.schemaVersion)
        return StoredAudioRevision(revision: revision, mediaURL: mediaURL)
    }

    /// Newest ready revision per item, from one fetch instead of one per
    /// item. Matches `readyRevision(for:)` with no `revisionID` exactly: only
    /// the newest revision counts, and a newest revision with no `mediaURL`
    /// means that item has no ready revision -- no fallback to an older one.
    /// A record that fails `AudioRevision` validation is skipped rather than
    /// thrown, matching every call site that fed this helper: two reconcile
    /// call sites resolved a single item's revision with `try?` and must
    /// keep processing the rest of the library on a malformed row, not abort
    /// reconciliation for every item because one is bad.
    nonisolated internal func newestReadyRevisionsByItemID(in context: ModelContext) throws -> [String: StoredAudioRevision] {
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
        var newestByItemID: [String: LocalLibrarySchemaV3Models.RevisionRecord] = [:]
        for record in records {
            if let existing = newestByItemID[record.itemID], existing.createdAt >= record.createdAt { continue }
            newestByItemID[record.itemID] = record
        }
        var result: [String: StoredAudioRevision] = [:]
        for (itemIDRaw, record) in newestByItemID {
            guard let mediaURLString = record.mediaURL, let mediaURL = URL(string: mediaURLString),
                  let itemID = try? ItemID(rawValue: itemIDRaw),
                  let revision = try? AudioRevision(itemID: itemID, revisionID: RevisionID(rawValue: record.id), durationSeconds: record.durationSeconds,
                                                    byteCount: record.byteCount, contentHash: record.contentHash, mediaType: record.mediaType,
                                                    createdAt: Timestamp(record.createdAt), schemaVersion: record.schemaVersion)
            else { continue }
            result[itemIDRaw] = StoredAudioRevision(revision: revision, mediaURL: mediaURL)
        }
        return result
    }

    nonisolated internal func newestReadyRevisionsByItemID() throws -> [String: StoredAudioRevision] {
        try newestReadyRevisionsByItemID(in: ModelContext(container))
    }

    /// Resolves one podcast revision without migrating any existing identity.
    ///
    /// New podcast rows include their episode identity, while older rows only
    /// include their content hash. Looking up the new form first keeps new
    /// downloads item-safe; accepting a same-item legacy row keeps existing
    /// media, transcripts, and playback bindings intact.
    public func resolvePodcastRevision(itemID: ItemID, contentHash: String) throws -> RevisionID {
        let namespaced = try RevisionID.derive(
            podcastDownloadedAudioItemID: itemID,
            contentHash: contentHash
        )
        let legacy = try RevisionID.derive(downloadedAudioContentHash: contentHash)
        let records = try ModelContext(container)
            .fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())

        if records.contains(where: {
            $0.id == namespaced.rawValue &&
                $0.itemID == itemID.rawValue &&
                $0.contentHash == contentHash
        }) {
            return namespaced
        }
        if records.contains(where: {
            $0.id == legacy.rawValue &&
                $0.itemID == itemID.rawValue &&
                $0.contentHash == contentHash
        }) {
            return legacy
        }
        return namespaced
    }

    public func revisions(for itemID: ItemID) throws -> [StoredAudioRevision] {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>()).filter { $0.itemID == itemID.rawValue }.compactMap { record in
            guard let value = record.mediaURL, let mediaURL = URL(string: value) else { return nil }
            let revision = try? AudioRevision(itemID: itemID, revisionID: RevisionID(rawValue: record.id), durationSeconds: record.durationSeconds,
                                              byteCount: record.byteCount, contentHash: record.contentHash, mediaType: record.mediaType,
                                              createdAt: Timestamp(record.createdAt), schemaVersion: record.schemaVersion)
            return revision.map { StoredAudioRevision(revision: $0, mediaURL: mediaURL) }
        }
    }

}
