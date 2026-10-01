import AppIntents
import Foundation
import WiltedDomain
import WiltedLibrary

/// A show in the Larder, offered to Siri so "play the next episode of TechCrunch Daily" resolves
/// whatever way the show was spoken.
struct ShowEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Show")
    static let defaultQuery = ShowEntityQuery()

    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

struct ShowEntityQuery: EntityStringQuery {
    @MainActor
    private func titles() async -> [String] {
        await VoiceRuntime.target()?.voiceSnapshot().knownShowTitles ?? []
    }

    func entities(for identifiers: [String]) async throws -> [ShowEntity] {
        let known = await titles()
        return identifiers.filter { known.contains($0) }.map(ShowEntity.init(id:))
    }

    func entities(matching string: String) async throws -> [ShowEntity] {
        let known = await titles()
        switch VoiceShowMatcher.match(string, among: known) {
        case let .match(title): return [ShowEntity(id: title)]
        case let .ambiguous(titles): return titles.map(ShowEntity.init(id:))
        case .none: return []
        }
    }

    func suggestedEntities() async throws -> [ShowEntity] { await titles().map(ShowEntity.init(id:)) }
}

/// A downloaded episode, offered to Siri so "play <episode> in Wilted" resolves however the title
/// was spoken. The id is the entry id.
struct EpisodeEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Episode")
    static let defaultQuery = EpisodeEntityQuery()

    let id: String
    let title: String
    let showTitle: String

    init(_ episode: VoiceEpisode) {
        id = episode.id.rawValue
        title = episode.title
        showTitle = episode.showTitle
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: showTitle.isEmpty ? nil : "\(showTitle)")
    }
}

struct EpisodeEntityQuery: EntityStringQuery {
    /// Episodes Siri is offered without a spoken title; the rest are still found by `entities(matching:)`.
    static let suggestionLimit = 25

    @MainActor
    private func downloaded() async -> [VoiceEpisode] {
        await VoiceRuntime.target()?.voiceSnapshot().downloaded ?? []
    }

    func entities(for identifiers: [String]) async throws -> [EpisodeEntity] {
        let wanted = Set(identifiers)
        return await downloaded().filter { wanted.contains($0.id.rawValue) }.map(EpisodeEntity.init)
    }

    func entities(matching string: String) async throws -> [EpisodeEntity] {
        let episodes = await downloaded()
        switch VoiceShowMatcher.match(string, among: episodes.map(\.title)) {
        case let .match(title): return episodes.filter { $0.title == title }.map(EpisodeEntity.init)
        case let .ambiguous(titles):
            // Every episode with a tied title, so equal titles from different shows stay distinguishable.
            let tied = Set(titles)
            return episodes.filter { tied.contains($0.title) }.map(EpisodeEntity.init)
        case .none: return []
        }
    }

    func suggestedEntities() async throws -> [EpisodeEntity] {
        await downloaded().prefix(Self.suggestionLimit).map(EpisodeEntity.init)
    }
}

/// Runs `command` through the shared runner and speaks the planner's short line.
@MainActor
func speak(_ command: VoiceCommand) async throws -> some IntentResult & ProvidesDialog {
    let line = try await VoiceCommandRunner.run(command, on: await VoiceRuntime.target()) { _ in }
    return .result(dialog: IntentDialog(stringLiteral: line))
}

struct PlayNextEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play next episode"
    static let description = IntentDescription("Plays the next downloaded episode, optionally of one show.")

    @Parameter(title: "Show") var show: ShowEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await speak(.playNext(show: show?.id))
    }
}

struct PlayEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play an episode"
    static let description = IntentDescription("Plays one downloaded episode by its title.")

    @Parameter(title: "Episode") var episode: EpisodeEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await speak(.playEpisodeByID(try ItemID(rawValue: episode.id)))
    }
}

struct PlayFirstEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play something"
    static let description = IntentDescription(
        "Plays the episode Wilted would play first: one you are partway through, otherwise the oldest you have not started. Optionally of one show.")

    @Parameter(title: "Show") var show: ShowEntity?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await speak(.playFirst(show: show?.id))
    }
}

struct PauseEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog { try await speak(.pause) }
}

struct ResumeEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog { try await speak(.resume) }
}

struct SkipForwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip forward"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog { try await speak(.skipForward) }
}

struct SkipBackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip back"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog { try await speak(.skipBack) }
}

struct RestartEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Restart this episode"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog { try await speak(.restart) }
}

struct MarkCompletedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark this episode completed"

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = try await VoiceCommandRunner.run(.markCompleted, on: await VoiceRuntime.target()) { question in
            try await confirm(question)
        }
        return .result(dialog: IntentDialog(stringLiteral: line))
    }

    /// Asks the question and throws if it is declined.
    private func confirm(_ question: String) async throws {
        try await requestConfirmation(dialog: IntentDialog(stringLiteral: question))
    }
}

struct WhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's playing"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog { try await speak(.whatsPlaying) }
}

struct ListDownloadedIntent: AppIntent {
    static let title: LocalizedStringResource = "List downloaded episodes"
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog { try await speak(.listDownloaded) }
}

/// The phrases Siri recognizes with no setup. Every phrase names the app, as App Shortcuts require,
/// and an app may declare at most 10; these are exactly 10. Pause, resume and the two skips have no
/// phrase: Siri's own "pause", "resume" and "skip" reach `LibraryPlayer`'s remote commands while
/// Wilted is the Now Playing app (and the car's skip buttons use them), and the four intents stay
/// available in the Shortcuts app. No phrase starts with pause, resume, continue or stop, so none can
/// collide with those system commands, and none stands in for "resume" (Play next would skip ahead).
struct WiltedShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayNextEpisodeIntent(),
            phrases: [
                "Play the next episode of \(\.$show) in \(.applicationName)",
                "Play the next \(.applicationName) episode",
                "Play my next podcast in \(.applicationName)",
                "Play the next podcast of \(\.$show) in \(.applicationName)",
            ],
            shortTitle: "Play next", systemImageName: "play.circle")
        AppShortcut(
            intent: PlayEpisodeIntent(),
            phrases: [
                "Play \(\.$episode) in \(.applicationName)",
                "Put on \(\.$episode) in \(.applicationName)",
            ],
            shortTitle: "Play episode", systemImageName: "play.square")
        AppShortcut(
            intent: PlayFirstEpisodeIntent(),
            phrases: [
                "Play something in \(.applicationName)",
                "Play an episode of \(\.$show) in \(.applicationName)",
                "Play the first episode of \(\.$show) in \(.applicationName)",
                "Play my top \(.applicationName) episode",
            ],
            shortTitle: "Play something", systemImageName: "play.circle")
        AppShortcut(
            intent: RestartEpisodeIntent(),
            phrases: [
                "Restart this episode in \(.applicationName)",
                "Start this episode over in \(.applicationName)",
            ],
            shortTitle: "Restart", systemImageName: "arrow.counterclockwise")
        AppShortcut(
            intent: MarkCompletedIntent(),
            phrases: [
                "Mark this episode completed in \(.applicationName)",
                "Mark this episode as done in \(.applicationName)",
            ],
            shortTitle: "Mark completed", systemImageName: "checkmark.circle")
        AppShortcut(
            intent: WhatsPlayingIntent(),
            phrases: [
                "What's playing in \(.applicationName)",
                "What am I listening to in \(.applicationName)",
            ],
            shortTitle: "What's playing", systemImageName: "waveform")
        AppShortcut(
            intent: ListDownloadedIntent(),
            phrases: [
                "What's downloaded in \(.applicationName)",
                "What episodes do I have in \(.applicationName)",
            ],
            shortTitle: "Downloaded", systemImageName: "arrow.down.circle")
        AppShortcut(
            intent: TimeLeftIntent(),
            phrases: [
                "How much is left in \(.applicationName)",
                "How much time is left in \(.applicationName)",
                "How long is left in \(.applicationName)",
            ],
            shortTitle: "Time left", systemImageName: "hourglass")
        AppShortcut(
            intent: SetSpeedIntent(),
            phrases: [
                "Set speed to \(\.$speed) in \(.applicationName)",
                "Set the speed to \(\.$speed) in \(.applicationName)",
            ],
            shortTitle: "Set speed", systemImageName: "speedometer")
    }
}
