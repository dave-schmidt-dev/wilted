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
    /// A `WiltedMacMenuGroup.rawValue`, nil for "All waiting".
    var menuFilter: String?
    var librarySearchQuery = ""
    var urlDraft = ""
    var podcastFeedDraft = ""

    init() {}

    /// Tolerant of a missing, added or reordered field: a stored value from another build restores
    /// what it can and defaults the rest.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedFeedEpisodeIDs = try values.decodeIfPresent(Set<String>.self, forKey: .selectedFeedEpisodeIDs) ?? []
        isOffListExpanded = try values.decodeIfPresent(Bool.self, forKey: .isOffListExpanded) ?? false
        scrollAnchors = try values.decodeIfPresent([String: String].self, forKey: .scrollAnchors) ?? [:]
        menuFilter = try values.decodeIfPresent(String.self, forKey: .menuFilter)
        librarySearchQuery = try values.decodeIfPresent(String.self, forKey: .librarySearchQuery) ?? ""
        urlDraft = try values.decodeIfPresent(String.self, forKey: .urlDraft) ?? ""
        podcastFeedDraft = try values.decodeIfPresent(String.self, forKey: .podcastFeedDraft) ?? ""
    }

    /// The value with everything that no longer exists dropped: episodes that left the library,
    /// destinations this build does not have, and a filter this build does not know.
    func pruned(knownEpisodeIDs: Set<String>) -> WiltedMacNavigationState {
        var result = self
        result.selectedFeedEpisodeIDs.formIntersection(knownEpisodeIDs)
        let destinations = Set(WiltedMacNavigation.allCases.map(\.rawValue))
        result.scrollAnchors = scrollAnchors.filter { destinations.contains($0.key) }
        if let filter = menuFilter, WiltedMacMenuGroup(rawValue: filter) == nil { result.menuFilter = nil }
        return result
    }

    static func restored(from data: Data?) -> WiltedMacNavigationState {
        data.flatMap { try? JSONDecoder().decode(WiltedMacNavigationState.self, from: $0) } ?? .empty
    }
}
