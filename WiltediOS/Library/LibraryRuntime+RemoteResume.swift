import Foundation
import OSLog
import WiltedDomain

extension LibraryAppModel {
    /// What a play command resumes when nothing is loaded: the first episode on the phone that is not
    /// completed, in the play order CarPlay, Siri and auto-continue share (in-progress episodes with the
    /// newest play first, then the not-started ones). Nil when every episode on the phone is completed,
    /// or none is: a finished episode is never restarted from the car.
    var remoteResumeRow: LibraryRow? {
        let finished = logicalFinished
        return playOrderRows.first { LibraryListing.completionDate($0, finished: finished) == nil }
    }
}

extension LibraryRuntime {
    /// Registers the system transport commands, and routes play and play/pause with nothing loaded to
    /// `resumeFromIdleRemote`. Safe to call from every entry point: the player installs once.
    func installRemoteCommands() {
        player.onIdleRemoteCommand = { [weak self] command in self?.resumeFromIdleRemote(command) ?? false }
        player.installRemoteCommands()
    }

    /// A play command with nothing loaded. The handler must answer at once, so this decides what it can
    /// without waiting: once the library is loaded and holds nothing to resume it fails, and otherwise it
    /// reports success and starts the episode in a task that logs how it ended. Before the library is
    /// loaded (a background launch for this very command) the answer is success, as nothing is known yet.
    func resumeFromIdleRemote(_ command: LibraryRemoteCommand) -> Bool {
        if model.localStateLoaded, model.remoteResumeRow == nil {
            playerLog.notice("Remote resume \(command.logName, privacy: .public): nothing on this iPhone to resume")
            return false
        }
        Task { await resumeFromLibrary(for: command) }
        return true
    }

    private func resumeFromLibrary(for command: LibraryRemoteCommand) async {
        let name = command.logName
        await prepare()
        // A listener's start (the phone, Siri, an earlier press of this same button) that is already
        // loaded or looking up its file keeps the player; this command never replaces it.
        if player.item != nil {
            playerLog.notice("Remote resume \(name, privacy: .public): an episode was loaded meanwhile")
            return
        }
        if case .starting = model.playbackCommand {
            playerLog.notice("Remote resume \(name, privacy: .public): a start is already under way")
            return
        }
        guard let row = model.remoteResumeRow else {
            playerLog.notice("Remote resume \(name, privacy: .public): nothing on this iPhone to resume")
            return
        }
        // The same start Siri makes: the system already counted this play, so it is not donated again.
        var outcome = LibraryStartOutcome.superseded
        await IntentDonor.shared.withoutDonatingPlay(of: row.id) {
            outcome = await model.startCached(row, kind: .select) { $0.item == nil }
        }
        if outcome.opensNowPlaying {
            playerLog.notice("Remote resume \(name, privacy: .public): resumed \(row.id.rawValue)")
        } else {
            playerLog.error("Remote resume \(name, privacy: .public): failed, \(outcome.logName, privacy: .public)")
        }
    }
}

private extension LibraryStartOutcome {
    /// The outcome for the log. A failure's reason is one of the player's fixed phrases, never episode text.
    var logName: String {
        switch self {
        case .started: "started"
        case .resumed: "resumed"
        case .alreadyPlaying: "alreadyPlaying"
        case .paused: "paused"
        case let .failed(failure): "failed: \(failure.playerReason)"
        case .superseded: "superseded by a newer command"
        case .declined: "declined"
        }
    }
}
