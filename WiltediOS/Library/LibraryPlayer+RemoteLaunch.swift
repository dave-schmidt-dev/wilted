import Foundation
import OSLog

extension LibraryRemoteCommand {
    /// The command's name for the log: never its position or speed, which are of no use there.
    var logName: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .togglePlayPause: "togglePlayPause"
        case .skipForward: "skipForward"
        case .skipBackward: "skipBackward"
        case .seek: "seek"
        case .setRate: "setRate"
        case .beginSeeking: "beginSeeking"
        case .endSeeking: "endSeeking"
        }
    }
}

extension LibraryPlayer {
    /// Registers the system command handlers once. The runtime calls this at launch, before any episode
    /// loads, because iOS relaunches a killed app in the background to deliver a Bluetooth or CarPlay
    /// command and drops it when no handler is registered by then. `start` calls it too, for a player
    /// built without the runtime. Nothing unregisters: the player lives as long as the process.
    func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        remoteCommands.install { [weak self] command in self?.handleRemote(command) ?? false }
    }

    /// A command with nothing loaded. Play and play/pause go to the runtime, which resumes an episode
    /// from the library and logs how that ended; everything else needs a loaded episode.
    func handleIdleRemote(_ command: LibraryRemoteCommand) -> Bool {
        switch command {
        case .play, .togglePlayPause: onIdleRemoteCommand?(command) ?? false
        case .pause, .skipForward, .skipBackward, .seek, .setRate, .beginSeeking, .endSeeking: false
        }
    }

    func logRemote(_ command: LibraryRemoteCommand, loaded: Bool, handled: Bool) {
        playerLog.notice(
            "Remote command \(command.logName, privacy: .public): loaded=\(loaded, privacy: .public) result=\(handled ? "handled" : "failed", privacy: .public)")
    }
}
