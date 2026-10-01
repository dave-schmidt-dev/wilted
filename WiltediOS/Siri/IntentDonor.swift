import AppIntents
import Combine
import Foundation
import WiltedDomain
import WiltedLibrary

/// Where donations go; tests record them instead of calling the system.
@MainActor
protocol IntentDonating: AnyObject {
    func donatePlay(of episode: EpisodeEntity)
    func donateMarkCompleted()
}

@MainActor
final class SystemIntentDonor: IntentDonating {
    func donatePlay(of episode: EpisodeEntity) {
        let intent = PlayEpisodeIntent()
        intent.episode = episode
        IntentDonationManager.shared.donate(intent: intent)
    }

    func donateMarkCompleted() {
        IntentDonationManager.shared.donate(intent: MarkCompletedIntent())
    }
}

/// Donates the intents the person actually uses from the app, so Siri can learn "play <episode>" and
/// "mark this completed" as habits. It sees them through state, not by editing the model: an episode
/// that starts playing, and a Mark completed on the episode that is loaded (what the spoken command
/// means by "this episode").
///
/// A command Siri itself ran is already known to the system, so the voice target tells the donor to
/// skip that one; donating it again would count it twice.
@MainActor
final class IntentDonor {
    static let shared = IntentDonor()

    private let donor: any IntentDonating
    private var lastPlayed: ItemID?
    private var seenDecisions: Set<String> = []
    private var skippedPlays: Set<ItemID> = []
    private var skippedMarks: Set<ItemID> = []

    init(donor: any IntentDonating = SystemIntentDonor()) {
        self.donor = donor
    }

    /// An episode just started playing. Once per episode until another one plays.
    func played(_ item: LibraryPlayer.Item) {
        guard item.entryID != lastPlayed else { return }
        lastPlayed = item.entryID
        if skippedPlays.remove(item.entryID) != nil { return }
        let episode = VoiceEpisode(id: item.entryID, title: item.title, showTitle: item.showTitle)
        donor.donatePlay(of: EpisodeEntity(episode))
    }

    /// The pending decisions changed: each decision's id and, for a Mark completed, its entry.
    /// `loaded` is the episode in the player, if any. Decisions already seen, and ones restored at
    /// launch (nothing is loaded then), are not donated.
    func decisions(_ pending: [(id: String, markedDone: ItemID?)], loaded: ItemID?) {
        for decision in pending where !seenDecisions.contains(decision.id) {
            guard let entryID = decision.markedDone, entryID == loaded else { continue }
            if skippedMarks.remove(entryID) == nil { donor.donateMarkCompleted() }
        }
        seenDecisions = Set(pending.map(\.id))
    }

    /// Runs `body`, which plays `entryID` for Siri; the system already counted that play. The state
    /// change reaches the donor while `body` runs, so nothing is left skipped afterwards.
    func withoutDonatingPlay(of entryID: ItemID, _ body: () async -> Void) async {
        skippedPlays.insert(entryID)
        await body()
        skippedPlays.remove(entryID)
    }

    func withoutDonatingMark(of entryID: ItemID, _ body: () async -> Void) async {
        skippedMarks.insert(entryID)
        await body()
        skippedMarks.remove(entryID)
    }

    /// Watches the player and the model for the life of the returned subscriptions.
    func observe(_ model: LibraryAppModel, _ player: LibraryPlayer) -> [AnyCancellable] {
        [
            player.$status.removeDuplicates().filter { $0 == .playing }
                .sink { [weak self, weak player] _ in
                    MainActor.assumeIsolated { if let item = player?.item { self?.played(item) } }
                },
            model.$decisions.sink { [weak self, weak player] pending in
                let summary = pending.map { decision -> (id: String, markedDone: ItemID?) in
                    if case .markDone(let entryID) = decision.intent.action { return (decision.id, entryID) }
                    return (decision.id, nil)
                }
                MainActor.assumeIsolated { self?.decisions(summary, loaded: player?.item?.entryID) }
            },
        ]
    }
}
