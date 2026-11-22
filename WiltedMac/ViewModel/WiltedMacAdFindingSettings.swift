import Foundation
import Observation
import WiltedProducer

// MARK: - Model

/// The Ad finding card's model: the provider key, the global switch, and the
/// confirm sheet that decides which subscribed shows are sent to the online
/// ad labeller.
///
/// The key is handed straight to the injected key store and never kept: once
/// `saveKey` succeeds the model holds no copy of it, and no message carries it.
/// Nothing is treated as remote before `confirm()` writes the confirmed set.
@MainActor @Observable
final class WiltedMacAdFindingSettings {
    /// One subscribed show the confirm sheet lists.
    struct Show: Identifiable, Equatable, Sendable {
        let feedID: String
        /// The name the app shows: the owner's own when they renamed the show.
        let title: String
        let feedURL: URL?
        var id: String { feedID }
    }

    private let preferences: UserDefaults
    private let keyStore: any LabellerKeyStoring
    private let now: @Sendable () -> Date
    private let showsProvider: @MainActor () -> [Show]

    /// Why the switch was refused, shown under the switch.
    private(set) var switchMessage: String?

    var hasKey: Bool { keyStore.hasKey() }
    private(set) var isOnlineFindingOn: Bool

    /// The global confirmation sheet and the eligible feed IDs it previews.
    private(set) var isConfirming = false
    private(set) var sheetSent: Set<String> = []

    init(preferences: UserDefaults, keyStore: any LabellerKeyStoring,
         now: @escaping @Sendable () -> Date = Date.init,
         shows: @escaping @MainActor () -> [Show]) {
        self.preferences = preferences
        self.keyStore = keyStore
        self.now = now
        self.showsProvider = shows
        isOnlineFindingOn = AdLabellerPreferences(preferences: preferences).isEnabled
    }

    private var labeller: AdLabellerPreferences { AdLabellerPreferences(preferences: preferences) }
    private var shows: [Show] {
        showsProvider().filter { show in
            guard let feedURL = show.feedURL else { return true }
            return !WiltedMacFeedKind.isArticleFeed(feedID: show.feedID, feedURL: feedURL)
        }
    }

    // MARK: Switch

    /// Turning on with no key is refused; with nothing ever confirmed it opens
    /// the confirm sheet instead, and the switch turns on only when the sheet
    /// is confirmed. Turning it off needs no confirmation.
    func setOnlineFinding(_ on: Bool) {
        guard !isConfirming else { return }
        switchMessage = nil
        guard on else {
            isOnlineFindingOn = false
            labeller.isEnabled = false
            return
        }
        guard hasKey else {
            switchMessage = "The chosen provider is not ready. Set it up in Providers."
            return
        }
        guard !labeller.confirmedFeedIDs.isEmpty else {
            openConfirmSheet(for: shows)
            return
        }
        isOnlineFindingOn = true
        labeller.isEnabled = true
    }

    // MARK: Confirm sheet

    /// Current eligible shows covered by the global confirmation.
    var sheetSentShows: [Show] {
        let refusals = Set(labeller.keptBackFeedIDs)
        return shows.filter { sheetSent.contains($0.feedID) && !refusals.contains($0.feedID) }
    }

    /// Current shows left out of the confirmation, including subscriptions added after it opened.
    var sheetNotSentShows: [Show] {
        let refusals = Set(labeller.keptBackFeedIDs)
        return shows.filter { !sheetSent.contains($0.feedID) || refusals.contains($0.feedID) }
    }

    func confirmationNotSentMessage(for show: Show) -> String {
        if labeller.keptBackFeedIDs.contains(show.feedID) { return "Kept local" }
        return "Not included in this confirmation"
    }

    /// Confirms the eligible shows previewed when the owner enabled the global switch.
    /// A refusal written while the sheet was open wins when the sheet is confirmed.
    func confirm() {
        guard isConfirming else { return }
        let currentRefusals = Set(labeller.keptBackFeedIDs)
        let currentShowsByID = Dictionary(shows.map { ($0.feedID, $0) }, uniquingKeysWith: { first, _ in first })
        for feedID in sheetSent {
            guard currentShowsByID[feedID] != nil, !currentRefusals.contains(feedID) else { continue }
            labeller.setConfirmed(feedID: feedID, true)
        }
        isOnlineFindingOn = true
        labeller.isEnabled = true
        isConfirming = false
    }

    /// Closes the sheet changing nothing.
    func cancel() {
        guard isConfirming else { return }
        isConfirming = false
    }

    private func openConfirmSheet(for shows: [Show]) {
        // A show starts sent unless the owner kept it back.
        let keptBack = Set(labeller.keptBackFeedIDs)
        sheetSent = Set(shows.filter { !keptBack.contains($0.feedID) }.map(\.feedID))
        isConfirming = true
    }

    // MARK: Requests

    /// Requests sent to the provider today, and the daily cap.
    var requestsToday: Int { LabellerRequestCounter(preferences: preferences, now: now).count }
    var dailyCap: Int { LabellerRequestCounter(preferences: preferences, now: now).cap }

    /// Listener-facing paused sentence while `providerPausedSince` is stored; nil once cleared.
    var providerPausedSentence: String? {
        guard let since = labeller.providerPausedSince else { return nil }
        return LabellerStopReason.providerPaused(since: since).sentence(formatTime: {
            $0.formatted(date: .omitted, time: .shortened)
        })
    }
}
