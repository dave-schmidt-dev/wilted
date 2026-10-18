import AppKit
import SwiftUI
import WiltedDomain

/// The static section presentation for the Larder: which sections render, in what order, and how
/// their rows are numbered and sorted. Presentation only; nothing here touches the durable queue.
extension WiltedMacEpisodePresentationSections {
    /// Continuous visible ordinals across the actual rendered sections.
    /// Only presentation changes: durable queue order and episode values stay intact. Articles are
    /// not in the queue, so they carry no ordinal.
    static func visibleNumbering(_ sections: [WiltedMacLarderSection]) -> VisibleNumbering {
        let episodes = sections.flatMap(\.episodes)
        let positions = Dictionary(uniqueKeysWithValues: episodes.enumerated().map {
            ($0.element.id, $0.offset + 1)
        })
        return VisibleNumbering(positions: positions, count: episodes.count)
    }

    /// The sections the Larder renders.
    ///
    /// - Parameter statusGroups: The lifecycle groups the status filter admits. Under Status
    ///   grouping each one is shown even with no rows, so its heading and help stay reachable; an
    ///   empty list (the default) keeps only sections that have rows. Feed and Date grouping
    ///   ignore it, and Active work appears only when something is in flight.
    static func displaySections(
        _ sections: [WiltedMacLarderSection],
        grouping: WiltedMacLarderGrouping,
        sort: WiltedMacLarderSort = .custom,
        direction: WiltedMacLarderSortDirection = .ascending,
        statusGroups: [WiltedMacLarderGroup] = [],
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date(),
        isDeferredForOffPeak: (String) -> Bool = { _ in false }
    ) -> [WiltedMacLarderSection] {
        func isActive(_ item: WiltedMacLibraryItem) -> Bool {
            switch item {
            case .article(let article): !article.isReady
            case .audiobook: false
            case .episode(let episode):
                episode.downloadState.isInFlight
                    || (episode.preparationState.isRunning && !isDeferredForOffPeak(episode.id))
            }
        }
        let keepsEmptyStatus = grouping == .status && !statusGroups.isEmpty
        let active = sections.flatMap(\.items).filter(isActive)
        let activeIDs = Set(active.map(\.id))
        let remaining = sections.compactMap { section -> WiltedMacLarderSection? in
            let rows = presentationOrder(
                section.items.filter { !activeIDs.contains($0.id) }, sort: sort, direction: direction
            )
            let keepsEmpty = keepsEmptyStatus && section.statusGroup.map { statusGroups.contains($0) } == true
            guard !rows.isEmpty || keepsEmpty else { return nil }
            return WiltedMacLarderSection(
                id: section.id, title: section.title, detail: section.detail,
                statusGroup: section.statusGroup, items: rows
            )
        }
        let content: [WiltedMacLarderSection]
        if grouping == .date {
            content = publicationDateSections(remaining.flatMap(\.items), calendar: calendar, now: now)
        } else if keepsEmptyStatus {
            content = admittedStatusSections(remaining, statusGroups: statusGroups)
        } else {
            content = remaining
        }
        guard !active.isEmpty else { return content }
        let activeSection = WiltedMacLarderSection(
            id: "active-work", title: "Active work", detail: "download or preparation in progress",
            statusGroup: nil, items: active
        )
        // Status appends Active work after the lifecycle sections so the available-download list collapses immediately.
        guard grouping == .status else { return [activeSection] + content }
        return content + [activeSection]
    }

    /// Every admitted lifecycle group in its fixed order, with an empty section for a group the
    /// model handed over no rows for, then any section that belongs to no group. The empty section
    /// carries the model's identity, title and detail, so its heading and help match a full one.
    private static func admittedStatusSections(
        _ sections: [WiltedMacLarderSection], statusGroups: [WiltedMacLarderGroup]
    ) -> [WiltedMacLarderSection] {
        let lifecycle = WiltedMacLarderGroup.allCases.filter { statusGroups.contains($0) }.map { group in
            sections.first { $0.statusGroup == group } ?? WiltedMacLarderSection(
                id: "status-\(group.rawValue)", title: group.displayName, detail: group.detail,
                statusGroup: group, items: []
            )
        }
        return lifecycle + sections.filter { $0.statusGroup == nil }
    }

    /// Newest keeps unknown feed publication facts after known facts while it
    /// presents each existing status or feed section. It deliberately does
    /// not rewrite the model's durable comparator or merge lifecycle sections.
    static func presentationOrder(
        _ episodes: [WiltedMacEpisode], sort: WiltedMacLarderSort
    ) -> [WiltedMacEpisode] {
        guard sort == .newest else { return episodes }
        return episodes.filter { $0.publishedAt != nil }
            + episodes.filter { $0.publishedAt == nil }
    }

    /// One section's rows in order. Without articles the queue order the model already holds is kept
    /// (the legacy rule above). With articles, which have no queue position, a calculated sort orders
    /// every row together; Listening order keeps the queued rows first and the articles after them,
    /// newest first.
    static func presentationOrder(
        _ items: [WiltedMacLibraryItem], sort: WiltedMacLarderSort,
        direction: WiltedMacLarderSortDirection = .ascending
    ) -> [WiltedMacLibraryItem] {
        let hasArticle = items.contains { if case .article = $0 { true } else { false } }
        guard hasArticle else {
            let episodes = items.compactMap { item -> WiltedMacEpisode? in
                switch item { case .episode(let value), .audiobook(let value): value; case .article: nil }
            }
            return presentationOrder(episodes, sort: sort).map(WiltedMacLibraryItem.init(episode:))
        }
        guard sort.canonical != .custom else {
            let queued = items.filter { if case .article = $0 { false } else { true } }
            let articles = items.filter { if case .article = $0 { true } else { false } }
            return queued + articles.sorted { $0.date > $1.date }
        }
        return WiltedMacEpisodeListOrder.ordered(
            items,
            key: { WiltedMacEpisodeListOrder.key(for: $0) },
            sort: sort,
            direction: direction
        )
    }

    /// The factual date of a row: a feed's publication date, or when an article was saved.
    private static func knownDate(_ item: WiltedMacLibraryItem) -> Date? {
        switch item {
        case .article(let value): value.createdAt
        case .episode(let value), .audiobook(let value): value.publishedAt
        }
    }

    /// `releasedAt` stays the legacy sort/grouping fallback, but a section
    /// header describes only the feed's actual optional publication date.
    /// Unknown facts are collected last rather than borrowing intake time.
    static func publicationDateSections(
        _ items: [WiltedMacLibraryItem], calendar: Calendar, now: Date
    ) -> [WiltedMacLarderSection] {
        var dated: [(date: Date, items: [WiltedMacLibraryItem])] = []
        var unknown: [WiltedMacLibraryItem] = []
        for item in items {
            guard let publishedAt = knownDate(item) else {
                unknown.append(item)
                continue
            }
            let date = calendar.startOfDay(for: publishedAt)
            if let index = dated.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
                dated[index].items.append(item)
            } else {
                dated.append((date, [item]))
            }
        }
        let known = dated.map { value in
            WiltedMacLarderSection(
                id: "publication-date-\(value.date.timeIntervalSinceReferenceDate)",
                title: publicationDateTitle(value.date, calendar: calendar, now: now), detail: nil,
                statusGroup: nil, items: value.items
            )
        }
        guard !unknown.isEmpty else { return known }
        return known + [WiltedMacLarderSection(
            id: "publication-date-unknown", title: "Unknown publication date", detail: nil,
            statusGroup: nil, items: unknown
        )]
    }

    private static func publicationDateTitle(_ date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
