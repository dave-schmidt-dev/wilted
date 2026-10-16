import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryAppModel {
    /// Queued entries the phone can play or fetch: a ready or available offer, a transfer under way, or audio
    /// already cached.
    var preparedIDs: (offered: Set<ItemID>, onPhone: Set<ItemID>) {
        let inFlight = Set(media.filter { $0.value.isInFlight }.keys)
        let onPhone = Set(media.filter { $0.value == .onPhone }.keys)
        return (readyOffers.union(inFlight), onPhone)
    }

    /// List and detail share the retained snapshot's effective media projection.
    /// Each caller captures live preparation/cache sets once; reports never add an ID.
    func effectiveLarderMediaIDs(
        prepared: (offered: Set<ItemID>, onPhone: Set<ItemID>)
    ) -> (offered: Set<ItemID>, onPhone: Set<ItemID>) {
        refreshEpisodeProjection()
        let groups = completedDisplayContent == nil ? projectedEpisodeGroupsByMember : completedDisplayGroupsByMember
        let offered: Set<ItemID>
        if let retained = completedDisplayRows {
            // Preserve cancellation/progress for actual live transfers without admitting
            // newly observed offers while the last completed display is retained.
            let inFlight = Set(media.filter { $0.value.isInFlight }.keys)
            offered = Set(retained.map(\.id)).union(inFlight)
        } else {
            offered = prepared.offered.union(cachedDisplayIDs)
        }
        return (logicalIDs(offered, groupsByMember: groups), logicalIDs(prepared.onPhone, groupsByMember: groups))
    }

    /// Prepared audio plus read-only preparation reports; media filters retain their meaning.
    var visibleRows: [LibraryRow] {
        let ids = effectiveLarderMediaIDs(prepared: preparedIDs)
        let display = completedDisplayContent ?? projectedEpisodeContent
        let groups = completedDisplayContent == nil ? projectedEpisodeGroupsByMember : completedDisplayGroupsByMember
        var rows = completedDisplayRows.map {
            LibraryRowBuilder.logicalRows($0, content: display, checkpoints: checkpoints,
                                          clock: clockFormat, started: startedEntries, groupsByMember: groups)
        } ?? logicalQueued
        if completedDisplayRows != nil {
            // The retained display snapshot can preserve certified media, but a report
            // must always come from the current mirror, including withdrawal/clear.
            let current = Dictionary(logicalQueued.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rows = rows.map { row in
                var row = row
                row.preparationAnnotations = current[row.id]?.preparationAnnotations ?? []
                return row
            }
            let shown = Set(rows.map(\.id))
            rows += logicalQueued.filter { !shown.contains($0.id) && !$0.preparationAnnotations.isEmpty }
        }
        let preparationIDs = Set(rows.filter { !$0.preparationAnnotations.isEmpty }.map(\.id))
        return LibraryListing.rows(rows, offered: ids.offered,
            onPhone: ids.onPhone, filter: filter, kind: kindFilter, query: searchText,
            progress: logicalProgress, finished: logicalFinished, preparationIDs: preparationIDs)
    }

    /// How many queued entries are prepared, before any filter or search; tells an empty Larder
    /// from an empty result.
    var preparedCount: Int {
        let ids = preparedIDs
        let offered = logicalIDs(ids.offered.union(cachedDisplayIDs))
        let onPhone = logicalIDs(ids.onPhone)
        return logicalQueued.filter { offered.contains($0.id) || onPhone.contains($0.id) || !$0.preparationAnnotations.isEmpty }.count
    }
}
