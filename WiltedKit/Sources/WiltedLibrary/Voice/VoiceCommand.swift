import Foundation
import WiltedDomain

/// One spoken request, already parsed by the system into a command. Framework-free: the App
/// Intents shells in the iPhone target map their intents onto this enum, and everything below
/// is unit-tested without Siri, the player or a library model.
public enum VoiceCommand: Sendable, Equatable {
    /// "Play the next episode of <show>". A nil show means the next downloaded episode overall.
    case playNext(show: String?)
    /// "Play <episode title>", optionally within one show. Matches among downloaded episodes only.
    case playEpisode(title: String, show: String?)
    /// Siri picked one exact episode (an `EpisodeEntity`), so its id decides, not its title.
    case playEpisodeByID(ItemID)
    /// "Play the latest episode", optionally of one show: the most recently published downloaded one.
    case playLatest(show: String?)
    /// "Play something", optionally of one show: the first downloaded episode in the app's play order
    /// (partway through first, then not-started oldest first), the one the phone list and autoplay reach first.
    case playFirst(show: String?)
    /// Save the current podcast's trailing 30 seconds to the Notebook.
    case saveThat
    case pause
    case resume
    case skipForward
    case skipBack
    /// Seek the current episode to 0.
    case restart
    /// Mark the current episode completed, at once: no question comes first.
    case markCompleted
    case whatsPlaying
    /// Count and first few titles of the episodes downloaded on the phone, in Larder order.
    case listDownloaded
    /// "How much is left": the loaded episode's remaining time at the current speed.
    case timeLeft
    /// Set the playback speed, now and for the next episodes (it is the app's speed setting).
    case setSpeed(Double)
    /// Pause after a while, or switch the timer off.
    case sleepTimer(VoiceSleepTimer)
}

/// What a spoken sleep timer asks for.
public enum VoiceSleepTimer: Sendable, Equatable {
    case minutes(Int)
    /// Stop when the loaded episode ends, and do not start the next one.
    case endOfEpisode
    case off
}

/// A downloaded episode, as the voice layer sees it. Only episodes whose audio is on the phone
/// ever appear; a voice command never starts a download.
public struct VoiceEpisode: Sendable, Equatable {
    public let id: ItemID
    public let title: String
    public let showTitle: String
    /// When the feed published it; decides "latest". Unknown sorts oldest.
    public let publishedAt: Date

    public init(id: ItemID, title: String, showTitle: String, publishedAt: Date = .distantPast) {
        self.id = id
        self.title = title
        self.showTitle = showTitle
        self.publishedAt = publishedAt
    }
}

/// What the player holds right now.
public struct VoiceNowPlaying: Sendable, Equatable {
    public let episode: VoiceEpisode
    public let isPlaying: Bool
    /// Whether the Larder offers Mark completed for this episode right now.
    public let canMarkCompleted: Bool
    /// Seconds into the file and its length; a zero duration means unknown.
    public let position: TimeInterval
    public let duration: TimeInterval
    /// The playback speed, 1 for normal.
    public let rate: Double

    public init(
        episode: VoiceEpisode, isPlaying: Bool, canMarkCompleted: Bool,
        position: TimeInterval = 0, duration: TimeInterval = 0, rate: Double = 1
    ) {
        self.episode = episode
        self.isPlaying = isPlaying
        self.canMarkCompleted = canMarkCompleted
        self.position = position
        self.duration = duration
        self.rate = rate
    }
}

/// Which episode an unnamed Resume can start from the current playback state.
public enum VoiceResumeTarget: Sendable, Equatable {
    /// A loaded, paused episode is the item to resume.
    case loadedEpisode
    /// With nothing loaded or after an episode ended, the library chooses an unfinished episode.
    case library(VoiceEpisode?)
}

/// Everything the planner may read, captured once per command.
public struct VoiceSnapshot: Sendable, Equatable {
    /// Episodes on the phone, in the order the Larder currently lists them.
    public let downloaded: [VoiceEpisode]
    /// Every show title in the Larder, downloaded or not, so a show with nothing on the phone
    /// can be told apart from a show that does not exist.
    public let knownShowTitles: [String]
    public let nowPlaying: VoiceNowPlaying?
    public let resumeTarget: VoiceResumeTarget

    public init(
        downloaded: [VoiceEpisode], knownShowTitles: [String], nowPlaying: VoiceNowPlaying?,
        resumeTarget: VoiceResumeTarget = .loadedEpisode
    ) {
        self.downloaded = downloaded
        self.knownShowTitles = knownShowTitles
        self.nowPlaying = nowPlaying
        self.resumeTarget = resumeTarget
    }
}

/// What to do to the player or library. The adapter maps each case onto `LibraryPlayer` and
/// `LibraryAppModel`; `none` means only the dialog is spoken.
public enum VoiceSeekDirection: String, Sendable, Equatable { case forward, backward }

public enum VoiceAction: Sendable, Equatable {
    case none
    case seekBegin(holdID: UUID, direction: VoiceSeekDirection, entryID: ItemID, seekSessionID: String)
    case seekEnd(holdID: UUID, direction: VoiceSeekDirection, entryID: ItemID, seekSessionID: String)
    /// Start this downloaded episode where it was left.
    case play(ItemID)
    case pause
    case resume
    case skipForward
    case skipBack
    case restart
    case markCompleted(ItemID)
    /// Capture the loaded podcast at its current playhead through the phone's durable Notebook path.
    case captureNotebook(origin: LibraryNotebookEntry.CaptureOrigin)
    case setSpeed(Double)
    case startSleepTimer(minutes: Int)
    case stopAfterEpisode
    case cancelSleepTimer
}

/// The planner's answer: an action plus the short line Siri speaks.
public struct VoicePlan: Sendable, Equatable {
    public let action: VoiceAction
    /// One short sentence; empty only when nothing should be said.
    public let dialog: String

    public init(action: VoiceAction, dialog: String) {
        self.action = action
        self.dialog = dialog
    }
}

/// How a spoken show name matched the Larder's show titles.
public enum VoiceShowMatch: Sendable, Equatable {
    case match(String)
    /// Two or more titles matched equally well; the dialog names the first two.
    case ambiguous([String])
    case none
}
