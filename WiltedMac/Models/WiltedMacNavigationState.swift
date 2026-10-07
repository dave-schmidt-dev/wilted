import Foundation

/// Everything the reader would expect to find where they left it: the Feeds selection and disclosure,
/// where each destination was scrolled to, the Larder filter and search, and the two composer drafts.
/// One value, owned by the model and persisted as one preference, so a destination switch and a
/// relaunch restore the same thing. Sort and grouping keep their own preference keys.
struct WiltedMacNavigationState: Codable, Equatable {
    static let empty = WiltedMacNavigationState()

    var selectedFeedEpisodeIDs: Set<String> = []
    var isOffListExpanded = false
    /// The top visible anchor of each destination, keyed by `WiltedMacNavigation.rawValue`.
    var scrollAnchors: [String: String] = [:]
    /// A `WiltedMacLarderGroup.rawValue`, nil for "All waiting".
    var larderFilter: String?
    var librarySearchQuery = ""
    var urlDraft = ""
    var podcastFeedDraft = ""

    init() {}

    /// `larderFilter` is stored under `menuFilter`, the name it had before the Menu became the Larder.
    private enum CodingKeys: String, CodingKey {
        case selectedFeedEpisodeIDs, isOffListExpanded, scrollAnchors
        case larderFilter = "menuFilter"
        case librarySearchQuery, urlDraft, podcastFeedDraft
    }

    /// Tolerant of a missing, added or reordered field: a stored value from another build restores
    /// what it can and defaults the rest.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedFeedEpisodeIDs = try values.decodeIfPresent(Set<String>.self, forKey: .selectedFeedEpisodeIDs) ?? []
        isOffListExpanded = try values.decodeIfPresent(Bool.self, forKey: .isOffListExpanded) ?? false
        scrollAnchors = Self.migratingLegacyAnchors(
            try values.decodeIfPresent([String: String].self, forKey: .scrollAnchors) ?? [:])
        larderFilter = try values.decodeIfPresent(String.self, forKey: .larderFilter)
        librarySearchQuery = try values.decodeIfPresent(String.self, forKey: .librarySearchQuery) ?? ""
        urlDraft = try values.decodeIfPresent(String.self, forKey: .urlDraft) ?? ""
        podcastFeedDraft = try values.decodeIfPresent(String.self, forKey: .podcastFeedDraft) ?? ""
    }

    /// Anchors stored while the Larder was the Menu: the destination key was `menu` and its anchor ids began `menu-`.
    /// An anchor already stored under the Larder's own name wins.
    static func migratingLegacyAnchors(_ stored: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, anchor) in stored {
            let legacy = key == WiltedMacNavigation.legacyLarderRawValue
            let migratedKey = legacy ? WiltedMacNavigation.larder.rawValue : key
            let migratedAnchor = legacy && anchor.hasPrefix("menu-") ? "larder-" + anchor.dropFirst("menu-".count) : anchor
            if legacy, result[migratedKey] != nil { continue }
            result[migratedKey] = migratedAnchor
        }
        if let current = stored[WiltedMacNavigation.larder.rawValue] { result[WiltedMacNavigation.larder.rawValue] = current }
        return result
    }

    /// The value with everything that no longer exists dropped: episodes that left the library,
    /// destinations this build does not have, and a filter this build does not know.
    func pruned(knownEpisodeIDs: Set<String>) -> WiltedMacNavigationState {
        var result = self
        result.selectedFeedEpisodeIDs.formIntersection(knownEpisodeIDs)
        let destinations = Set(WiltedMacNavigation.allCases.map(\.rawValue))
        result.scrollAnchors = scrollAnchors.filter { destinations.contains($0.key) }
        if let filter = larderFilter, WiltedMacLarderGroup(rawValue: filter) == nil { result.larderFilter = nil }
        return result
    }

    static func restored(from data: Data?) -> WiltedMacNavigationState {
        data.flatMap { try? JSONDecoder().decode(WiltedMacNavigationState.self, from: $0) } ?? .empty
    }
}
