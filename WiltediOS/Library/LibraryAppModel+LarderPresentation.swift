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
        let prepared = preparedIDs
        let ids = effectiveLarderMediaIDs(prepared: prepared)
        var onPhone = ids.onPhone
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
            // Audio already on the phone is a local fact, not an offer: the snapshot keeps only offered
            // rows, so without this a sync round briefly empties the list of downloaded episodes. It is
            // matched in the current mirror's grouping, the one `logicalQueued` uses; an episode the
            // snapshot already lists, alone or in a group, keeps that row and gets no second one.
            let liveOnPhone = logicalIDs(prepared.onPhone, groupsByMember: projectedEpisodeGroupsByMember)
            let shown = Set(rows.map(\.id))
            let shownMembers = shown.union(rows.flatMap(\.memberIDs))
            rows += logicalQueued.filter { row in
                !shown.contains(row.id) && (!row.preparationAnnotations.isEmpty
                    || (liveOnPhone.contains(row.id) && !row.memberIDs.contains(where: shownMembers.contains)))
            }
            onPhone.formUnion(liveOnPhone)
        }
        if listOrder == .mac {
            var queueIndices: [ItemID: Int] = [:]
            for (index, row) in logicalQueued.enumerated() {
                if queueIndices[row.id] == nil {
                    queueIndices[row.id] = index
                }
            }
            rows = rows.enumerated().sorted { left, right in
                switch (queueIndices[left.element.id], queueIndices[right.element.id]) {
                case let (l?, r?):
                    return l < r
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    return left.offset < right.offset
                }
            }.map(\.element)
        }
        let preparationIDs = Set(rows.filter { !$0.preparationAnnotations.isEmpty }.map(\.id))
        return LibraryListing.rows(rows, offered: ids.offered,
            onPhone: onPhone, filter: filter, kind: kindFilter, query: searchText,
            progress: logicalProgress, finished: logicalFinished, preparationIDs: preparationIDs,
            order: listOrder)
    }

    /// True once the Larder has something true to show (W-INV-040): the saved prepared rows as soon as the
    /// store is read, while the audio on the phone is still being checked; with none saved, once that check
    /// ends, so "Nothing prepared yet" is never said before it is known.
    var larderReady: Bool { localStateLoaded || preparedCount > 0 }

    /// How many queued entries are prepared, before any filter or search; tells an empty Larder
    /// from an empty result.
    var preparedCount: Int {
        let ids = preparedIDs
        let offered = logicalIDs(ids.offered.union(cachedDisplayIDs))
        let onPhone = logicalIDs(ids.onPhone)
        return logicalQueued.filter { offered.contains($0.id) || onPhone.contains($0.id) || !$0.preparationAnnotations.isEmpty }.count
    }
}
