import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryAppModel {
    /// The episodes on the phone in the one play order CarPlay, Siri and auto-continue share.
    var playOrderRows: [LibraryRow] {
        LibraryListing.rows(
            queued, offered: [], onPhone: preparedIDs.onPhone, filter: .onPhone, query: "",
            progress: progress, finished: finished)
    }

    /// An episode played to its end: remember it as played out and saved at its end (local and unsent,
    /// so the next sync publishes it even when the player has moved on), then continue if asked to.
    func episodeFinished(_ endedID: ItemID, autoPlayNext: Bool) async {
        guard let player = handoffState.player, player.item?.entryID == endedID, player.isUntouchedSinceEnd else { return }
        playedOut[endedID] = now().addingTimeInterval(handoffState.clockOffset)
        handoffState.unpublished[endedID] = (player.duration, now())
        await rememberOwnPosition(endedID, position: player.duration)
        if autoPlayNext { await autoContinue(after: endedID) }
    }

    /// Starts the next episode after `endedID` finished: the first of the play order that is not
    /// completed and not the one that just ended, from its saved position, at the speed the listener
    /// was using. Stops cleanly when none remain. Audio already on the phone only: nothing is fetched.
    /// A command given meanwhile (pause, play, seek, another start) cancels it.
    func autoContinue(after endedID: ItemID) async {
        guard let player = handoffState.player, player.item?.entryID == endedID, player.isUntouchedSinceEnd else { return }
        refreshProgress()
        let next = InProgressOrdering.next(
            in: playOrderRows, after: endedID, id: \.id,
            isCompleted: { LibraryListing.completionDate($0, finished: finished) != nil })
        guard let next else { return }
        let rate = player.rate
        let started = await startCached(next, togglingIfLoaded: false) { player in
            player.item?.entryID == endedID && player.isUntouchedSinceEnd
        }
        if started { player.setRate(rate) }
    }
}
