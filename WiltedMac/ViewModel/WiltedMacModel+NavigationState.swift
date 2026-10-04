import Foundation
import SwiftUI

/// Window state the reader chooses and the app keeps across launches.
extension WiltedMacModel {
    static let sidebarVisiblePreferenceKey = "wilted.navigation.sidebar.visible"

    /// Hide or show the sidebar: the toolbar button and ⌃⌘S both come here.
    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    /// The label the toolbar button and the menu command carry.
    var sidebarToggleTitle: String {
        isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
    }
}

// MARK: - Retained navigation state

extension WiltedMacModel {
    static let navigationStatePreferenceKey = "wilted.navigation.state"

    /// Reads the saved value at launch. Unknown fields default; episodes that are not loaded yet are
    /// pruned by `pruneNavigationState()` once the library is.
    func restoreNavigationState() {
        navigationState = WiltedMacNavigationState.restored(
            from: preferences.data(forKey: Self.navigationStatePreferenceKey))
        // Assigning the state bypasses the `librarySearchQuery` setter, so the restored query's transcript
        // search is scheduled here. With no store yet (a production launch) this is a no-op; bootstrap
        // schedules it again once the store is ready.
        scheduleTranscriptSearch()
    }

    func persistNavigationState() {
        if navigationState == .empty {
            preferences.removeObject(forKey: Self.navigationStatePreferenceKey)
        } else if let data = try? JSONEncoder().encode(navigationState) {
            preferences.set(data, forKey: Self.navigationStatePreferenceKey)
        }
    }

    /// Drops saved selections for episodes that left the library. Called after a store read, never
    /// before the first one, so a relaunch does not prune against an empty list. Stale scroll anchors are left to
    /// the view: an anchor that no longer exists scrolls nowhere.
    func pruneNavigationState() {
        let pruned = navigationState.pruned(knownEpisodeIDs: Set(episodes.map(\.id)))
        if pruned != navigationState { navigationState = pruned }
    }

    /// The Clear action: forget the saved view and start from the defaults.
    func clearNavigationState() {
        navigationState = .empty
        scheduleTranscriptSearch()
    }

    var hasRetainedNavigationState: Bool { navigationState != .empty }

    /// A destination's saved scroll anchor, as a binding for `scrollPosition(id:)`.
    func scrollAnchor(for destination: WiltedMacNavigation) -> Binding<String?> {
        Binding(
            get: { self.navigationState.scrollAnchors[destination.rawValue] },
            set: { anchor in
                guard self.navigationState.scrollAnchors[destination.rawValue] != anchor else { return }
                self.navigationState.scrollAnchors[destination.rawValue] = anchor
            })
    }
}
