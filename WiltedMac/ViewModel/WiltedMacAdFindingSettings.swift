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
        let title: String
        let feedURL: URL?
        var id: String { feedID }
    }

    /// Runs the label-only backfill and reports progress. A nil summary means
    /// labelling is not available in this launch.
    typealias BackfillRun = @MainActor (
        @escaping @Sendable (LabellerBackfill.Progress) -> Void
    ) async -> LabellerBackfill.Summary?

    /// What the Prepared episodes row is doing.
    enum BackfillState: Equatable {
        case idle
        case checking
        case running(done: Int, total: Int)
        case ended(String)
    }

    private let preferences: UserDefaults
    private let keyStore: any LabellerKeyStoring
    private let now: @Sendable () -> Date
    private let showsProvider: @MainActor () -> [Show]
    private let backfill: BackfillRun?

    /// The draft in the key field, cleared the moment a key is saved.
    var typedKey = ""
    /// Why the last key action was refused, shown beside the field.
    private(set) var keyMessage: String?
    /// Why the switch was refused, shown under the switch.
    private(set) var switchMessage: String?

    private(set) var hasKey: Bool
    private(set) var isOnlineFindingOn: Bool

    /// The confirm sheet: whether it is presented, the shows it lists, and
    /// which of them the draft sends. `confirmsSwitchOn` remembers that the
    /// sheet opened because the owner turned the switch on.
    private(set) var isConfirming = false
    private(set) var sheetShows: [Show] = []
    private(set) var sheetSent: Set<String> = []
    private var confirmsSwitchOn = false

    /// Live state of the label-only backfill row.
    private(set) var backfillState: BackfillState = .idle
    private var backfillTask: Task<Void, Never>?

    init(preferences: UserDefaults, keyStore: any LabellerKeyStoring,
         now: @escaping @Sendable () -> Date = Date.init,
         shows: @escaping @MainActor () -> [Show],
         backfill: BackfillRun? = nil) {
        self.preferences = preferences
        self.keyStore = keyStore
        self.now = now
        self.showsProvider = shows
        self.backfill = backfill
        hasKey = keyStore.hasKey()
        isOnlineFindingOn = AdLabellerPreferences(preferences: preferences).isEnabled
    }

    private var labeller: AdLabellerPreferences { AdLabellerPreferences(preferences: preferences) }
    private var shows: [Show] { showsProvider() }

    // MARK: Key

    /// Whether the Save button can act on the draft.
    var canSaveKey: Bool { !typedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Stores the trimmed key. Empty input is refused with an inline message;
    /// on success the typed text is cleared and the model keeps no copy of it.
    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyMessage = "Enter a provider key first."
            return
        }
        do {
            try keyStore.save(trimmed)
        } catch {
            keyMessage = "The key could not be saved."
            return
        }
        hasKey = keyStore.hasKey()
        typedKey = ""
        keyMessage = nil
        switchMessage = nil
    }

    /// Removes the stored key. The policy answers no key, so online ad finding
    /// stops until a key is saved again; the switch keeps its position.
    func removeKey() {
        stopBackfill()
        try? keyStore.remove()
        hasKey = keyStore.hasKey()
    }

    // MARK: Switch

    /// Turning on with no key is refused; with nothing ever confirmed it opens
    /// the confirm sheet instead, and the switch turns on only when the sheet
    /// is confirmed. Turning it off needs no confirmation.
    func setOnlineFinding(_ on: Bool) {
        guard !isConfirming else { return }
        switchMessage = nil
        guard on else {
            stopBackfill()
            isOnlineFindingOn = false
            labeller.isEnabled = false
            return
        }
        guard hasKey else {
            switchMessage = "Save a provider key first."
            return
        }
        guard !labeller.confirmedFeedIDs.isEmpty else {
            openConfirmSheet(for: shows, confirmingSwitch: true)
            return
        }
        isOnlineFindingOn = true
        labeller.isEnabled = true
    }

    // MARK: Waiting shows

    /// Subscribed shows in neither the confirmed set nor the local-only set,
    /// and not forced local by the policy.
    var waitingShows: [Show] {
        let confirmed = Set(labeller.confirmedFeedIDs)
        let localOnly = Set(labeller.localOnlyFeedIDs)
        return shows.filter { show in
            !confirmed.contains(show.feedID) && !localOnly.contains(show.feedID)
                && forcedLocalReason(for: show) == nil
        }
    }

    var waitingShowCount: Int { waitingShows.count }

    /// Opens the sheet for the waiting shows only; confirming adds to, never
    /// replaces, the confirmed set.
    func reviewWaitingShows() {
        openConfirmSheet(for: waitingShows, confirmingSwitch: false)
    }

    // MARK: Confirm sheet

    /// The sheet's two groups, in subscribed order.
    var sheetSentShows: [Show] { sheetShows.filter { sheetSent.contains($0.feedID) } }
    var sheetLocalShows: [Show] { sheetShows.filter { !sheetSent.contains($0.feedID) } }

    /// Why the policy keeps this show on this Mac whatever the owner chooses;
    /// nil when the owner may send it.
    func forcedLocalReason(for show: Show) -> RemoteLabellingLocalReason? {
        RemoteLabellingPolicy.forcedLocalReason(for: RemoteLabellingInput(
            feedID: show.feedID, feedURL: show.feedURL, feedTitle: show.title, audioURL: nil))
    }

    /// The forced reason in the plain words the feed page already uses.
    func forcedLocalMessage(for show: Show) -> String? {
        forcedLocalReason(for: show)?.forcedLocalMessage
    }

    /// A show the policy forces local cannot be toggled to sent.
    func setSheetSent(_ sent: Bool, for show: Show) {
        guard forcedLocalReason(for: show) == nil else { return }
        if sent { sheetSent.insert(show.feedID) } else { sheetSent.remove(show.feedID) }
    }

    /// Writes the sheet's choices: the shows listed as sent into the confirmed
    /// set (a review adds to it), and the shows switched to local into the
    /// local-only set. When the sheet opened from the switch, the switch turns
    /// on here and not before.
    func confirm() {
        guard isConfirming else { return }
        for show in sheetShows where !sheetSent.contains(show.feedID) {
            labeller.setConfirmed(feedID: show.feedID, false)
            if forcedLocalReason(for: show) == nil {
                labeller.setLocalOnly(feedID: show.feedID, true)
            }
        }
        for feedID in sheetSent {
            labeller.setConfirmed(feedID: feedID, true)
            labeller.setLocalOnly(feedID: feedID, false)
        }
        if confirmsSwitchOn {
            isOnlineFindingOn = true
            labeller.isEnabled = true
        }
        isConfirming = false
        confirmsSwitchOn = false
    }

    /// Closes the sheet changing nothing.
    func cancel() {
        guard isConfirming else { return }
        isConfirming = false
        confirmsSwitchOn = false
    }

    private func openConfirmSheet(for shows: [Show], confirmingSwitch: Bool) {
        let localOnly = Set(labeller.localOnlyFeedIDs)
        sheetShows = shows
        confirmsSwitchOn = confirmingSwitch
        // A show starts sent unless the policy forces it local or the owner
        // already keeps it local.
        sheetSent = Set(shows
            .filter { forcedLocalReason(for: $0) == nil && !localOnly.contains($0.feedID) }
            .map(\.feedID))
        isConfirming = true
    }

    // MARK: Requests

    /// Requests sent to the provider today, and the daily cap.
    var requestsToday: Int { LabellerRequestCounter(preferences: preferences, now: now).count }
    var dailyCap: Int { LabellerRequestCounter(preferences: preferences, now: now).cap }

    // MARK: Backfill

    /// Whether the Prepared episodes row can offer Label now.
    var offersBackfill: Bool { backfill != nil && hasKey && isOnlineFindingOn }

    /// Whether a backfill Task is checking or labelling.
    var isBackfilling: Bool {
        switch backfillState {
        case .checking, .running: true
        case .idle, .ended: false
        }
    }

    /// Starts one label-only backfill when the row offers it and none is running.
    func startBackfill() {
        guard offersBackfill, !isBackfilling, let backfill else { return }
        backfillState = .checking
        backfillTask = Task {
            let summary = await backfill { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch self.backfillState {
                    case .checking, .running:
                        self.backfillState = .running(done: progress.done, total: progress.total)
                    case .idle, .ended:
                        break
                    }
                }
            }
            self.backfillState = .ended(Self.backfillEndedMessage(for: summary))
            self.backfillTask = nil
        }
    }

    /// Cancels the in-flight backfill Task; the run ends through its own
    /// cancelled summary.
    func stopBackfill() {
        backfillTask?.cancel()
    }
}
