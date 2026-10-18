import Foundation
import SwiftData
import WiltedLibrary

/// The History ordering pass reads only the stable scalar fields needed by
/// `LibraryEpisodeOrdering`; complete episode rows are fetched after the page
/// IDs are selected.
extension LocalLibraryStore {
    /// Returns the ordered IDs for one calculated History page. Scalar keys
    /// are read in stable ID-ordered batches, while the selection heap retains
    /// at most `offset + limit` keys. This bounds full-row hydration, not the
    /// amount of work the store performs while scanning the filtered set.
    func historyOrderedPageIDs(
        matching predicate: Predicate<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>,
        total: Int,
        offset: Int,
        limit: Int,
        sort: LibraryEpisodeOrdering.Sort,
        direction: LibraryEpisodeOrdering.Direction,
        in context: ModelContext
    ) throws -> [String] {
        guard limit > 0, offset >= 0, offset < total, sort != .custom else { return [] }

        let pageLength = min(limit, total - offset)
        let retainedCount = offset + pageLength
        var retained: [LibraryEpisodeOrdering.Key] = []
        retained.reserveCapacity(retainedCount)
        var scanOffset = 0

        while scanOffset < total {
            var descriptor = FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.id, comparator: .lexical)]
            )
            descriptor.propertiesToFetch = [\.id, \.title, \.durationSeconds, \.publishedTime]
            descriptor.fetchOffset = scanOffset
            descriptor.fetchLimit = Self.historyOrderingBatchSize
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }

            for record in batch {
                retain(
                    LibraryEpisodeOrdering.Key(
                        id: record.id,
                        title: record.title,
                        durationSeconds: record.durationSeconds,
                        publishedAt: record.publishedTime
                    ),
                    in: &retained,
                    capacity: retainedCount,
                    sort: sort,
                    direction: direction
                )
            }
            scanOffset += batch.count
        }

        let ordered = LibraryEpisodeOrdering.ordered(retained, sort: sort, direction: direction)
        return ordered.dropFirst(offset).prefix(pageLength).map(\.id)
    }

    private static let historyOrderingBatchSize = 256

    /// Keeps the globally earliest `capacity` keys in a max heap whose root is
    /// the latest retained key. The final small set is ordered by the shared
    /// comparator before the caller slices the requested page.
    private func retain(
        _ key: LibraryEpisodeOrdering.Key,
        in heap: inout [LibraryEpisodeOrdering.Key],
        capacity: Int,
        sort: LibraryEpisodeOrdering.Sort,
        direction: LibraryEpisodeOrdering.Direction
    ) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(key)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard LibraryEpisodeOrdering.precedes(heap[parent], heap[child], sort: sort, direction: direction) else {
                    break
                }
                heap.swapAt(parent, child)
                child = parent
            }
            return
        }

        guard let latestRetained = heap.first,
              LibraryEpisodeOrdering.precedes(key, latestRetained, sort: sort, direction: direction) else { return }
        heap[0] = key
        var parent = 0
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var latest = parent
            if left < heap.count,
               LibraryEpisodeOrdering.precedes(heap[latest], heap[left], sort: sort, direction: direction) {
                latest = left
            }
            if right < heap.count,
               LibraryEpisodeOrdering.precedes(heap[latest], heap[right], sort: sort, direction: direction) {
                latest = right
            }
            guard latest != parent else { break }
            heap.swapAt(parent, latest)
            parent = latest
        }
    }
}
