import Foundation
import Observation
import os
import WiltedDomain
import WiltedProducer

private let feedHistoryLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "FeedHistory")

/// One History page as the store is asked for it.
struct WiltedMacFeedHistoryRequest: Equatable, Sendable {
    /// The feed to read, or nil for every feed.
    var feedID: String?
    var search: String
    var status: LocalLibraryStore.HistoryStatusFilter?
    var sort: WiltedMacLarderSort = .custom
    var direction: WiltedMacLarderSortDirection = .ascending
    var offset: Int
    var limit: Int
}

/// Pages History out of the library store for one History view, which holds
/// the displayed page in `@State`. Calculated ordering scans scalar keys across
/// the matching set and hydrates complete rows only for the requested page;
/// the default Custom order remains a bounded store page. The store is an
/// actor, so each page is read off the main actor. Search waits for typing to
/// pause (`searchDebounce`, each keystroke cancels and restarts the wait); a
/// filter, sort, or page change loads at once. Every load takes a new
/// generation, and a response is published only while its generation is still
/// the newest, so a slow stale page can never replace a newer one.
@MainActor @Observable
final class WiltedMacFeedHistoryLoader {
    static let sortPreferenceKey = "wilted.history.sort"
    static let sortDirectionPreferenceKey = "wilted.history.sort-direction"

    /// Reads one page. Production reads the model's library store; tests may
    /// inject their own to count queries.
    typealias Fetch = @MainActor @Sendable (WiltedMacFeedHistoryRequest) async throws -> LocalLibraryStore.HistoryPage

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All statuses"
        case played = "Played"
        case skipped = "Skipped"

        var id: String { rawValue }

        /// Skipped includes rule skips: the store's filter is every row that is not played.
        var storeFilter: LocalLibraryStore.HistoryStatusFilter? {
            switch self {
            case .all: nil
            case .played: .played
            case .skipped: .skipped
            }
        }
    }

    static let pageSize = 25
    static let searchDebounce: Duration = .milliseconds(300)

    /// The search field's text. The query it drives waits for typing to pause.
    private(set) var searchText = ""
    /// The all-feeds feed picker. Ignored while the view is scoped to one feed.
    private(set) var feedFilter: String?
    private(set) var statusFilter: StatusFilter = .all
    /// History ordering is independent from the Larder's saved queue order.
    private(set) var sort: WiltedMacLarderSort = .custom
    private(set) var direction: WiltedMacLarderSortDirection = .ascending
    /// The requested page, which leads `shownOffset` while that page loads.
    private(set) var pageIndex = 0
    /// The rows on screen and where they start; both change only when a page arrives.
    private(set) var rows: [LocalLibraryStore.HistoryRow] = []
    private(set) var shownOffset = 0
    /// How many rows match the scope, search and status filter in total.
    private(set) var total = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var loadFailed = false
    /// Rows whose Restore was sent and whose reloaded page has not arrived yet.
    private(set) var restoringIDs: Set<String> = []

    @ObservationIgnored private var scopeFeedID: String?
    @ObservationIgnored private var hasScope = false
    @ObservationIgnored private var fetch: Fetch?
    @ObservationIgnored private var preferences: UserDefaults
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTasks: [String: Task<Void, Never>] = [:]

    init(fetch: Fetch? = nil, preferences: UserDefaults = .standard) {
        self.fetch = fetch
        self.preferences = preferences
        restoreOrdering(from: preferences)
    }

    private func restoreOrdering(from preferences: UserDefaults) {
        let storedSort = preferences.string(forKey: Self.sortPreferenceKey)
        let restored = storedSort.flatMap(WiltedMacLarderSort.restored)
        sort = restored?.0.canonical ?? .custom
        let storedDirection = preferences.string(forKey: Self.sortDirectionPreferenceKey)
            .flatMap(WiltedMacLarderSortDirection.init(rawValue:))
        direction = storedDirection ?? restored?.1 ?? .ascending

        if let restored, let storedSort, restored.0.canonical.rawValue != storedSort {
            preferences.set(restored.0.canonical.rawValue, forKey: Self.sortPreferenceKey)
        }
        if storedDirection == nil, let migratedDirection = restored?.1 {
            preferences.set(migratedDirection.rawValue, forKey: Self.sortDirectionPreferenceKey)
        }
    }

    var pageCount: Int { max(1, (total + Self.pageSize - 1) / Self.pageSize) }

    /// Whether a search or filter narrows the rows, which decides the empty copy.
    var isFiltered: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || statusFilter != .all || (scopeFeedID == nil && feedFilter != nil)
    }

    /// Reads pages from `model`'s library store, unless a fetch was injected.
    func useStore(of model: WiltedMacModel) {
        guard fetch == nil else { return }
        preferences = model.preferences
        restoreOrdering(from: preferences)
        // The model outlives every History view and never holds this loader.
        fetch = { request in
            guard let store = model.store else { throw LoadError.storeUnavailable }
            let feedID = try request.feedID.map { try ItemID(rawValue: $0) }
            return try await store.historyPage(
                feedID: feedID, search: request.search, status: request.status,
                sort: WiltedMacEpisodeListOrder.librarySort(request.sort),
                direction: WiltedMacEpisodeListOrder.libraryDirection(request.direction),
                offset: request.offset, limit: request.limit
            )
        }
    }

    /// Scopes History to one feed, or every feed when `feedID` is nil, and
    /// loads the current page. A new scope starts again at page one.
    func start(feedID: String?) async {
        if !hasScope || scopeFeedID != feedID {
            hasScope = true
            scopeFeedID = feedID
            pageIndex = 0
        }
        await reload()
    }

    func setSearchText(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        pageIndex = 0
        schedule(after: Self.searchDebounce)
    }

    func setStatusFilter(_ filter: StatusFilter) {
        guard filter != statusFilter else { return }
        statusFilter = filter
        pageIndex = 0
        schedule(after: nil)
    }

    func setFeedFilter(_ feedID: String?) {
        guard feedID != feedFilter else { return }
        feedFilter = feedID
        pageIndex = 0
        schedule(after: nil)
    }

    func setSort(_ newSort: WiltedMacLarderSort) {
        let canonical = newSort.canonical
        let newDirection = newSort.legacyDirection ?? direction
        guard canonical != sort || newDirection != direction else { return }
        sort = canonical
        direction = newDirection
        preferences.set(canonical.rawValue, forKey: Self.sortPreferenceKey)
        preferences.set(newDirection.rawValue, forKey: Self.sortDirectionPreferenceKey)
        pageIndex = 0
        schedule(after: nil)
    }

    func setDirection(_ newDirection: WiltedMacLarderSortDirection) {
        guard newDirection != direction else { return }
        direction = newDirection
        preferences.set(newDirection.rawValue, forKey: Self.sortDirectionPreferenceKey)
        pageIndex = 0
        schedule(after: nil)
    }

    func showPage(_ index: Int) {
        let clamped = min(max(0, index), pageCount - 1)
        guard clamped != pageIndex else { return }
        pageIndex = clamped
        schedule(after: nil)
    }

    /// Loads the current page now and waits for it.
    func reload() async {
        schedule(after: nil)
        await settle()
    }

    /// Waits until no Restore follow-up or page load is outstanding, including
    /// loads that a newer one replaced while this waited.
    func settle() async {
        while let task = restoreTasks.values.first ?? loadTask {
            await task.value
            if restoreTasks.values.contains(task) { continue }
            if task == loadTask { loadTask = nil }
        }
    }

    /// Sends Restore through the model, unchanged: it writes a manual Keep, so
    /// a feed rule never skips the episode again. Once that write commits, the
    /// current page reloads and the restored row leaves it.
    func restore(_ record: WiltedMacFeedHistoryRecord, model: WiltedMacModel) {
        let id = record.id
        guard restoreTasks[id] == nil else { return }
        let writers = record.requestRestore(through: model)
        guard !writers.isEmpty else { return }
        restoringIDs.insert(id)
        restoreTasks[id] = Task { [weak self] in
            for writer in writers { await writer.value }
            guard let self else { return }
            self.schedule(after: nil)
            await self.loadTask?.value
            self.restoringIDs.remove(id)
            self.restoreTasks[id] = nil
        }
    }

    private var currentRequest: WiltedMacFeedHistoryRequest {
        WiltedMacFeedHistoryRequest(
            feedID: scopeFeedID ?? feedFilter,
            search: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            status: statusFilter.storeFilter,
            sort: sort,
            direction: direction,
            offset: pageIndex * Self.pageSize,
            limit: Self.pageSize
        )
    }

    /// Replaces any pending or in-flight load with one for the current state.
    private func schedule(after delay: Duration?) {
        loadTask?.cancel()
        generation &+= 1
        let token = generation
        guard hasScope, let fetch else { return }
        loadTask = Task { [weak self] in
            if let delay {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.load(token: token, fetch: fetch)
        }
    }

    private func load(token: UInt64, fetch: Fetch) async {
        guard token == generation else { return }
        isLoading = true
        var request = currentRequest
        do {
            while true {
                let page = try await fetch(request)
                guard token == generation else { return }
                // The page emptied under us (the last row of the last page was
                // restored): step back to the new last page instead of showing none.
                if page.rows.isEmpty, page.total > 0, request.offset >= page.total {
                    pageIndex = (page.total - 1) / Self.pageSize
                    request.offset = pageIndex * Self.pageSize
                    continue
                }
                rows = page.rows
                shownOffset = page.offset
                total = page.total
                loadFailed = false
                break
            }
        } catch {
            guard token == generation else { return }
            feedHistoryLog.error("History page read failed: \(String(describing: error), privacy: .public)")
            loadFailed = true
        }
        hasLoaded = true
        isLoading = false
    }

    private enum LoadError: Error {
        case storeUnavailable
    }
}
