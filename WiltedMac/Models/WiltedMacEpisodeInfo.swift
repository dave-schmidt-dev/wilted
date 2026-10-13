import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

/// One episode as an info popover needs it: the identity a title click carries,
/// the facts every surface states the same way, and the feed's show notes.
///
/// A surface either already holds the episode (Feeds, the Larder, a playlist
/// row, the player) or kept only the durable identity a History row names
/// (History, the rules preview). This is the one shape both can hand the
/// popover, so the notes drawn cannot differ by which screen opened them.
struct WiltedMacEpisodeInfo: Equatable, Sendable {
    let id: String
    let title: String
    let presentation: WiltedMacEpisodePresentation
    let notes: String?

    init(id: String, title: String, presentation: WiltedMacEpisodePresentation, notes: String?) {
        self.id = id
        self.title = title
        self.presentation = presentation
        self.notes = notes
    }

    init(episode: WiltedMacEpisode) {
        self.init(
            id: episode.id, title: episode.title, presentation: episode.presentation, notes: episode.notes)
    }

#if canImport(WiltedProducer)
    /// A stored episode plus the show title the caller already knows. The show
    /// title is a parameter rather than a lookup because a hand-built row may
    /// carry facts the feed record no longer does.
    init(stored: PodcastEpisode, showTitle: String?) {
        self.init(
            id: stored.itemID.rawValue,
            title: stored.title,
            presentation: WiltedMacEpisodePresentation(
                title: stored.title,
                showTitle: showTitle,
                publishedAt: stored.publishedTime?.date,
                sourceDurationSeconds: stored.durationSeconds,
                playableDurationSeconds: nil
            ),
            notes: stored.notes
        )
    }
#endif
}

/// What a by-ID popover open resolved to.
enum WiltedMacEpisodeInfoLoad: Equatable, Sendable {
    case loaded(WiltedMacEpisodeInfo)
    /// Neither the loaded rows nor the store holds this episode any more.
    case notFound
    case failed
}

/// What reading the transcript retained for an episode resolved to.
enum WiltedMacEpisodeTranscriptLoad: Equatable, Sendable {
    case loaded(WiltedMacTranscript)
    /// No transcript record is saved for this episode at all.
    case none
    case failed
}

/// The two reads an info popover performs: the facts behind an identity, and
/// the transcript retained for it.
///
/// Both are closures so the popover stays a view. Whoever builds the source is
/// the one that reaches the model or the store; the popover never touches
/// either, and a surface with nothing to read hands over `.unavailable`.
///
/// The source is main-actor work by construction: every surface that builds
/// one is a view, and both reads land back in the UI.
struct WiltedMacEpisodeInfoSource {
    /// Resolves an episode a surface knows only by identity. A seeded popover
    /// never calls this.
    let loadInfo: @MainActor () async -> WiltedMacEpisodeInfoLoad
    /// Reads the transcript saved for the episode. Called the first time the
    /// Transcript tab is shown, not when the popover opens.
    let loadTranscript: @MainActor () async -> WiltedMacEpisodeTranscriptLoad

    init(
        loadInfo: @escaping @MainActor () async -> WiltedMacEpisodeInfoLoad,
        loadTranscript: @escaping @MainActor () async -> WiltedMacEpisodeTranscriptLoad
    ) {
        self.loadInfo = loadInfo
        self.loadTranscript = loadTranscript
    }

    /// A surface with no readable library: a by-ID open lands on the neutral
    /// not-found state, and the transcript tab says nothing was saved.
    static var unavailable: WiltedMacEpisodeInfoSource {
        WiltedMacEpisodeInfoSource(
            loadInfo: { .notFound },
            loadTranscript: { .none }
        )
    }
}

/// The two halves of an episode info popover.
enum WiltedMacEpisodeNotesSection: String, CaseIterable, Identifiable, Sendable {
    case notes = "Notes"
    case transcript = "Transcript"

    var id: String { rawValue }
}
