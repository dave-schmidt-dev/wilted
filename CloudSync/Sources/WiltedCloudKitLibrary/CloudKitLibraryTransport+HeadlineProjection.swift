import CloudKit
import Foundation
import WiltedCloudKit
import WiltedLibrary

/// Serializes multi-record index swaps while allowing ordinary library operations to continue.
actor CloudKitHeadlineProjectionGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else { isLocked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else { isLocked = false; return }
        waiters.removeFirst().resume()
    }
}

// MARK: - Mac-owned headline projection

extension CloudKitLibraryTransport {
    /// Writes immutable bounded pages before replacing the single index that makes them visible.
    public func publishHeadlineProjection(_ projection: LibraryHeadlineProjection) async throws {
        try await CloudKitOperationContext.$caller.withValue(.bulletins) {
            guard isLibraryWriter else {
                throw LibraryTransportError.ownershipViolation("\(deviceID) may not publish headline state")
            }
            await headlineProjectionGate.acquire()
            do {
                try await publishHeadlineProjectionLocked(projection)
                await headlineProjectionGate.release()
            } catch {
                await headlineProjectionGate.release()
                throw error
            }
        }
    }

    /// Reads only the indexed page names, never scanning the CloudKit zone.
    public func fetchHeadlineProjection() async throws -> LibraryHeadlineProjection? {
        try await CloudKitOperationContext.$caller.withValue(.bulletins) {
            let generation = operationGenerationValue
            let owner = observedOwnerToken
            try verifyFetchContext(generation: generation, owner: owner)
            try await driver.ensureZone()
            let indexRecords = try await fetchPresent([mapper.headlineProjectionIndexRecordID])
            try verifyFetchContext(generation: generation, owner: owner)
            guard let record = indexRecords.first else { return nil }
            guard case let .headlineProjectionIndex(index) = try mapper.decode(record) else {
                throw LibraryRecordMapperError.identityMismatch(record.recordID.recordName)
            }
            let requests = try Self.pageIDs(for: index, using: mapper)
            let pageRecords = try await fetchPresent(requests.ids)
            try verifyFetchContext(generation: generation, owner: owner)
            guard pageRecords.count == requests.ids.count else {
                throw LibraryTransportError.transport("headline projection is missing an indexed page")
            }
            var recent: [LibraryHeadlineStory] = []
            var saved: [LibraryHeadlineStory] = []
            var publishers: [LibraryHeadlinePublisher] = []
            var expiredIdentities: [LibraryHeadlineStoryIdentity] = []
            var expected: [String: (LibraryHeadlineProjectionPage.Kind, Int)] = [:]
            for id in requests.ids {
                guard let kind = requests.kinds[id.recordName] else {
                    throw LibraryRecordMapperError.identityMismatch(id.recordName)
                }
                expected[id.recordName] = kind
            }
            for record in pageRecords {
                guard let expectedPage = expected[record.recordID.recordName] else {
                    throw LibraryRecordMapperError.identityMismatch(record.recordID.recordName)
                }
                guard case let .headlineProjectionPage(page) = try mapper.decode(record),
                      page.generationID == index.generationID,
                      expectedPage.0 == page.kind, expectedPage.1 == page.pageIndex else {
                    throw LibraryRecordMapperError.identityMismatch(record.recordID.recordName)
                }
                switch page.kind {
                case .recent: recent.append(contentsOf: page.stories)
                case .saved: saved.append(contentsOf: page.stories)
                case .publishers: publishers.append(contentsOf: page.publishers)
                case .expired: expiredIdentities.append(contentsOf: page.storyIdentities)
                }
            }
            return try LibraryHeadlineProjection(
                generationID: index.generationID,
                revision: index.revision,
                updatedAt: index.updatedAt,
                recent: recent.sorted { ($0.recentAnchorAt, $0.id) > ($1.recentAnchorAt, $1.id) },
                saved: saved.sorted { (($0.savedAt ?? .distantPast), $0.id) > (($1.savedAt ?? .distantPast), $1.id) },
                publishers: publishers.sorted { $0.id < $1.id },
                expiredIdentities: expiredIdentities.sorted { $0.id < $1.id })
        }
    }

    private func publishHeadlineProjectionLocked(_ projection: LibraryHeadlineProjection) async throws {
        let generation = operationGenerationValue
        let owner = observedOwnerToken
        try verifyFetchContext(generation: generation, owner: owner)
        do {
            try await driver.ensureZone()
            let existingIndexRecords = try await fetchPresent([mapper.headlineProjectionIndexRecordID])
            try verifyFetchContext(generation: generation, owner: owner)
            var oldIndex: LibraryHeadlineProjectionIndex?
            if let record = existingIndexRecords.first {
                guard case let .headlineProjectionIndex(value) = try mapper.decode(record) else {
                    throw LibraryRecordMapperError.identityMismatch(record.recordID.recordName)
                }
                oldIndex = value
            } else {
                oldIndex = nil
            }

            let pages = try Self.pages(for: projection)
            let current = try Self.generation(for: projection, pageCounts: Self.pageCounts(pages))
            if let oldIndex, oldIndex.generationID == projection.generationID,
               oldIndex.revision != projection.revision {
                throw LibraryTransportError.transport("headline projection revision changed within a generation")
            }

            // Remove any pages left by an earlier interrupted stage before beginning another.
            if let storedIndex = oldIndex {
                for stale in storedIndex.retiredGenerations + storedIndex.stagedGenerations {
                    try await deletePages(for: stale, generation: generation, owner: owner)
                }
                if !storedIndex.retiredGenerations.isEmpty || !storedIndex.stagedGenerations.isEmpty {
                    let cleaned = try Self.index(
                        matching: storedIndex, retired: [], staged: [])
                    try await writeHeadlineIndex(cleaned, generation: generation, owner: owner)
                    oldIndex = cleaned
                }
            }
            try verifyFetchContext(generation: generation, owner: owner)

            let active = try oldIndex ?? Self.emptyIndex(at: projection.updatedAt)
            if active.generationID == projection.generationID {
                guard active.revision == projection.revision else {
                    throw LibraryTransportError.transport("headline projection index changed without a generation")
                }
                return
            }

            let staging = try Self.index(matching: active, retired: [], staged: [current])
            try await writeHeadlineIndex(staging, generation: generation, owner: owner)
            for page in pages {
                let id = try mapper.recordID(
                    headlineProjectionPage: page.generationID, kind: page.kind, pageIndex: page.pageIndex)
                try await write(name: id.recordName, conflictIsSuccess: true, context: (generation, owner)) { base in
                    try self.mapper.record(headlineProjectionPage: page, existing: base)
                }
            }
            try verifyFetchContext(generation: generation, owner: owner)

            let retired: [LibraryHeadlineProjectionGeneration]
            if active.generationID == Self.emptyGenerationID {
                retired = []
            } else {
                retired = [try LibraryHeadlineProjectionGeneration(
                    id: active.generationID, recentPageCount: active.recentPageCount,
                    savedPageCount: active.savedPageCount, publisherPageCount: active.publisherPageCount,
                    expiredPageCount: active.expiredPageCount)]
            }
            let indexed = try LibraryHeadlineProjectionIndex(
                generationID: projection.generationID, revision: projection.revision, updatedAt: projection.updatedAt,
                recentPageCount: current.recentPageCount, savedPageCount: current.savedPageCount,
                publisherPageCount: current.publisherPageCount, expiredPageCount: current.expiredPageCount,
                retiredGenerations: retired)
            try await writeHeadlineIndex(indexed, generation: generation, owner: owner)
            try verifyFetchContext(generation: generation, owner: owner)

            for old in retired {
                try await deletePages(for: old, generation: generation, owner: owner)
            }
            if !retired.isEmpty {
                let cleaned = try Self.index(matching: indexed, retired: [], staged: [])
                try await writeHeadlineIndex(cleaned, generation: generation, owner: owner)
            }
        } catch {
            throw failure(error)
        }
    }

    private func writeHeadlineIndex(
        _ index: LibraryHeadlineProjectionIndex,
        generation: UInt64,
        owner: String?
    ) async throws {
        try await write(name: mapper.headlineProjectionIndexRecordID.recordName, conflictIsSuccess: false,
                        context: (generation, owner)) { base in
            try self.mapper.record(headlineProjectionIndex: index, existing: base)
        }
    }

    private func deletePages(
        for generationDescriptor: LibraryHeadlineProjectionGeneration,
        generation: UInt64,
        owner: String?
    ) async throws {
        let ids = try Self.pageIDs(for: generationDescriptor, using: mapper).ids
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            let existing = try await fetchPresent(batch)
            guard !existing.isEmpty else { continue }
            await acquire()
            defer { release() }
            guard !quarantined else { throw CloudKitSyncError.quarantined }
            try verifyFetchContext(generation: generation, owner: owner)
            try await driver.ensureZone()
            let result = try await runSend(saves: [], deletes: existing.map(\.recordID))
            try verifyFetchContext(generation: generation, owner: owner)
            if result.zoneMissing {
                throw LibraryTransportError.transport("CloudKit zone reset during headline page cleanup")
            }
            if let failure = result.failed.values.first {
                throw LibraryTransportError.transport("headline page cleanup failed: \(failure.disposition.rawValue)")
            }
            for record in existing { serverRecords.removeValue(forKey: record.recordID.recordName) }
        }
    }

    private static func pages(for projection: LibraryHeadlineProjection) throws -> [LibraryHeadlineProjectionPage] {
        var result: [LibraryHeadlineProjectionPage] = []
        for (kind, stories) in [(LibraryHeadlineProjectionPage.Kind.recent, projection.recent), (.saved, projection.saved)] {
            for (index, chunk) in chunks(stories, size: LibraryHeadlineProjectionPage.maximumStories).enumerated() {
                result.append(try LibraryHeadlineProjectionPage(
                    generationID: projection.generationID, kind: kind, pageIndex: index, stories: chunk))
            }
        }
        for (index, chunk) in chunks(projection.publishers, size: LibraryHeadlineProjectionPage.maximumPublishers).enumerated() {
            result.append(try LibraryHeadlineProjectionPage(
                generationID: projection.generationID, kind: .publishers, pageIndex: index, publishers: chunk))
        }
        for (index, chunk) in chunks(
            projection.expiredIdentities, size: LibraryHeadlineProjectionPage.maximumExpiredIdentities).enumerated() {
            result.append(try LibraryHeadlineProjectionPage(
                generationID: projection.generationID, kind: .expired, pageIndex: index, storyIdentities: chunk))
        }
        let counts = pageCounts(result)
        guard [counts.recent, counts.saved, counts.publishers, counts.expired].allSatisfy({
            $0 <= LibraryHeadlineProjectionIndex.maximumPagesPerSection
        }) else {
            throw LibraryTransportError.transport("headline projection has too many pages")
        }
        return result
    }

    private static let emptyGenerationID = "00000000000000000000000000000000"

    private static func emptyIndex(at date: Date) throws -> LibraryHeadlineProjectionIndex {
        try LibraryHeadlineProjectionIndex(
            generationID: emptyGenerationID, revision: 0, updatedAt: date,
            recentPageCount: 0, savedPageCount: 0, publisherPageCount: 0, expiredPageCount: 0)
    }

    private static func index(
        matching source: LibraryHeadlineProjectionIndex,
        retired: [LibraryHeadlineProjectionGeneration],
        staged: [LibraryHeadlineProjectionGeneration]
    ) throws -> LibraryHeadlineProjectionIndex {
        try LibraryHeadlineProjectionIndex(
            generationID: source.generationID, revision: source.revision, updatedAt: source.updatedAt,
            recentPageCount: source.recentPageCount, savedPageCount: source.savedPageCount,
            publisherPageCount: source.publisherPageCount, expiredPageCount: source.expiredPageCount,
            retiredGenerations: retired, stagedGenerations: staged)
    }

    private static func pageCounts(_ pages: [LibraryHeadlineProjectionPage]) -> (
        recent: Int, saved: Int, publishers: Int, expired: Int
    ) {
        (
            pages.filter { $0.kind == .recent }.count,
            pages.filter { $0.kind == .saved }.count,
            pages.filter { $0.kind == .publishers }.count,
            pages.filter { $0.kind == .expired }.count
        )
    }

    private static func generation(
        for projection: LibraryHeadlineProjection,
        pageCounts: (recent: Int, saved: Int, publishers: Int, expired: Int)
    ) throws -> LibraryHeadlineProjectionGeneration {
        try LibraryHeadlineProjectionGeneration(
            id: projection.generationID,
            recentPageCount: pageCounts.recent,
            savedPageCount: pageCounts.saved,
            publisherPageCount: pageCounts.publishers,
            expiredPageCount: pageCounts.expired)
    }

    private static func pageIDs(
        for index: LibraryHeadlineProjectionIndex,
        using mapper: LibraryRecordMapper
    ) throws -> (ids: [CKRecord.ID], kinds: [String: (LibraryHeadlineProjectionPage.Kind, Int)]) {
        try pageIDs(for: LibraryHeadlineProjectionGeneration(
            id: index.generationID,
            recentPageCount: index.recentPageCount,
            savedPageCount: index.savedPageCount,
            publisherPageCount: index.publisherPageCount,
            expiredPageCount: index.expiredPageCount), using: mapper)
    }

    private static func pageIDs(
        for generation: LibraryHeadlineProjectionGeneration,
        using mapper: LibraryRecordMapper
    ) throws -> (ids: [CKRecord.ID], kinds: [String: (LibraryHeadlineProjectionPage.Kind, Int)]) {
        var ids: [CKRecord.ID] = []
        var kinds: [String: (LibraryHeadlineProjectionPage.Kind, Int)] = [:]
        for (kind, count) in [
            (LibraryHeadlineProjectionPage.Kind.recent, generation.recentPageCount),
            (.saved, generation.savedPageCount),
            (.publishers, generation.publisherPageCount),
            (.expired, generation.expiredPageCount)
        ] {
            for index in 0..<count {
                let id = try mapper.recordID(headlineProjectionPage: generation.id, kind: kind, pageIndex: index)
                ids.append(id)
                kinds[id.recordName] = (kind, index)
            }
        }
        return (ids, kinds)
    }

    private static func chunks<Value>(_ values: [Value], size: Int) -> [[Value]] {
        guard !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map { start in
            Array(values[start..<min(start + size, values.count)])
        }
    }
}
